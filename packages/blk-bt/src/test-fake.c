#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

static void trace(const char* fmt, ...)
{
    const char* p = getenv("FAKE_TRACE");
    if (!p)
        return;
    FILE* f = fopen(p, "a");
    if (!f)
        return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static int fd_path(int fd, char* b, size_t n)
{
    char p[64];
    snprintf(p, sizeof p, "/proc/self/fd/%d", fd);
    ssize_t r = readlink(p, b, n - 1);
    if (r < 0)
        return -1;
    b[r] = 0;
    return 0;
}

static int is_stpbt(int fd)
{
    const char* p = getenv("FAKE_STPBT");
    struct stat a, b;
    if (!p || syscall(SYS_fstat, fd, &a) != 0 || stat(p, &b) != 0)
        return 0;
    return S_ISCHR(a.st_mode) && S_ISCHR(b.st_mode) && a.st_rdev == b.st_rdev;
}

static int is_pty(int fd, char* b, size_t n)
{
    struct stat a;
    if (syscall(SYS_fstat, fd, &a) != 0 || !S_ISCHR(a.st_mode) || fd_path(fd, b, n) < 0)
        return 0;
    return !strncmp(b, "/dev/pts/", 9) || strstr(b, "ptmx") != NULL;
}

static int ctl_says(const char* word)
{
    const char* p = getenv("FAKE_CTL");
    char b[64];
    if (!p)
        return 0;
    FILE* f = fopen(p, "r");
    if (!f)
        return 0;
    size_t r = fread(b, 1, sizeof b - 1, f);
    fclose(f);
    b[r] = 0;
    return strstr(b, word) != NULL;
}

int fake_ioctl(int fd, unsigned long req, ...)
{
    if ((unsigned)req == 0x540c) {
        trace("ioctl TIOCEXCL");
        return 0;
    }
    va_list ap;
    va_start(ap, req);
    unsigned long arg = va_arg(ap, unsigned long);
    va_end(ap);
    char p[PATH_MAX] = "";
    const char* fail = getenv("FAKE_FAIL_IOCTL");
    switch ((unsigned)req) {
    case 0x5423:
        fd_path(fd, p, sizeof p);
        trace("ioctl TIOCSETD %d %s", *(int*)arg, p);
        if (fail && !strcmp(fail, "TIOCSETD"))
            return errno = EINVAL, -1;
        return 0;
    case 0x400455cb:
        trace("ioctl HCIUARTSETFLAGS %lu", arg);
        if (fail && !strcmp(fail, "HCIUARTSETFLAGS"))
            return errno = EINVAL, -1;
        return 0;
    case 0x400455c8:
        trace("ioctl HCIUARTSETPROTO %lu", arg);
        if (fail && !strcmp(fail, "HCIUARTSETPROTO"))
            return errno = EBUSY, -1;
        return 0;
    case 0x800455ca: {
        trace("ioctl HCIUARTGETDEVICE");
        if (getenv("FAKE_DROP_SLAVE")) {
            int n = open("/dev/null", O_RDWR);
            dup2(n, fd);
            syscall(SYS_close, n);
            trace("slave dropped");
        }
        const char* h = getenv("FAKE_HCI");
        return h ? atoi(h) : 0;
    }
    }
    return (int)syscall(SYS_ioctl, fd, req, arg);
}

ssize_t fake_write(int fd, const void* b, size_t n)
{
    char p[PATH_MAX];
    const char* full = getenv("FAKE_ENOSPC");
    if (full && fd_path(fd, p, sizeof p) == 0) {
        const char* base = strrchr(p, '/');
        if (base && !strcmp(base + 1, full))
            return errno = ENOSPC, -1;
    }
    if (is_stpbt(fd)) {
        if (ctl_says("eintr")) {
            trace("w-eintr");
            return errno = EINTR, -1;
        }
        if (ctl_says("eio")) {
            trace("w-eio");
            return errno = EIO, -1;
        }
        if (ctl_says("eagain")) {
            trace("w-eagain");
            return errno = EAGAIN, -1;
        }
        char h[2 * 2048 + 1];
        size_t m = n > 2048 ? 2048 : n;
        for (size_t i = 0; i < m; i++)
            snprintf(h + 2 * i, 3, "%02x", ((const unsigned char*)b)[i]);
        h[2 * m] = 0;
        trace("w %s", h);
    }
    return syscall(SYS_write, fd, b, n);
}

ssize_t fake_read(int fd, void* b, size_t n)
{
    static int flags_seen;
    char p[PATH_MAX];
    const char* st = getenv("FAKE_STATE");
    if (is_stpbt(fd)) {
        if (n > 2048)
            trace("r-over %zu", n);
        if (!flags_seen) {
            flags_seen = 1;
            trace("stpbt nonblock=%d", (int)((syscall(SYS_fcntl, fd, F_GETFL) & O_NONBLOCK) != 0));
        }
    } else if (st && fd_path(fd, p, sizeof p) == 0 && !strncmp(p, st, strlen(st)) && p[strlen(st)] == '/') {
        trace("read %s", p + strlen(st) + 1);
    }
    return syscall(SYS_read, fd, b, n);
}

int fake_flock(int fd, int op)
{
    trace("flock %d", op);
    return (int)syscall(SYS_flock, fd, op);
}

int fake_close(int fd)
{
    char p[PATH_MAX];
    const char* st = getenv("FAKE_STATE");
    int stp = is_stpbt(fd);
    if (stp || is_pty(fd, p, sizeof p)) {
        char m[64] = "none";
        if (st) {
            char q[PATH_MAX];
            snprintf(q, sizeof q, "%s/bt", st);
            FILE* f = fopen(q, "r");
            if (f) {
                if (!fgets(m, sizeof m, f))
                    strcpy(m, "empty");
                m[strcspn(m, "\n")] = 0;
                fclose(f);
            }
        }
        trace("close %s bt=%s", stp ? "stpbt" : (strstr(p, "ptmx") ? "ptm" : "pts"), m);
    }
    return (int)syscall(SYS_close, fd);
}
