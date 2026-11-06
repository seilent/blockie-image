#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

static long env(const char* name, long def)
{
    const char* v = getenv(name);
    return v && *v ? strtol(v, NULL, 0) : def;
}

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

int fake_ioctl(int fd, unsigned long req, ...)
{
    va_list ap;
    va_start(ap, req);
    unsigned long arg = va_arg(ap, unsigned long);
    va_end(ap);
    (void)fd;
    long chip = env("FAKE_CHIP", 0x6768);
    switch ((unsigned)req) {
    case 0x4008a01f:
    case 0x4008a00f: {
        const uint8_t* p = (const uint8_t*)arg;
        uint32_t first;
        memcpy(&first, p, 4);
        trace("%s %u %02x%02x%02x%02x %s", req == 0x4008a01f ? "rom" : "patch", first, p[4], p[5], p[6], p[7], (const char*)p + 8);
        return 0;
    }
    default: trace("ioctl 0x%08x 0x%lx", (unsigned)req, arg);
    }
    switch ((unsigned)req) {
    case 0x8004770a: return (int)env("FAKE_HWINIT", 0);
    case 0x80047706: return -1;
    case 0x80047703: return (int)chip;
    case 0x80047709: return (int)env("FAKE_ADIE", 0);
    case 0x80047704: return (int)env("FAKE_MODINIT", 0);
    case 0x80047705: return (int)env("FAKE_CLEANUP", 0);
    case 0x8004a016: return (int)chip;
    case 0x8004a00c: return arg == 0 ? (int)chip : (int)env("FAKE_FWVER", 0x8a00);
    case 0x4004a007: {
        const char* hold = getenv("FAKE_HOLD");
        for (int i = 0; hold && i < 600 && access(hold, F_OK) != 0; i++)
            usleep(50000);
        trace("power done");
        return getenv("FAKE_POWER_FAIL") ? -1 : 0;
    }
    default: return 0;
    }
}

ssize_t fake_write(int fd, const void* buf, size_t n)
{
    const char* knob = getenv("FAKE_ENOSPC");
    if (knob && *knob) {
        char l[64], p[4096];
        snprintf(l, sizeof l, "/proc/self/fd/%d", fd);
        ssize_t k = readlink(l, p, sizeof p - 1);
        if (k > 0) {
            p[k] = 0;
            size_t kl = strlen(knob), pl = strlen(p);
            if (strstr(p, "/wmt/") && pl > kl && p[pl - kl - 1] == '/' && !strcmp(p + pl - kl, knob)) {
                errno = ENOSPC;
                return -1;
            }
        }
    }
    return syscall(SYS_write, fd, buf, n);
}
