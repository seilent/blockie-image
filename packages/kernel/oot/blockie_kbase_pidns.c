#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/kprobes.h>
#include <linux/pid.h>
#include <linux/pid_namespace.h>
#include <linux/sched.h>
#include <linux/rcupdate.h>
#include <linux/mutex.h>
#include <linux/notifier.h>
#include <linux/atomic.h>
#include <linux/string.h>
#include <linux/uaccess.h>
#include <linux/ptrace.h>
#include <asm/ptrace.h>

#define NSITES 2

static const char *const site_sym[NSITES] = {
	"mali_kbase_mt6768:kbase_context_common_init",
	"mali_kbase_mt6768:mali_oom_notifier_handler",
};
static const unsigned int site_off[NSITES] = { 0x8c, 0xac };
static const u32 site_pre[NSITES] = { 0xb9422300, 0xb9400780 };
static const u32 site_post[NSITES] = { 0xb40018e0, 0x2a1f03e1 };

static struct kprobe kp[NSITES];
static int armed[NSITES];
static atomic_t hits[NSITES];
static atomic_t miss[NSITES];
static atomic_t wrong[NSITES];
static DEFINE_MUTEX(arm_lock);

static bool is_bl(u32 w)
{
	return (w & 0xfc000000) == 0x94000000;
}

static int pidns_pre(struct kprobe *p, struct pt_regs *regs)
{
	int site = p - kp;
	int nr = (int)regs->regs[0];
	unsigned long pc = instruction_pointer(regs);
	struct pid *fixed;
	struct pid *stock;

	rcu_read_lock();
	fixed = get_pid(find_pid_ns(nr, &init_pid_ns));
	stock = find_pid_ns(nr, task_active_pid_ns(current));
	if (!stock)
		atomic_inc(&miss[site]);
	else if (stock != fixed)
		atomic_inc(&wrong[site]);
	rcu_read_unlock();

	regs->regs[0] = (unsigned long)fixed;
	regs->regs[30] = pc + 4;
	instruction_pointer_set(regs, pc + 4);
	atomic_inc(&hits[site]);
	return 1;
}
NOKPROBE_SYMBOL(pidns_pre);

static void kp_reset(int site)
{
	memset(&kp[site], 0, sizeof(kp[site]));
	kp[site].symbol_name = site_sym[site];
	kp[site].offset = site_off[site];
	kp[site].pre_handler = pidns_pre;
	kp[site].flags = KPROBE_FLAG_DISABLED;
}

static void arm_site(int site, bool quiet)
{
	unsigned long addr;
	u32 before, at, after;
	int ret;

	if (armed[site])
		return;

	kp_reset(site);
	ret = register_kprobe(&kp[site]);
	if (ret) {
		if (quiet)
			pr_info("blockie_kbase_pidns: site %d not armed yet (%d), waiting for kbase\n", site, ret);
		else
			pr_warn("blockie_kbase_pidns: site %d register failed %d\n", site, ret);
		kp_reset(site);
		return;
	}

	addr = (unsigned long)kp[site].addr;
	if (copy_from_kernel_nofault(&before, (void *)(addr - 4), sizeof(before)) ||
	    copy_from_kernel_nofault(&at, (void *)addr, sizeof(at)) ||
	    copy_from_kernel_nofault(&after, (void *)(addr + 4), sizeof(after))) {
		pr_warn("blockie_kbase_pidns: site %d word read failed\n", site);
		unregister_kprobe(&kp[site]);
		kp_reset(site);
		return;
	}

	if (before != site_pre[site] || after != site_post[site] ||
	    !(is_bl(at) || is_bl(kp[site].opcode))) {
		pr_warn("blockie_kbase_pidns: site %d words %08x %08x %08x opcode %08x unexpected\n",
			site, before, at, after, kp[site].opcode);
		unregister_kprobe(&kp[site]);
		kp_reset(site);
		return;
	}

	ret = enable_kprobe(&kp[site]);
	if (ret) {
		pr_warn("blockie_kbase_pidns: site %d enable failed %d\n", site, ret);
		unregister_kprobe(&kp[site]);
		kp_reset(site);
		return;
	}
	armed[site] = 1;
}

static void disarm_site(int site)
{
	if (armed[site]) {
		unregister_kprobe(&kp[site]);
		armed[site] = 0;
	}
	kp_reset(site);
}

static int mod_notify(struct notifier_block *nb, unsigned long action, void *data)
{
	struct module *mod = data;
	int i;

	if (strcmp(mod->name, "mali_kbase_mt6768"))
		return NOTIFY_DONE;

	mutex_lock(&arm_lock);
	if (action == MODULE_STATE_LIVE)
		for (i = 0; i < NSITES; i++)
			arm_site(i, false);
	else if (action == MODULE_STATE_GOING)
		for (i = 0; i < NSITES; i++)
			disarm_site(i);
	mutex_unlock(&arm_lock);
	return NOTIFY_DONE;
}

static struct notifier_block mod_nb = {
	.notifier_call = mod_notify,
};

static int armed_get(char *buf, const struct kernel_param *p)
{
	return sprintf(buf, "%d %d\n", armed[0], armed[1]);
}
static const struct kernel_param_ops armed_ops = { .get = armed_get };
module_param_cb(armed, &armed_ops, NULL, 0444);

static int hits_get(char *buf, const struct kernel_param *p)
{
	return sprintf(buf, "%d %d\n", atomic_read(&hits[0]), atomic_read(&hits[1]));
}
static const struct kernel_param_ops hits_ops = { .get = hits_get };
module_param_cb(hits, &hits_ops, NULL, 0444);

static int miss_get(char *buf, const struct kernel_param *p)
{
	return sprintf(buf, "%d %d\n", atomic_read(&miss[0]), atomic_read(&miss[1]));
}
static const struct kernel_param_ops miss_ops = { .get = miss_get };
module_param_cb(miss, &miss_ops, NULL, 0444);

static int wrong_get(char *buf, const struct kernel_param *p)
{
	return sprintf(buf, "%d %d\n", atomic_read(&wrong[0]), atomic_read(&wrong[1]));
}
static const struct kernel_param_ops wrong_ops = { .get = wrong_get };
module_param_cb(wrong, &wrong_ops, NULL, 0444);

static int __init pidns_init(void)
{
	int i, ret;

	for (i = 0; i < NSITES; i++)
		kp_reset(i);

	ret = register_module_notifier(&mod_nb);
	if (ret)
		return ret;

	mutex_lock(&arm_lock);
	for (i = 0; i < NSITES; i++)
		arm_site(i, true);
	mutex_unlock(&arm_lock);
	return 0;
}

static void __exit pidns_exit(void)
{
	int i;

	unregister_module_notifier(&mod_nb);
	mutex_lock(&arm_lock);
	for (i = 0; i < NSITES; i++)
		disarm_site(i);
	mutex_unlock(&arm_lock);
}

module_init(pidns_init);
module_exit(pidns_exit);

MODULE_LICENSE("GPL v2");
MODULE_AUTHOR("seilent");
MODULE_DESCRIPTION("kbase pid lookups resolved in init_pid_ns");
