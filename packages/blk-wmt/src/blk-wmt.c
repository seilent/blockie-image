#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <time.h>
#include <unistd.h>

#define IOC(dir, type, nr, size) (((unsigned)(dir) << 30) | ((unsigned)(size) << 16) | ((unsigned)(type) << 8) | (unsigned)(nr))
#define COMBO_IOCTL_SET_CHIP_ID IOC(1, 'w', 1, 4)
#define COMBO_IOCTL_GET_SOC_CHIP_ID IOC(2, 'w', 3, 4)
#define COMBO_IOCTL_DO_MODULE_INIT IOC(2, 'w', 4, 4)
#define COMBO_IOCTL_MODULE_CLEANUP IOC(2, 'w', 5, 4)
#define COMBO_IOCTL_EXT_CHIP_PWR_ON IOC(2, 'w', 6, 4)
#define COMBO_IOCTL_GET_ADIE_CHIP_ID IOC(2, 'w', 9, 4)
#define COMBO_IOCTL_CONNSYS_SOC_HW_INIT IOC(2, 'w', 10, 4)
#define WMT_IOCTL_SET_STP_MODE IOC(1, 0xa0, 5, 4)
#define WMT_IOCTL_LPBK_POWER_CTRL IOC(1, 0xa0, 7, 4)
#define WMT_IOCTL_GET_CHIP_INFO IOC(2, 0xa0, 12, 4)
#define WMT_IOCTL_SET_LAUNCHER_KILL IOC(1, 0xa0, 13, 4)
#define WMT_IOCTL_SET_PATCH_NUM IOC(1, 0xa0, 14, 4)
#define WMT_IOCTL_SET_PATCH_INFO IOC(1, 0xa0, 15, 8)
#define WMT_IOCTL_WMT_QUERY_CHIPID IOC(2, 0xa0, 22, 4)
#define WMT_IOCTL_SET_ROM_PATCH_INFO IOC(1, 0xa0, 31, 8)

#define CHIP 0x6768
#define SOC "soc1_0"
#define PATTERN ".bin"
#define STP_MODE 0x23
#define POWER_ON 2
#define NVRAM_TAG "WR-BUF:NVRAM"
#define NVRAM_MAX 8192

struct rom_patch_info {
    uint32_t type;
    uint8_t addr[4];
    char name[256];
};

struct patch_info {
    uint32_t seq;
    uint8_t addr[4];
    char name[256];
};

static const struct {
    unsigned code;
    const char* name;
} names[] = {
    {COMBO_IOCTL_SET_CHIP_ID, "SET_CHIP_ID"},
    {COMBO_IOCTL_GET_SOC_CHIP_ID, "GET_SOC_CHIP_ID"},
    {COMBO_IOCTL_DO_MODULE_INIT, "DO_MODULE_INIT"},
    {COMBO_IOCTL_MODULE_CLEANUP, "MODULE_CLEANUP"},
    {COMBO_IOCTL_EXT_CHIP_PWR_ON, "EXT_CHIP_PWR_ON"},
    {COMBO_IOCTL_GET_ADIE_CHIP_ID, "GET_ADIE_CHIP_ID"},
    {COMBO_IOCTL_CONNSYS_SOC_HW_INIT, "CONNSYS_SOC_HW_INIT"},
    {WMT_IOCTL_SET_STP_MODE, "SET_STP_MODE"},
    {WMT_IOCTL_LPBK_POWER_CTRL, "LPBK_POWER_CTRL"},
    {WMT_IOCTL_GET_CHIP_INFO, "GET_CHIP_INFO"},
    {WMT_IOCTL_SET_LAUNCHER_KILL, "SET_LAUNCHER_KILL"},
    {WMT_IOCTL_SET_PATCH_NUM, "SET_PATCH_NUM"},
    {WMT_IOCTL_SET_PATCH_INFO, "SET_PATCH_INFO"},
    {WMT_IOCTL_WMT_QUERY_CHIPID, "QUERY_CHIPID"},
    {WMT_IOCTL_SET_ROM_PATCH_INFO, "SET_ROM_PATCH_INFO"},
};

static const char* fwdir = "/vendor/firmware";
static const char* devdir = "/dev";
static const char* rundir = "/run/blockie";
static const char* sysdir = "/sys";
static const char* bootid_path = "/proc/sys/kernel/random/boot_id";
static const char* kmsg_path = "/dev/kmsg";
static int node_wait = 30;
static int verdict_wait = 60;
static char state[PATH_MAX];
static int kmsg = -1;
static int stpwmt = -1;
static int status_pipe = -1;
static volatile sig_atomic_t stop;

static void emit(int fd, const char* b, size_t n)
{
    if (fd >= 0) {
        ssize_t r = write(fd, b, n);
        (void)r;
    }
}

static void say(const char* fmt, ...)
{
    char b[512];
    va_list ap;
    int n = snprintf(b, sizeof b, "blk-wmt: ");
    va_start(ap, fmt);
    n += vsnprintf(b + n, sizeof b - (size_t)n, fmt, ap);
    va_end(ap);
    if (n > (int)sizeof b - 2)
        n = (int)sizeof b - 2;
    b[n++] = '\n';
    b[n] = 0;
    emit(kmsg, b, (size_t)n);
    emit(2, b, (size_t)n);
}

static void msleep(int ms)
{
    struct timespec t = {ms / 1000, (ms % 1000) * 1000000L};
    while (nanosleep(&t, &t) != 0 && errno == EINTR)
        ;
}

static const char* ioctl_name(unsigned code)
{
    for (size_t i = 0; i < sizeof names / sizeof *names; i++)
        if (names[i].code == code)
            return names[i].name;
    return "?";
}

static int xioctl(int fd, unsigned code, unsigned long arg)
{
    errno = 0;
    int r = ioctl(fd, code, arg);
    int e = errno;
    if (r < 0)
        say("ioctl %s(0x%lx) = %d %s", ioctl_name(code), arg, r, strerror(e));
    else
        say("ioctl %s(0x%lx) = %d (0x%x)", ioctl_name(code), arg, r, (unsigned)r);
    errno = e;
    return r;
}

static int path(char* b, size_t n, const char* dir, const char* name)
{
    int r = snprintf(b, n, "%s/%s", dir, name);
    return r < 0 || (size_t)r >= n ? -1 : 0;
}

static int put(const char* name, const char* fmt, ...)
{
    char p[PATH_MAX], b[PATH_MAX];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(b, sizeof b - 1, fmt, ap);
    va_end(ap);
    if (n < 0 || n >= (int)sizeof b - 1 || path(p, sizeof p, state, name) < 0)
        return -1;
    b[n++] = '\n';
    int fd = open(p, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0 || write(fd, b, (size_t)n) != n) {
        say("state %s: %s", p, strerror(errno));
        if (fd >= 0)
            close(fd);
        return -1;
    }
    close(fd);
    return 0;
}

static int slurp(const char* p, char* b, size_t n)
{
    int fd = open(p, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return -1;
    ssize_t r = read(fd, b, n - 1);
    close(fd);
    if (r <= 0)
        return -1;
    b[r] = 0;
    b[strcspn(b, "\n")] = 0;
    return b[0] ? 0 : -1;
}

static int get(const char* name, char* b, size_t n)
{
    char p[PATH_MAX];
    if (path(p, sizeof p, state, name) < 0)
        return -1;
    return slurp(p, b, n);
}

static int claim(const char* name)
{
    char p[PATH_MAX];
    if (path(p, sizeof p, state, name) < 0)
        return -1;
    int fd = open(p, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) {
        if (errno == EEXIST)
            return 1;
        say("%s: marker %s: %s", name, p, strerror(errno));
        return -1;
    }
    char b[32];
    int n = snprintf(b, sizeof b, "%d\n", (int)getpid());
    if (write(fd, b, (size_t)n) != n) {
        say("%s: marker %s not written: %s; it stays and blocks this boot, nothing was sent", name, p, strerror(errno));
        close(fd);
        return -1;
    }
    close(fd);
    return 0;
}

static int state_dir(void)
{
    char id[64], top[PATH_MAX];
    struct stat st;
    if (stat(rundir, &st) != 0 || !S_ISDIR(st.st_mode)) {
        say("run dir %s missing", rundir);
        return -1;
    }
    if (slurp(bootid_path, id, sizeof id) < 0 || strlen(id) != 36 || strspn(id, "0123456789abcdef-") != 36) {
        say("boot id at %s unreadable or not a uuid", bootid_path);
        return -1;
    }
    if (path(top, sizeof top, rundir, "wmt") < 0 || path(state, sizeof state, top, id) < 0)
        return -1;
    if ((mkdir(top, 0700) != 0 && errno != EEXIST) || (mkdir(state, 0700) != 0 && errno != EEXIST)) {
        say("state dir %s: %s", state, strerror(errno));
        return -1;
    }
    if (lstat(state, &st) != 0 || !S_ISDIR(st.st_mode)) {
        say("state dir %s is not a directory", state);
        return -1;
    }
    return 0;
}

static int ensure_node(const char* name)
{
    char p[PATH_MAX], sp[PATH_MAX], b[64];
    struct stat st;
    if (path(p, sizeof p, devdir, name) < 0)
        return -1;
    if (stat(p, &st) == 0) {
        if (S_ISCHR(st.st_mode))
            return 0;
        say("%s exists but is not a character device", p);
        return -1;
    }
    char cls[PATH_MAX];
    if (path(cls, sizeof cls, sysdir, "class") < 0)
        return -1;
    DIR* d = opendir(cls);
    if (!d)
        return -1;
    struct dirent* de;
    unsigned maj = 0, min = 0;
    int found = 0;
    while (!found && (de = readdir(d))) {
        if (de->d_name[0] == '.')
            continue;
        int r = snprintf(sp, sizeof sp, "%s/%s/%s/dev", cls, de->d_name, name);
        if (r < 0 || (size_t)r >= sizeof sp || slurp(sp, b, sizeof b) < 0)
            continue;
        found = sscanf(b, "%u:%u", &maj, &min) == 2;
    }
    closedir(d);
    if (!found)
        return -1;
    say("%s missing: mknod %s c %u %u (from %s)", p, p, maj, min, sp);
    if (mknod(p, S_IFCHR | 0600, makedev(maj, min)) < 0 && errno != EEXIST) {
        say("mknod %s: %s", p, strerror(errno));
        return -1;
    }
    return 0;
}

static int open_node(const char* name, int flags)
{
    char p[PATH_MAX];
    if (path(p, sizeof p, devdir, name) < 0)
        return -1;
    int tries = node_wait * 10 / 3;
    if (tries < 1)
        tries = 1;
    for (int i = 0; i < tries; i++) {
        ensure_node(name);
        int fd = open(p, flags | O_CLOEXEC | O_NOCTTY);
        if (fd >= 0) {
            struct stat st;
            if (fstat(fd, &st) != 0 || !S_ISCHR(st.st_mode)) {
                close(fd);
                say("open %s: not a character device, refused", p);
                return -1;
            }
            say("open %s fd=%d attempt=%d", p, fd, i + 1);
            return fd;
        }
        if (i == 0 || i % 10 == 9)
            say("open %s: %s (attempt %d/%d)", p, strerror(errno), i + 1, tries);
        if (i + 1 < tries)
            msleep(300);
    }
    return -1;
}

static void verdict(char c)
{
    int fd = __atomic_exchange_n(&status_pipe, -1, __ATOMIC_SEQ_CST);
    if (fd >= 0) {
        emit(fd, &c, 1);
        close(fd);
    }
}

static int loader(int fd)
{
    if (xioctl(fd, COMBO_IOCTL_CONNSYS_SOC_HW_INIT, 0) != 0) {
        say("loader: CONNSYS_SOC_HW_INIT failed");
        return -1;
    }
    int chip = -1;
    for (int i = 0; i < 20 && chip == -1; i++) {
        int r = xioctl(fd, COMBO_IOCTL_EXT_CHIP_PWR_ON, 0);
        if (r == 0) {
            say("loader: EXT_CHIP_PWR_ON answered 0, an external combo chip is not this board");
            return -1;
        }
        if (r == -1)
            chip = xioctl(fd, COMBO_IOCTL_GET_SOC_CHIP_ID, 0);
        if (chip == -1)
            msleep(500);
    }
    if (chip != CHIP) {
        say("loader: chip id 0x%x, want 0x%x", (unsigned)chip, CHIP);
        return -1;
    }
    xioctl(fd, COMBO_IOCTL_SET_CHIP_ID, (unsigned long)chip);
    if (xioctl(fd, COMBO_IOCTL_MODULE_CLEANUP, (unsigned long)chip) != 0) {
        say("loader: MODULE_CLEANUP failed, no DO_MODULE_INIT (as stock)");
        return -1;
    }
    if (xioctl(fd, COMBO_IOCTL_DO_MODULE_INIT, (unsigned long)chip) != 0) {
        say("loader: DO_MODULE_INIT failed");
        return -1;
    }
    int adie = xioctl(fd, COMBO_IOCTL_GET_ADIE_CHIP_ID, 0);
    if (adie == -1) {
        say("loader: A-die chip id error (as stock, stop)");
        return -1;
    }
    if (put("chipid", "0x%04x", (unsigned)chip) < 0 || put("adie", "0x%04x", (unsigned)adie) < 0) {
        say("loader: state not recorded, stopping before the power on");
        return -2;
    }
    say("loader: done chip=0x%04x adie=0x%04x", (unsigned)chip, (unsigned)adie);
    return 0;
}

static int cmpstr(const void* a, const void* b)
{
    return strcmp(*(char* const*)a, *(char* const*)b);
}

static void free_list(char** v, int n)
{
    for (int i = 0; i < n; i++)
        free(v[i]);
    free(v);
}

static int candidates(const char* prefix, char*** out)
{
    DIR* d = opendir(fwdir);
    if (!d) {
        say("firmware dir %s: %s", fwdir, strerror(errno));
        return -1;
    }
    char** v = NULL;
    int n = 0;
    struct dirent* de;
    while ((de = readdir(d))) {
        if (strncmp(de->d_name, prefix, strlen(prefix)) || !strstr(de->d_name, PATTERN))
            continue;
        char** w = realloc(v, (size_t)(n + 1) * sizeof *v);
        char* s = strdup(de->d_name);
        if (!w || !s) {
            free(s);
            free_list(w ? w : v, n);
            closedir(d);
            return -1;
        }
        v = w;
        v[n++] = s;
    }
    closedir(d);
    if (n > 1)
        qsort(v, (size_t)n, sizeof *v, cmpstr);
    *out = v;
    return n;
}

static int header(const char* name, uint8_t* ver, uint8_t info[8])
{
    char p[PATH_MAX];
    uint8_t h[0x20];
    if (path(p, sizeof p, fwdir, name) < 0)
        return -1;
    int fd = open(p, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        say("patch %s: %s", p, strerror(errno));
        return -1;
    }
    ssize_t n = pread(fd, h, sizeof h, 0);
    close(fd);
    if (n != (ssize_t)sizeof h) {
        say("patch %s: header short (%zd bytes)", p, n);
        return -1;
    }
    *ver = h[0x17];
    memcpy(info, h + 0x18, 8);
    return 0;
}

static int chip_info(int* fwv)
{
    int chip = xioctl(stpwmt, WMT_IOCTL_GET_CHIP_INFO, 0);
    if (chip != CHIP) {
        say("chip info: chip 0x%x, want 0x%x", (unsigned)chip, CHIP);
        return -1;
    }
    *fwv = xioctl(stpwmt, WMT_IOCTL_GET_CHIP_INFO, 2);
    return 0;
}

static int rom_patch(void)
{
    int fwv;
    char** v;
    if (chip_info(&fwv) < 0)
        return -1;
    int n = candidates(SOC "_ram", &v);
    if (n < 0)
        return -3;
    int ok = 0, rc = 0;
    for (int i = 0; i < n; i++) {
        uint8_t ver, info[8];
        if (header(v[i], &ver, info) < 0) {
            rc = -4;
            continue;
        }
        if (ver != (uint8_t)(fwv & 0xff)) {
            say("srh_rom_patch: %s skipped, version byte 0x%02x, fw_version 0x%04x", v[i], ver, (unsigned)fwv & 0xffff);
            continue;
        }
        if (!(info[3] & 0xf0) || info[7] > 5) {
            say("srh_rom_patch: %s skipped, info[3]=0x%02x info[7]=%u", v[i], info[3], info[7]);
            continue;
        }
        struct rom_patch_info ri;
        memset(&ri, 0, sizeof ri);
        ri.type = info[7];
        ri.addr[1] = info[1];
        ri.addr[2] = info[2];
        ri.addr[3] = info[3];
        strncpy(ri.name, v[i], sizeof ri.name - 1);
        say("srh_rom_patch: type=%u name=%s addr=00,%02x,%02x,%02x", ri.type, ri.name, ri.addr[1], ri.addr[2], ri.addr[3]);
        if (xioctl(stpwmt, WMT_IOCTL_SET_ROM_PATCH_INFO, (unsigned long)&ri) != 0) {
            rc = -6;
            continue;
        }
        ok++;
    }
    free_list(v, n);
    if (!rc && !ok) {
        say("srh_rom_patch: no usable %s_ram*%s in %s (%d candidates)", SOC, PATTERN, fwdir, n);
        rc = -6;
    }
    return rc;
}

static int patch(void)
{
    int fwv;
    char** v;
    if (chip_info(&fwv) < 0)
        return -1;
    int n = candidates(SOC "_patch", &v);
    if (n < 0)
        return -3;
    int ok = 0, rc = 0;
    for (int i = 0; i < n; i++) {
        uint8_t ver, info[8];
        if (header(v[i], &ver, info) < 0) {
            rc = -4;
            continue;
        }
        if (ver != (uint8_t)(fwv & 0xff)) {
            say("srh_patch: %s skipped, version byte 0x%02x, fw_version 0x%04x", v[i], ver, (unsigned)fwv & 0xffff);
            continue;
        }
        if (!ok)
            xioctl(stpwmt, WMT_IOCTL_SET_PATCH_NUM, info[0] >> 4);
        struct patch_info pi;
        memset(&pi, 0, sizeof pi);
        pi.seq = info[0] & 0xf;
        pi.addr[1] = info[1];
        pi.addr[2] = info[2];
        pi.addr[3] = info[3];
        strncpy(pi.name, v[i], sizeof pi.name - 1);
        say("srh_patch: num=%u seq=%u name=%s addr=00,%02x,%02x,%02x", info[0] >> 4, pi.seq, pi.name, pi.addr[1], pi.addr[2],
            pi.addr[3]);
        xioctl(stpwmt, WMT_IOCTL_SET_PATCH_INFO, (unsigned long)&pi);
        ok++;
    }
    free_list(v, n);
    if (!rc && !ok) {
        say("srh_patch: no usable %s_patch*%s in %s (%d candidates)", SOC, PATTERN, fwdir, n);
        rc = -6;
    }
    return rc;
}

static void answer(const char* cmd)
{
    char resp[32];
    int r;
    if (!strcmp(cmd, "srh_rom_patch"))
        r = rom_patch();
    else if (!strcmp(cmd, "srh_patch"))
        r = patch();
    else if (!strcmp(cmd, "update_patch_version"))
        r = 0;
    else
        r = 1;
    if (r == 0)
        snprintf(resp, sizeof resp, "ok");
    else if (r == 1)
        snprintf(resp, sizeof resp, "cmd not found");
    else
        snprintf(resp, sizeof resp, "resp_%d", r);
    say("cmd(%s) resp(%s)", cmd, resp);
    ssize_t w = write(stpwmt, resp, strlen(resp));
    if (w != (ssize_t)strlen(resp))
        say("write resp: %zd %s", w, strerror(errno));
}

static void* power(void* arg)
{
    (void)arg;
    say("launcher: LPBK_POWER_CTRL(%d), once", POWER_ON);
    int ok = xioctl(stpwmt, WMT_IOCTL_LPBK_POWER_CTRL, POWER_ON) == 0;
    int saved = put("launcher", ok ? "yes" : "no") == 0;
    say(ok ? "launcher: connsys on" : "launcher: connsys power on failed, reboot before any retry");
    if (ok && !saved)
        say("launcher: connsys on, but the launcher state was not recorded");
    verdict(ok ? (saved ? 'K' : 'S') : 'F');
    return NULL;
}

static void on_term(int sig)
{
    (void)sig;
    stop = 1;
}

static int launcher(void)
{
    int fd = open_node("stpwmt", O_RDWR);
    if (fd < 0) {
        say("launcher: no %s/stpwmt", devdir);
        return -1;
    }
    stpwmt = fd;
    int chip = xioctl(fd, WMT_IOCTL_WMT_QUERY_CHIPID, 0);
    for (int i = 0; chip == -1 && i < 50; i++) {
        msleep(300);
        chip = xioctl(fd, WMT_IOCTL_WMT_QUERY_CHIPID, 0);
    }
    if (chip != CHIP) {
        say("launcher: chip id 0x%x, want 0x%x", (unsigned)chip, CHIP);
        return -1;
    }
    xioctl(fd, WMT_IOCTL_SET_STP_MODE, STP_MODE);
    xioctl(fd, WMT_IOCTL_SET_LAUNCHER_KILL, 0);
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = SIG_IGN;
    sigaction(SIGPIPE, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);
    sa.sa_handler = on_term;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    pthread_t th;
    if (pthread_create(&th, NULL, power, NULL) != 0) {
        say("launcher: power thread: %s", strerror(errno));
        return -1;
    }
    pthread_detach(th);
    struct pollfd p = {.fd = fd, .events = POLLIN | POLLRDNORM};
    while (!stop) {
        p.revents = 0;
        int r = poll(&p, 1, 1000);
        if (r < 0) {
            if (errno == EINTR)
                continue;
            say("launcher: poll: %s", strerror(errno));
            break;
        }
        if (r == 0)
            continue;
        if (p.revents & (POLLERR | POLLHUP | POLLNVAL)) {
            say("launcher: poll revents 0x%x, giving up", p.revents);
            break;
        }
        if (!(p.revents & POLLIN))
            continue;
        char b[256];
        ssize_t n = read(fd, b, sizeof b - 1);
        if (n < 1) {
            say("launcher: POLLIN but read %zd", n);
            msleep(100);
            continue;
        }
        b[n] = 0;
        answer(b);
    }
    say("launcher: stopping, SET_LAUNCHER_KILL(1)");
    xioctl(fd, WMT_IOCTL_SET_LAUNCHER_KILL, 1);
    put("launcher", "stopped");
    return 0;
}

static int start(void)
{
    int fd = open_node("wmtdetect", O_RDWR);
    if (fd < 0) {
        say("start: no %s/wmtdetect, is wmt_drv loaded?", devdir);
        return 1;
    }
    int c = claim("once.power");
    if (c) {
        close(fd);
        if (c > 0)
            say("start: connsys power on already attempted this boot, refusing (reboot first)");
        return c > 0 ? 4 : 1;
    }
    int r = loader(fd);
    close(fd);
    if (r == -2)
        return 5;
    if (r < 0)
        return 2;
    int pfd[2];
    if (pipe2(pfd, O_CLOEXEC) < 0) {
        say("start: pipe: %s", strerror(errno));
        return 2;
    }
    pid_t pid = fork();
    if (pid < 0) {
        say("start: fork: %s", strerror(errno));
        return 2;
    }
    if (pid > 0) {
        close(pfd[1]);
        int saved = put("pid", "%d", (int)pid) == 0;
        struct pollfd p = {.fd = pfd[0], .events = POLLIN};
        int n = poll(&p, 1, verdict_wait * 1000);
        char v = 0;
        if (n > 0 && read(pfd[0], &v, 1) == 1 && (v == 'K' || v == 'S')) {
            if (v == 'S' || !saved) {
                say("start: connsys on, launcher pid %d, but its state was not recorded (%s); reboot before any retry",
                    (int)pid, v == 'S' ? "launcher" : "pid");
                return 5;
            }
            say("start: connsys on, launcher pid %d keeps %s/stpwmt open", (int)pid, devdir);
            return 0;
        }
        if (n == 0) {
            say("start: no power on verdict after %d s, launcher pid %d still running", verdict_wait, (int)pid);
            return 3;
        }
        say("start: bring up failed, launcher pid %d", (int)pid);
        return 2;
    }
    close(pfd[0]);
    status_pipe = pfd[1];
    setsid();
    int nul = open("/dev/null", O_RDWR | O_CLOEXEC);
    if (nul >= 0) {
        dup2(nul, 0);
        dup2(nul, 1);
        dup2(nul, 2);
    }
    if (chdir("/") != 0)
        say("launcher: chdir /: %s", strerror(errno));
    r = launcher();
    verdict('F');
    _exit(r < 0);
}

static int nvram(int argc, char** argv)
{
    static char* def[] = {"/mnt/vendor/nvdata/APCFG/APRDEB/WIFI", "/vendor/nvdata-fallback/APCFG/APRDEB/WIFI"};
    char** files = argc ? argv : def;
    int count = argc ? argc : 2;
    const char* file = NULL;
    struct stat st;
    for (int i = 0; i < count && !file; i++) {
        if (stat(files[i], &st) == 0)
            file = files[i];
        else
            say("nvram: %s: %s", files[i], strerror(errno));
    }
    if (!file) {
        say("nvram: no NVRAM file");
        return 1;
    }
    long len = (long)st.st_size - 2;
    if (!S_ISREG(st.st_mode) || len < 256 || (len & 0xff) || len > NVRAM_MAX) {
        say("nvram: %s size %lld, want a regular file of 256 * n + 2 bytes, at most %d", file, (long long)st.st_size, NVRAM_MAX + 2);
        return 1;
    }
    size_t tag = strlen(NVRAM_TAG);
    char* b = malloc(tag + (size_t)len);
    if (!b)
        return 1;
    memcpy(b, NVRAM_TAG, tag);
    int fd = open(file, O_RDONLY | O_CLOEXEC);
    ssize_t n = fd < 0 ? -1 : read(fd, b + tag, (size_t)len);
    if (fd >= 0)
        close(fd);
    if (n != len) {
        say("nvram: read %s: %zd of %ld bytes", file, n, len);
        free(b);
        return 1;
    }
    int w = open_node("wmtWifi", O_RDWR);
    if (w < 0) {
        say("nvram: no %s/wmtWifi, is wmt_chrdev_wifi loaded?", devdir);
        free(b);
        return 1;
    }
    ssize_t r = write(w, b, tag + (size_t)len);
    int e = errno;
    close(w);
    free(b);
    if (r != (ssize_t)(tag + (size_t)len)) {
        say("nvram: write %s/wmtWifi: %zd of %zu bytes %s", devdir, r, tag + (size_t)len, r < 0 ? strerror(e) : "");
        return 2;
    }
    if (put("nvram", "%s", file) < 0) {
        say("nvram: %ld bytes from %s pushed, but the state was not recorded", len, file);
        return 5;
    }
    say("nvram: %ld bytes from %s pushed to %s/wmtWifi", len, file, devdir);
    return 0;
}

static int alive(void)
{
    char v[32], p[64], b[256];
    if (get("pid", v, sizeof v) < 0)
        return 0;
    int pid = atoi(v);
    if (pid <= 1 || kill(pid, 0) != 0)
        return 0;
    snprintf(p, sizeof p, "/proc/%d/stat", pid);
    if (slurp(p, b, sizeof b) < 0)
        return 0;
    char* name = strchr(b, '(');
    char* end = strrchr(b, ')');
    return name && end && !strncmp(name + 1, "blk-wmt", 7) && end[1] == ' ' && end[2] && end[2] != 'Z';
}

static int wifi_on(void)
{
    char v[PATH_MAX];
    if (get("once.power", v, sizeof v) < 0) {
        say("wifi-on: no connsys power on recorded for this boot");
        return 1;
    }
    if (get("launcher", v, sizeof v) < 0)
        strcpy(v, "-");
    if (strcmp(v, "yes")) {
        say("wifi-on: connsys is not on (launcher=%s)", v);
        return 1;
    }
    if (!alive()) {
        say("wifi-on: the launcher is not running");
        return 1;
    }
    if (get("nvram", v, sizeof v) < 0) {
        say("wifi-on: NVRAM not pushed this boot");
        return 1;
    }
    int fd = open_node("wmtWifi", O_WRONLY);
    if (fd < 0) {
        say("wifi-on: no %s/wmtWifi", devdir);
        return 1;
    }
    int c = claim("once.wifi");
    if (c) {
        close(fd);
        if (c > 0)
            say("wifi-on: Wi-Fi power on already attempted this boot, refusing (reboot first)");
        return c > 0 ? 4 : 1;
    }
    ssize_t r = write(fd, "1", 2);
    int e = errno;
    close(fd);
    if (r != 2) {
        put("wifi", "failed");
        say("wifi-on: write 1 to %s/wmtWifi: %zd %s", devdir, r, r < 0 ? strerror(e) : "");
        return 2;
    }
    if (put("wifi", "on") < 0) {
        say("wifi-on: 1 written to %s/wmtWifi, Wi-Fi is on, but the state was not recorded; reboot before any retry",
            devdir);
        return 5;
    }
    say("wifi-on: 1 written to %s/wmtWifi", devdir);
    return 0;
}

static int usage(void)
{
    fprintf(stderr, "usage: blk-wmt [-p fwdir] [-d devdir] [-r rundir] [-s sysdir] [-b boot_id] [-k kmsg] [-n node_wait_s] [-w wait_s]\n"
                    "               start | nvram [file...] | wifi-on\n");
    return 2;
}

static int number(const char* s, int* out)
{
    char* end;
    errno = 0;
    long v = strtol(s, &end, 10);
    if (errno || end == s || *end || v < 0 || v > 3600)
        return -1;
    *out = (int)v;
    return 0;
}

int main(int argc, char** argv)
{
    int c;
    while ((c = getopt(argc, argv, "+p:d:r:s:b:k:n:w:")) != -1) {
        switch (c) {
        case 'p': fwdir = optarg; break;
        case 'd': devdir = optarg; break;
        case 'r': rundir = optarg; break;
        case 's': sysdir = optarg; break;
        case 'b': bootid_path = optarg; break;
        case 'k': kmsg_path = optarg; break;
        case 'n':
            if (number(optarg, &node_wait) < 0)
                return usage();
            break;
        case 'w':
            if (number(optarg, &verdict_wait) < 0)
                return usage();
            break;
        default: return usage();
        }
    }
    if (optind >= argc)
        return usage();
    const char* cmd = argv[optind++];
    int nargs = argc - optind;
    if (strcmp(cmd, "start") && strcmp(cmd, "nvram") && strcmp(cmd, "wifi-on"))
        return usage();
    if (strcmp(cmd, "nvram") && nargs)
        return usage();
    kmsg = open(kmsg_path, O_WRONLY | O_APPEND | O_NOCTTY | O_CLOEXEC);
    if (state_dir() < 0)
        return 1;
    if (!strcmp(cmd, "start"))
        return start();
    if (!strcmp(cmd, "nvram"))
        return nvram(nargs, argv + optind);
    return wifi_on();
}
