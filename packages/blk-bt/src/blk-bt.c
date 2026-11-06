#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/un.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#define LDISC_HCI 15
#define HCIUARTSETPROTO _IOW('U', 200, int)
#define HCIUARTGETDEVICE _IOR('U', 202, int)
#define HCIUARTSETFLAGS _IOW('U', 203, int)
#define UART_RESET_ON_INIT 0x02
#define UART_H4 0

#define MAX_OPENS 20
#define CHIP_MAX 1996
#define READ_MAX 2048
#define CTL_BUF 8192
#define HOST_BUF 8192
#define OUTQ 65536
#define OUTQ_ROOM (2048 + 1028)
#define HELD_MAX 16384
#define CHIPQ 16384
#define REC_LEN 438
#define REC_FILE 440
#define OWN_MAX 8
#define INIT_WAIT_MS 8000
#define RESET_FC1A_MS 5000
#define HWERR_WAIT_MS 30000
#define EAGAIN_STEP_MS 30
#define EAGAIN_MAX_MS 1000
#define PARTIAL_MS 100

#define OP_RESET 0x0c03
#define OP_SYNC_TRAIN 0x0c77
#define OP_LOCAL_CMDS 0x1002
#define OP_BDADDR 0x1009
#define OP_BUFSIZE 0x1005
#define ACL_MAX (CHIP_MAX - 5)
#define OP_FC1A 0xfc1a
#define OP_FC79 0xfc79
#define OP_FC93 0xfc93
#define OP_FC7A 0xfc7a
#define OP_FD5B 0xfd5b

struct buf {
    uint8_t* d;
    size_t n;
    size_t cap;
};

struct own {
    uint16_t op;
    long long deadline;
    int on_reset;
    int wait_ms;
    int sent;
    uint8_t b[32];
    size_t n;
};

static const char* devdir = "/dev";
static const char* rundir = "/run/blockie";
static const char* sysdir = "/sys";
static const char* bootid_path = "/proc/sys/kernel/random/boot_id";
static const char* kmsg_path = "/dev/kmsg";
static const char* nvram_paths[8] = {
    "/run/vendor/nvdata/APCFG/APRDEB/BT_Addr",
    "/mnt/vendor/nvdata/APCFG/APRDEB/BT_Addr",
    "/vendor/nvdata-fallback/APCFG/APRDEB/BT_Addr",
};
static int n_nvram = 3;
static int no_reset_fc1a, le_if_zero, sw79, sw93, sw7a;
static char state[PATH_MAX];
static char nonce[40] = "-";
static int kmsg = -1, pmsg = -1, lockfd = -1;
static int stp = -1, ptm = -1, pts = -1;
static volatile sig_atomic_t stop;
static uint8_t rec[REC_FILE];
static struct buf ctl, host, outq, held, chipq;
static uint8_t held_reset[260];
static size_t held_reset_n;
static struct own owns[OWN_MAX];
static int n_own;
static long long retry_at, eagain_since, host_last;
static int resync;
static int out_full;
static unsigned c_partial, c_resync, c_full, c_sync, c_fd5b, c_early;
static int bdaddr_seen;
static unsigned stp_major = 192, stp_minor = 0;
static sigset_t waitmask;

static long long now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (long long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static void emit(int fd, const char* b, size_t n)
{
    if (fd >= 0) {
        ssize_t r = write(fd, b, n);
        (void)r;
    }
}

static void mark(const char* fmt, ...)
{
    char b[512];
    struct timespec t;
    clock_gettime(CLOCK_BOOTTIME, &t);
    int n = snprintf(b, sizeof b, "blockie: %s bt up=%lld.%02ld ", nonce, (long long)t.tv_sec, t.tv_nsec / 10000000);
    va_list ap;
    va_start(ap, fmt);
    n += vsnprintf(b + n, sizeof b - (size_t)n, fmt, ap);
    va_end(ap);
    if (n > (int)sizeof b - 2)
        n = (int)sizeof b - 2;
    b[n++] = '\n';
    b[n] = 0;
    emit(kmsg, b, (size_t)n);
    emit(pmsg, b, (size_t)n);
    emit(1, b, (size_t)n);
}

static int path(char* b, size_t n, const char* dir, const char* name)
{
    int r = snprintf(b, n, "%s/%s", dir, name);
    return r < 0 || (size_t)r >= n ? -1 : 0;
}

static int put(const char* name, const char* fmt, ...)
{
    char p[PATH_MAX], b[128];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(b, sizeof b - 1, fmt, ap);
    va_end(ap);
    if (n < 0 || n >= (int)sizeof b - 1 || path(p, sizeof p, state, name) < 0)
        return -1;
    b[n++] = '\n';
    int fd = open(p, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0)
        return -1;
    if (write(fd, b, (size_t)n) != n) {
        close(fd);
        return -1;
    }
    return close(fd);
}

static int put_bt(const char* v, int keep)
{
    char p[PATH_MAX], t[PATH_MAX], b[16];
    int n = snprintf(b, sizeof b, "%s\n", v);
    if (path(p, sizeof p, state, "bt") < 0 || path(t, sizeof t, state, "bt.tmp") < 0)
        return -1;
    int fd = open(p, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd >= 0) {
        int ok = write(fd, b, (size_t)n) == n;
        return close(fd) == 0 && ok ? 0 : -1;
    }
    if (errno != EEXIST)
        return -1;
    if (keep)
        return 1;
    fd = open(t, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0)
        return -1;
    int ok = write(fd, b, (size_t)n) == n;
    if (close(fd) != 0 || !ok || rename(t, p) != 0)
        return -1;
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

static int comm_is(int pid, const char* want)
{
    char p[64], b[256];
    if (pid <= 1 || kill(pid, 0) != 0)
        return 0;
    snprintf(p, sizeof p, "/proc/%d/stat", pid);
    if (slurp(p, b, sizeof b) < 0)
        return 0;
    char* name = strchr(b, '(');
    char* end = strrchr(b, ')');
    size_t w = strlen(want);
    return name && end && end > name && (size_t)(end - name - 1) == w && !strncmp(name + 1, want, w) && end[1] == ' ' &&
        end[2] && end[2] != 'Z';
}

static int pid_alive(const char* name, const char* comm)
{
    char v[32];
    if (get(name, v, sizeof v) < 0)
        return 0;
    return comm_is(atoi(v), comm);
}

static void close_all(void)
{
    if (pts >= 0)
        close(pts);
    if (ptm >= 0)
        close(ptm);
    if (stp >= 0)
        close(stp);
    pts = ptm = stp = -1;
}

static void drop_pid(void)
{
    char p[PATH_MAX];
    if (path(p, sizeof p, state, "bt.pid") == 0)
        unlink(p);
}

static void stats(void)
{
    mark("stats host_partial=%u host_resync=%u pty_full=%u sync_train=%u fd5b=%u early=%u", c_partial, c_resync, c_full, c_sync,
        c_fd5b, c_early);
}

static void fail(const char* why)
{
    int sw = put_bt("failed", 0) < 0;
    mark("failed why=%s", why);
    stats();
    close_all();
    drop_pid();
    mark("result rc=2 bt=failed%s", sw ? " state_write=failed" : "");
    exit(2);
}

static int hwerr_in(const uint8_t* b, size_t n)
{
    for (size_t i = 0; i + 2 < n; i++)
        if (b[i] == 0x04 && b[i + 1] == 0x10 && b[i + 2] == 0x01)
            return 1;
    return 0;
}

static void reset_path(const char* trigger, int seen)
{
    int sw = put_bt("reset", 0) < 0;
    mark("reset trigger=%s", trigger);
    int expired = 0;
    if (!seen && stp >= 0) {
        long long end = now_ms() + HWERR_WAIT_MS;
        uint8_t b[READ_MAX + 2];
        size_t keep = 0;
        while (!seen && !stop) {
            long long left = end - now_ms();
            if (left <= 0) {
                expired = 1;
                break;
            }
            struct pollfd p = {stp, POLLIN, 0};
            struct timespec ts = {left / 1000, (left % 1000) * 1000000L};
            int r = ppoll(&p, 1, &ts, &waitmask);
            if (r < 0 && errno == EINTR)
                continue;
            if (r == 0) {
                expired = 1;
                break;
            }
            if (r < 0)
                break;
            ssize_t n = read(stp, b + keep, READ_MAX);
            if (n > 0) {
                size_t all = keep + (size_t)n;
                seen = hwerr_in(b, all);
                keep = all < 2 ? all : 2;
                memmove(b, b + all - keep, keep);
            } else if (n == 0 || (errno != EAGAIN && errno != EINTR)) {
                struct timespec t = {0, 50 * 1000000L};
                nanosleep(&t, NULL);
            }
        }
        if (expired && put_bt("failed", 0) < 0)
            sw = 1;
    }
    stats();
    close_all();
    drop_pid();
    mark("result rc=5 bt=%s hw_error=%s%s%s", expired ? "failed" : "reset", seen ? "yes" : "no", stop && !seen && !expired ? " stop=signal" : "",
        sw ? " state_write=failed" : "");
    exit(5);
}

static int buf_init(struct buf* b, size_t cap)
{
    b->d = malloc(cap);
    b->n = 0;
    b->cap = cap;
    return b->d ? 0 : -1;
}

static int buf_add(struct buf* b, const uint8_t* p, size_t n)
{
    if (b->cap - b->n < n)
        return -1;
    memcpy(b->d + b->n, p, n);
    b->n += n;
    return 0;
}

static void buf_drop(struct buf* b, size_t n)
{
    memmove(b->d, b->d + n, b->n - n);
    b->n -= n;
}

static int frame(const uint8_t* b, size_t n, int from_ctl, size_t* total)
{
    size_t h, len;
    if (n < 1)
        return 0;
    switch (b[0]) {
    case 0x01:
        if (from_ctl)
            return -1;
        h = 4;
        if (n < h)
            return 0;
        len = h + b[3];
        break;
    case 0x02:
        h = 5;
        if (n < h)
            return 0;
        len = h + (size_t)(b[3] | (b[4] << 8));
        if (from_ctl && len - h > 1024)
            return -2;
        break;
    case 0x03:
        h = 4;
        if (n < h)
            return 0;
        len = h + b[3];
        if (from_ctl && len - h > 252)
            return -2;
        break;
    case 0x04:
        if (!from_ctl)
            return -1;
        h = 3;
        if (n < h)
            return 0;
        len = h + b[2];
        break;
    case 0x05:
        h = 5;
        if (n < h)
            return 0;
        len = h + (size_t)((b[3] | (b[4] << 8)) & 0x3fff);
        if (from_ctl && len - h > 1024)
            return -2;
        break;
    default:
        return -1;
    }
    if (!from_ctl && len > CHIP_MAX)
        return -2;
    *total = len;
    return n >= len ? 1 : 0;
}

static void to_host(const uint8_t* p, size_t n)
{
    if (held_reset_n) {
        if (buf_add(&held, p, n) < 0)
            fail("held_overflow");
        return;
    }
    if (buf_add(&outq, p, n) < 0)
        fail("outq_overflow");
}

static void release_held(void)
{
    if (buf_add(&outq, held_reset, held_reset_n) < 0 || buf_add(&outq, held.d, held.n) < 0)
        fail("outq_overflow");
    held_reset_n = 0;
    held.n = 0;
}

static void queue_own(const uint8_t* p, size_t n, int on_reset, int wait_ms)
{
    if (n_own >= OWN_MAX || n > sizeof owns[0].b)
        fail("own_queue");
    struct own* o = &owns[n_own++];
    memcpy(o->b, p, n);
    o->n = n;
    o->op = (uint16_t)(p[1] | (p[2] << 8));
    o->on_reset = on_reset;
    o->wait_ms = wait_ms;
    o->sent = 0;
    o->deadline = 0;
}

static void send_fc1a(int on_reset, int wait_ms)
{
    uint8_t c[10] = {0x01, 0x1a, 0xfc, 0x06, rec[5], rec[4], rec[3], rec[2], rec[1], rec[0]};
    queue_own(c, sizeof c, on_reset, wait_ms);
}

static void send_switched(void)
{
    if (sw79) {
        uint8_t c[12] = {0x01, 0x79, 0xfc, 0x08};
        memcpy(c + 4, rec + 12, 6);
        memcpy(c + 10, rec + 36, 2);
        queue_own(c, sizeof c, 0, INIT_WAIT_MS);
    }
    if (sw93) {
        uint8_t c[20] = {0x01, 0x93, 0xfc, 0x10};
        memcpy(c + 4, rec + 27, 3);
        memcpy(c + 7, rec + 38, 3);
        memcpy(c + 10, rec + 41, 10);
        queue_own(c, sizeof c, 0, INIT_WAIT_MS);
    }
    if (sw7a) {
        uint8_t c[11] = {0x01, 0x7a, 0xfc, 0x07};
        memcpy(c + 4, rec + 18, 7);
        queue_own(c, sizeof c, 0, INIT_WAIT_MS);
    }
}

static int own_done(uint16_t op, int status, int is_status_event)
{
    for (int i = 0; i < n_own; i++) {
        if (owns[i].op != op || !owns[i].sent)
            continue;
        if (status != 0) {
            mark("own op=0x%04x status=0x%02x", op, status);
            fail("own_status");
        }
        if (is_status_event)
            return 1;
        int on_reset = owns[i].on_reset;
        memmove(owns + i, owns + i + 1, (size_t)(n_own - i - 1) * sizeof *owns);
        n_own--;
        if (on_reset)
            release_held();
        return 1;
    }
    return 0;
}

static void le_patch(uint8_t* p)
{
    uint8_t* o = p + 32;
    char orig[16];
    snprintf(orig, sizeof orig, "%02x%02x%02x%02x", o[0], o[1], o[2], o[3]);
    int zero = !(o[0] | o[1] | o[2] | o[3]);
    if (le_if_zero && !zero) {
        mark("le_patch=skipped orig=%s", orig);
        return;
    }
    o[0] |= 0xf7;
    o[1] |= 0xff;
    o[2] |= 0xff;
    o[3] |= 0x0f;
    mark("le_patch=applied orig=%s", orig);
}

static void ctl_packet(uint8_t* p, size_t n)
{
    if (p[0] == 0x04) {
        if (p[1] == 0x10)
            reset_path("hw_error", 1);
        int op = -1, status = -1, cs = 0;
        if (p[1] == 0x0e && n >= 6) {
            op = p[4] | (p[5] << 8);
            status = n >= 7 ? p[6] : 0;
        } else if (p[1] == 0x0f && n >= 7) {
            op = p[5] | (p[6] << 8);
            status = p[3];
            cs = 1;
        }
        if (op >= 0 && own_done((uint16_t)op, status, cs))
            return;
        if (p[1] == 0x0e && op == OP_RESET && status == 0 && !no_reset_fc1a && !held_reset_n) {
            if (n > sizeof held_reset)
                fail("reset_event");
            memcpy(held_reset, p, n);
            held_reset_n = n;
            send_fc1a(1, RESET_FC1A_MS);
            return;
        }
        if (p[1] == 0x0e && op == OP_LOCAL_CMDS && status == 0 && n >= 71)
            le_patch(p);
        if (p[1] == 0x0e && op == OP_BUFSIZE && status == 0 && n >= 9) {
            int acl = p[7] | (p[8] << 8);
            mark("acl_mtu=%d", acl);
            if (acl > ACL_MAX)
                fail("acl_mtu");
        }
        if (p[1] == 0x0e && op == OP_BDADDR && status == 0 && n >= 13) {
            int match = p[7] == rec[5] && p[8] == rec[4] && p[9] == rec[3] && p[10] == rec[2] && p[11] == rec[1] &&
                p[12] == rec[0];
            bdaddr_seen = 1;
            mark("bdaddr_match=%s", match ? "yes" : "no");
            if (!match && !no_reset_fc1a)
                fail("bdaddr_mismatch");
        }
    }
    to_host(p, n);
}

static void ctl_parse(void)
{
    for (;;) {
        size_t total = 0;
        int r = frame(ctl.d, ctl.n, 1, &total);
        if (r == 0)
            return;
        if (r == -1) {
            mark("ctl type=0x%02x", ctl.d[0]);
            fail("ctl_unknown_type");
        }
        if (r == -2)
            fail("ctl_over_limit");
        ctl_packet(ctl.d, total);
        buf_drop(&ctl, total);
    }
}

static void host_packet(const uint8_t* p, size_t n)
{
    if (p[0] == 0x01) {
        int op = p[1] | (p[2] << 8);
        if (op == OP_SYNC_TRAIN) {
            static const uint8_t r[] = {0x04, 0x0e, 0x0b, 0x01, 0x77, 0x0c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
            c_sync++;
            to_host(r, sizeof r);
            return;
        }
        if (op == OP_FD5B) {
            static const uint8_t r[] = {0x04, 0x0e, 0x04, 0x01, 0x5b, 0xfd, 0x01};
            c_fd5b++;
            mark("host fd5b answered locally");
            to_host(r, sizeof r);
            return;
        }
    }
    uint8_t l[2] = {(uint8_t)(n & 0xff), (uint8_t)(n >> 8)};
    if (buf_add(&chipq, l, 2) < 0 || buf_add(&chipq, p, n) < 0)
        fail("chipq_overflow");
}

static void host_parse(void)
{
    static const uint8_t reset[4] = {0x01, 0x03, 0x0c, 0x00};
    for (;;) {
        if (resync) {
            size_t i = 0;
            while (i + 4 <= host.n && memcmp(host.d + i, reset, 4))
                i++;
            if (i + 4 <= host.n) {
                buf_drop(&host, i);
                resync = 0;
            } else {
                size_t keep = host.n < 3 ? host.n : 3;
                buf_drop(&host, host.n - keep);
                return;
            }
        }
        size_t total = 0;
        int r = frame(host.d, host.n, 0, &total);
        if (r == 0)
            return;
        if (r < 0) {
            c_resync++;
            mark("host resync type=0x%02x why=%s", host.d[0], r == -1 ? "type" : "length");
            resync = 1;
            buf_drop(&host, 1);
            continue;
        }
        host_packet(host.d, total);
        buf_drop(&host, total);
    }
}

static int write_chip(const uint8_t* p, size_t n)
{
    ssize_t r = write(stp, p, n);
    if (r == (ssize_t)n) {
        eagain_since = 0;
        retry_at = 0;
        return 1;
    }
    if (r < 0 && errno == EINTR) {
        retry_at = now_ms();
        return 0;
    }
    if (r < 0 && errno == EAGAIN) {
        long long t = now_ms();
        if (!eagain_since)
            eagain_since = t;
        if (t - eagain_since >= EAGAIN_MAX_MS)
            fail("eagain");
        retry_at = t + EAGAIN_STEP_MS;
        return 0;
    }
    if (r < 0 && errno == EIO)
        reset_path("write_eio", 0);
    if (r < 0)
        mark("write errno=%d", errno);
    fail("write");
    return 0;
}

static void chip_step(void)
{
    if (retry_at && now_ms() < retry_at)
        return;
    if (n_own) {
        if (owns[0].sent)
            return;
        if (write_chip(owns[0].b, owns[0].n)) {
            owns[0].sent = 1;
            owns[0].deadline = now_ms() + owns[0].wait_ms;
        }
        return;
    }
    while (chipq.n >= 2) {
        size_t n = (size_t)(chipq.d[0] | (chipq.d[1] << 8));
        if (!write_chip(chipq.d + 2, n))
            return;
        buf_drop(&chipq, n + 2);
    }
}

static void read_ctl(void)
{
    size_t room = ctl.cap - ctl.n;
    if (room > READ_MAX)
        room = READ_MAX;
    if (!room)
        fail("ctl_buffer");
    ssize_t r = read(stp, ctl.d + ctl.n, room);
    if (r > 0) {
        ctl.n += (size_t)r;
        ctl_parse();
    } else if (r == 0) {
        fail("stpbt_eof");
    } else if (errno != EAGAIN && errno != EINTR) {
        mark("read errno=%d", errno);
        fail("stpbt_read");
    }
}

static void read_host(void)
{
    if (host.cap == host.n)
        fail("host_buffer");
    ssize_t r = read(ptm, host.d + host.n, host.cap - host.n);
    if (r > 0) {
        host.n += (size_t)r;
        host_last = now_ms();
        host_parse();
    } else if (r == 0 || (errno != EAGAIN && errno != EINTR)) {
        fail("pty_read");
    }
}

static void write_host(void)
{
    while (outq.n) {
        ssize_t r = write(ptm, outq.d, outq.n);
        if (r > 0) {
            buf_drop(&outq, (size_t)r);
            continue;
        }
        if (r < 0 && (errno == EAGAIN || errno == EINTR))
            return;
        fail("pty_write");
    }
}

static void wait_own(void)
{
    while (n_own && !stop) {
        chip_step();
        if (!n_own)
            break;
        long long t = now_ms();
        int ms = owns[0].sent ? (int)(owns[0].deadline - t) : EAGAIN_STEP_MS;
        if (owns[0].sent && ms <= 0) {
            mark("own op=0x%04x timeout", owns[0].op);
            fail(owns[0].op == OP_FC1A ? "fc1a_timeout" : "own_timeout");
        }
        if (retry_at && retry_at - t < ms)
            ms = (int)(retry_at - t) < 1 ? 1 : (int)(retry_at - t);
        struct pollfd p = {stp, POLLIN, 0};
        struct timespec ts = {ms / 1000, (ms % 1000) * 1000000L};
        int r = ppoll(&p, 1, &ts, &waitmask);
        if (r < 0 && errno != EINTR)
            fail("poll");
        if (r > 0 && (p.revents & (POLLERR | POLLHUP | POLLNVAL)) && !(p.revents & POLLIN))
            fail("stpbt_poll");
        if (r > 0 && (p.revents & POLLIN)) {
            size_t before = outq.n;
            read_ctl();
            c_early += outq.n != before;
            outq.n = before;
        }
    }
}

static void notify_ready(void)
{
    const char* e = getenv("NOTIFY_SOCKET");
    if (!e || !*e)
        return;
    struct sockaddr_un a;
    memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    size_t n = strlen(e);
    if (n >= sizeof a.sun_path) {
        mark("notify=failed why=path");
        return;
    }
    memcpy(a.sun_path, e, n);
    if (a.sun_path[0] == '@')
        a.sun_path[0] = 0;
    int s = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (s < 0 || sendto(s, "READY=1", 7, MSG_NOSIGNAL, (struct sockaddr*)&a, (socklen_t)(offsetof(struct sockaddr_un, sun_path) + n)) != 7)
        mark("notify=failed errno=%d", errno);
    else
        mark("notify=ready");
    if (s >= 0)
        close(s);
}

static void setup_pty(void)
{
    char name[128];
    ptm = posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC);
    if (ptm < 0 || grantpt(ptm) < 0 || unlockpt(ptm) < 0 || ptsname_r(ptm, name, sizeof name) != 0)
        fail("pty_open");
    pts = open(name, O_RDWR | O_NOCTTY | O_CLOEXEC);
    if (pts < 0 || fchmod(pts, 0600) < 0)
        fail("pty_slave");
    if (ioctl(pts, TIOCEXCL) < 0)
        fail("pty_excl");
    struct termios t;
    if (tcgetattr(pts, &t) < 0)
        fail("pty_termios");
    cfmakeraw(&t);
    if (tcsetattr(pts, TCSANOW, &t) < 0)
        fail("pty_termios");
    int fl = fcntl(ptm, F_GETFL);
    if (fl < 0 || fcntl(ptm, F_SETFL, fl | O_NONBLOCK) < 0)
        fail("pty_nonblock");
    int ld = LDISC_HCI;
    if (ioctl(pts, TIOCSETD, &ld) < 0)
        fail("ldisc");
    if (ioctl(pts, HCIUARTSETFLAGS, (unsigned long)UART_RESET_ON_INIT) < 0)
        fail("uart_flags");
    if (ioctl(pts, HCIUARTSETPROTO, (unsigned long)UART_H4) < 0)
        fail("uart_proto");
    int idx = ioctl(pts, HCIUARTGETDEVICE, 0UL);
    if (idx < 0)
        fail("uart_device");
    mark("hci=%d", idx);
    notify_ready();
}

static void loop(void)
{
    for (;;) {
        if (stop) {
            if (n_own)
                fail("stop_with_own_command");
            stats();
            close_all();
            drop_pid();
            mark("result rc=0 stop=signal bdaddr_seen=%s", bdaddr_seen ? "yes" : "no");
            exit(0);
        }
        long long t = now_ms();
        if (host.n && !resync && t - host_last >= PARTIAL_MS) {
            c_partial++;
            mark("host partial bytes=%zu dropped", host.n);
            host.n = 0;
            resync = 1;
        }
        for (int i = 0; i < n_own; i++)
            if (owns[i].sent && t >= owns[i].deadline) {
                mark("own op=0x%04x timeout", owns[i].op);
                fail(owns[i].op == OP_FC1A ? "fc1a_timeout" : "own_timeout");
            }
        chip_step();
        int full = outq.cap - outq.n < OUTQ_ROOM;
        if (full && !out_full)
            c_full++;
        out_full = full;
        int ms = 1000;
        if (host.n && !resync && host_last + PARTIAL_MS - t < ms)
            ms = (int)(host_last + PARTIAL_MS - t);
        for (int i = 0; i < n_own; i++)
            if (owns[i].sent && owns[i].deadline - t < ms)
                ms = (int)(owns[i].deadline - t);
        if (retry_at && retry_at - t < ms)
            ms = (int)(retry_at - t);
        if (ms < 1)
            ms = 1;
        struct pollfd p[2] = {{stp, (short)(full ? 0 : POLLIN), 0}, {ptm, (short)(POLLIN | (outq.n ? POLLOUT : 0)), 0}};
        struct timespec ts = {ms / 1000, (ms % 1000) * 1000000L};
        int r = ppoll(p, 2, &ts, &waitmask);
        if (r < 0) {
            if (errno == EINTR)
                continue;
            fail("poll");
        }
        if (p[0].revents & POLLIN)
            read_ctl();
        else if (p[0].revents & (POLLERR | POLLHUP | POLLNVAL))
            fail("stpbt_poll");
        if (p[1].revents & POLLIN)
            read_host();
        else if (p[1].revents & (POLLERR | POLLHUP | POLLNVAL))
            fail("pty_poll");
        if (outq.n)
            write_host();
    }
}

static int load_nvram(void)
{
    for (int i = 0; i < n_nvram; i++) {
        struct stat st;
        if (lstat(nvram_paths[i], &st) != 0)
            continue;
        int fd = open(nvram_paths[i], O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_NOCTTY | O_CLOEXEC);
        if (fd < 0 || fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || (st.st_size != REC_LEN && st.st_size != REC_FILE)) {
            mark("refused why=nvram file=%s size=%lld", nvram_paths[i], fd < 0 ? -1LL : (long long)st.st_size);
            if (fd >= 0)
                close(fd);
            return -1;
        }
        ssize_t r = read(fd, rec, REC_LEN);
        close(fd);
        if (r != REC_LEN) {
            mark("refused why=nvram_read file=%s", nvram_paths[i]);
            return -1;
        }
        int zero = 1, ff = 1;
        for (int j = 0; j < 6; j++) {
            zero &= rec[j] == 0x00;
            ff &= rec[j] == 0xff;
        }
        if (zero || ff) {
            mark("refused why=nvram_address file=%s", nvram_paths[i]);
            return -1;
        }
        mark("nvram file=%s size=%lld", nvram_paths[i], (long long)st.st_size);
        return 0;
    }
    mark("refused why=no_nvram");
    return -1;
}

static int find_state(void)
{
    char id[64], top[PATH_MAX];
    struct stat st;
    if (stat(rundir, &st) != 0 || !S_ISDIR(st.st_mode)) {
        mark("refused why=no_rundir");
        return 1;
    }
    if (slurp(bootid_path, id, sizeof id) < 0 || strlen(id) != 36 || strspn(id, "0123456789abcdef-") != 36) {
        mark("refused why=boot_id");
        return 1;
    }
    if (path(top, sizeof top, rundir, "wmt") < 0 || path(state, sizeof state, top, id) < 0)
        return 1;
    return 0;
}

static void word(char* b, size_t n, const char* v)
{
    size_t j = 0;
    for (size_t i = 0; v && v[i] && j + 1 < n; i++)
        if ((v[i] >= 'a' && v[i] <= 'z') || v[i] == '-')
            b[j++] = v[i];
    b[j] = 0;
    if (!j)
        snprintf(b, n, "none");
}

static int stop_post(void)
{
    char v[64], res[24], code[24], p[PATH_MAX];
    struct stat st;
    int r = find_state();
    if (r)
        return r;
    const char* sr = getenv("SERVICE_RESULT");
    word(res, sizeof res, sr);
    word(code, sizeof code, getenv("EXIT_CODE"));
    if (!sr || !strcmp(sr, "success")) {
        mark("stop_post end=%s", res);
        return 0;
    }
    if (lstat(state, &st) != 0 || !S_ISDIR(st.st_mode) || path(p, sizeof p, state, "bt.lock") < 0) {
        mark("stop_post why=no_state end=%s", res);
        return 1;
    }
    const char* lock = "";
    lockfd = open(p, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (lockfd < 0)
        lock = " lock=open_failed";
    else if (flock(lockfd, LOCK_EX | LOCK_NB) < 0)
        lock = " lock=busy";
    int w = put_bt("failed", 1);
    if (w == 1) {
        if (get("bt", v, sizeof v) < 0)
            strcpy(v, "empty");
        mark("stop_post bt=%s untouched end=%s%s", strspn(v, "abcdefghijklmnopqrstuvwxyz") == strlen(v) ? v : "unknown", res, lock);
        return 0;
    }
    if (w < 0) {
        mark("stop_post state_write=failed end=%s code=%s%s", res, code, lock);
        return 1;
    }
    mark("stop_post bt=failed end=%s code=%s%s", res, code, lock);
    return 0;
}

static int gate(void)
{
    char v[64], p[PATH_MAX];
    struct stat st;
    int fs = find_state();
    if (fs)
        return fs;
    if (lstat(state, &st) != 0 || !S_ISDIR(st.st_mode)) {
        mark("refused why=no_power_on");
        return 4;
    }
    if (path(p, sizeof p, state, "bt.lock") < 0)
        return 1;
    lockfd = open(p, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (lockfd < 0) {
        mark("refused why=lock_open");
        return 1;
    }
    if (flock(lockfd, LOCK_EX | LOCK_NB) < 0) {
        mark("refused why=locked");
        return 4;
    }
    if (get("once.power", v, sizeof v) < 0) {
        mark("refused why=no_power_on");
        return 4;
    }
    if (get("launcher", v, sizeof v) < 0 || strcmp(v, "yes")) {
        mark("refused why=launcher");
        return 4;
    }
    if (!pid_alive("pid", "blk-wmt")) {
        mark("refused why=launcher_dead");
        return 4;
    }
    if (get("wifi", v, sizeof v) < 0 || strcmp(v, "on")) {
        mark("refused why=wifi");
        return 4;
    }
    if (path(p, sizeof p, sysdir, "class/net/wlan0") < 0 || stat(p, &st) != 0) {
        mark("refused why=no_wlan0");
        return 4;
    }
    if (path(p, sizeof p, state, "bt") < 0)
        return 1;
    if (lstat(p, &st) == 0) {
        if (get("bt", v, sizeof v) < 0)
            strcpy(v, "empty");
        mark("refused why=bt_%s", strspn(v, "abcdefghijklmnopqrstuvwxyz") == strlen(v) ? v : "unknown");
        return 4;
    }
    if (pid_alive("bt.pid", "blk-bt")) {
        mark("refused why=bt_running");
        return 4;
    }
    long opens = 0;
    if (get("bt.opens", v, sizeof v) == 0) {
        char* end;
        errno = 0;
        opens = strtol(v, &end, 10);
        if (errno || end == v || *end || opens < 0) {
            mark("refused why=opens_unreadable");
            return 4;
        }
    } else {
        if (path(p, sizeof p, state, "bt.opens") < 0)
            return 1;
        if (lstat(p, &st) == 0) {
            mark("refused why=opens_unreadable");
            return 4;
        }
    }
    if (opens >= MAX_OPENS) {
        mark("refused why=opens opens=%ld", opens);
        return 4;
    }
    if (put("bt.pid", "%d", (int)getpid()) < 0 || put("bt.opens", "%ld", opens + 1) < 0) {
        drop_pid();
        mark("refused why=state_write");
        return 1;
    }
    return 0;
}

static void on_signal(int s)
{
    (void)s;
    stop = 1;
}

static int usage(void)
{
    fprintf(stderr, "usage: blk-bt [-r rundir] [-d devdir] [-s sysdir] [-b boot_id] [-k kmsg] [-n nvram]... [--no-reset-fc1a]\n"
                    "              [--le-patch-if-zero] [--fc79] [--fc93] [--fc7a] [--stpbt-dev major:minor] run | stop-post\n");
    return 1;
}

int main(int argc, char** argv)
{
    static const struct option lo[] = {
        {"no-reset-fc1a", no_argument, &no_reset_fc1a, 1},
        {"le-patch-if-zero", no_argument, &le_if_zero, 1},
        {"fc79", no_argument, &sw79, 1},
        {"fc93", no_argument, &sw93, 1},
        {"fc7a", no_argument, &sw7a, 1},
        {"stpbt-dev", required_argument, NULL, 'D'},
        {0, 0, 0, 0},
    };
    int c, own_n = 0;
    while ((c = getopt_long(argc, argv, "+r:d:s:b:k:n:", lo, NULL)) != -1) {
        switch (c) {
        case 0: break;
        case 'r': rundir = optarg; break;
        case 'd': devdir = optarg; break;
        case 's': sysdir = optarg; break;
        case 'b': bootid_path = optarg; break;
        case 'k': kmsg_path = optarg; break;
        case 'D':
            if (sscanf(optarg, "%u:%u", &stp_major, &stp_minor) != 2)
                return usage();
            break;
        case 'n':
            if (own_n >= (int)(sizeof nvram_paths / sizeof *nvram_paths))
                return usage();
            nvram_paths[own_n++] = optarg;
            n_nvram = own_n;
            break;
        default: return usage();
        }
    }
    if (optind != argc - 1 || (strcmp(argv[optind], "run") && strcmp(argv[optind], "stop-post")))
        return usage();
    int post = !strcmp(argv[optind], "stop-post");
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_signal;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigset_t block;
    sigemptyset(&block);
    sigaddset(&block, SIGTERM);
    sigaddset(&block, SIGINT);
    sigprocmask(SIG_BLOCK, &block, &waitmask);
    sigdelset(&waitmask, SIGTERM);
    sigdelset(&waitmask, SIGINT);
    signal(SIGHUP, SIG_IGN);
    signal(SIGPIPE, SIG_IGN);
    kmsg = open(kmsg_path, O_WRONLY | O_APPEND | O_NOCTTY | O_CLOEXEC);
    char p[PATH_MAX];
    if (path(p, sizeof p, devdir, "pmsg0") == 0)
        pmsg = open(p, O_WRONLY | O_APPEND | O_NOCTTY | O_CLOEXEC);
    char nb[PATH_MAX];
    if (path(nb, sizeof nb, rundir, "nonce") == 0 && slurp(nb, p, sizeof p) == 0 && strlen(p) < sizeof nonce &&
        strspn(p, "0123456789abcdef") == strlen(p))
        strcpy(nonce, p);
    if (post)
        return stop_post();
    if (buf_init(&ctl, CTL_BUF) || buf_init(&host, HOST_BUF) || buf_init(&outq, OUTQ) || buf_init(&held, HELD_MAX) ||
        buf_init(&chipq, CHIPQ))
        return 1;
    int g = gate();
    if (g)
        return g;
    if (load_nvram() < 0) {
        drop_pid();
        return 1;
    }
    struct stat st;
    if (path(p, sizeof p, devdir, "stpbt") < 0 || stat(p, &st) != 0 || !S_ISCHR(st.st_mode)) {
        mark("refused why=no_stpbt");
        drop_pid();
        return 1;
    }
    if (major(st.st_rdev) != stp_major || minor(st.st_rdev) != stp_minor) {
        mark("refused why=stpbt_node node=%u:%u", major(st.st_rdev), minor(st.st_rdev));
        drop_pid();
        return 1;
    }
    struct timespec bt;
    clock_gettime(CLOCK_BOOTTIME, &bt);
    mark("open start t=%lld", (long long)bt.tv_sec * 1000 + bt.tv_nsec / 1000000);
    long long t0 = now_ms();
    stp = open(p, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC);
    if (stp < 0) {
        mark("open errno=%d", errno);
        fail("open");
    }
    mark("open done ms=%lld", now_ms() - t0);
    send_fc1a(0, INIT_WAIT_MS);
    send_switched();
    wait_own();
    if (stop && n_own)
        fail("stop_with_own_command");
    if (stop) {
        close_all();
        drop_pid();
        mark("result rc=0 stop=signal");
        return 0;
    }
    mark("init fc1a=ok fc79=%s fc93=%s fc7a=%s", sw79 ? "ok" : "off", sw93 ? "ok" : "off", sw7a ? "ok" : "off");
    setup_pty();
    loop();
    return 0;
}
