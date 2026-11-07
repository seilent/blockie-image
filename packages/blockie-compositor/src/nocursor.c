#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>

#define PLANE_TYPE_CURSOR 2

typedef int (*ioctl_fn)(int, unsigned long, ...);

static ioctl_fn next_ioctl;
static int refused_logged;

static ioctl_fn real(void)
{
    ioctl_fn f = __atomic_load_n(&next_ioctl, __ATOMIC_ACQUIRE);
    if (!f) {
        f = (ioctl_fn)dlsym(RTLD_NEXT, "ioctl");
        __atomic_store_n(&next_ioctl, f, __ATOMIC_RELEASE);
    }
    return f;
}

static void say(const char* fmt, ...)
{
    char b[160];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(b, sizeof b, fmt, ap);
    va_end(ap);
    if (n > 0) {
        ssize_t r = write(2, b, (size_t)n < sizeof b ? (size_t)n : sizeof b - 1);
        (void)r;
    }
}

static int plane_type(ioctl_fn f, int fd, uint32_t id)
{
    struct drm_mode_obj_get_properties op = { .obj_id = id, .obj_type = DRM_MODE_OBJECT_PLANE };
    if (f(fd, DRM_IOCTL_MODE_OBJ_GETPROPERTIES, &op) || op.count_props == 0)
        return -1;
    uint32_t n = op.count_props;
    uint32_t* props = calloc(n, sizeof *props);
    uint64_t* vals = calloc(n, sizeof *vals);
    int type = -1;
    if (props && vals) {
        op.props_ptr = (uintptr_t)props;
        op.prop_values_ptr = (uintptr_t)vals;
        op.count_props = n;
        if (f(fd, DRM_IOCTL_MODE_OBJ_GETPROPERTIES, &op) == 0) {
            if (op.count_props < n)
                n = op.count_props;
            for (uint32_t i = 0; i < n && type < 0; i++) {
                struct drm_mode_get_property gp = { .prop_id = props[i] };
                if (f(fd, DRM_IOCTL_MODE_GETPROPERTY, &gp) == 0 && strncmp(gp.name, "type", sizeof gp.name) == 0)
                    type = (int)vals[i];
            }
        }
    }
    free(props);
    free(vals);
    return type;
}

static void hide_cursor_planes(ioctl_fn f, int fd, struct drm_mode_get_plane_res* res)
{
    uint32_t* ids = (uint32_t*)(uintptr_t)res->plane_id_ptr;
    uint32_t kept = 0;
    for (uint32_t i = 0; i < res->count_planes; i++) {
        if (plane_type(f, fd, ids[i]) != PLANE_TYPE_CURSOR)
            ids[kept++] = ids[i];
    }
    if (kept < res->count_planes)
        say("blockie-nocursor: hid %u cursor planes of %u\n", res->count_planes - kept, res->count_planes);
    res->count_planes = kept;
}

static int cursor_request(unsigned long req, void* arg)
{
    uint32_t flags = 0, handle = 0;
    if (req == DRM_IOCTL_MODE_CURSOR) {
        struct drm_mode_cursor* c = arg;
        flags = c->flags;
        handle = c->handle;
    } else {
        struct drm_mode_cursor2* c = arg;
        flags = c->flags;
        handle = c->handle;
    }
    if ((flags & DRM_MODE_CURSOR_BO) && handle == 0)
        return 0;
    if (!__atomic_exchange_n(&refused_logged, 1, __ATOMIC_RELAXED))
        say("blockie-nocursor: refused a cursor ioctl (flags 0x%x)\n", flags);
    errno = EOPNOTSUPP;
    return -1;
}

int ioctl(int fd, unsigned long req, ...)
{
    va_list ap;
    va_start(ap, req);
    void* arg = va_arg(ap, void*);
    va_end(ap);
    if (req == DRM_IOCTL_MODE_CURSOR || req == DRM_IOCTL_MODE_CURSOR2) {
        if (!arg) {
            errno = EFAULT;
            return -1;
        }
        return cursor_request(req, arg);
    }
    ioctl_fn f = real();
    if (!f) {
        errno = ENOSYS;
        return -1;
    }
    if (req != DRM_IOCTL_MODE_GETPLANERESOURCES || !arg)
        return f(fd, req, arg);
    struct drm_mode_get_plane_res* res = arg;
    uint32_t room = res->count_planes;
    int r = f(fd, req, arg);
    if (r == 0 && res->plane_id_ptr && res->count_planes && room >= res->count_planes)
        hide_cursor_planes(f, fd, res);
    return r;
}
