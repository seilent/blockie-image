#define _GNU_SOURCE
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>

#define FAKE_FD 1000
#define PROP_TYPE 100
#define PROP_ZPOS 101

static const uint32_t plane_ids[] = { 31, 32, 33, 34, 35, 36 };
static const uint64_t plane_types[] = { 1, 0, 2, 1, 0, 2 };

int fake_cursor_calls;
int fake_calls;
uint32_t fake_broken_plane;

static int plane_index(uint32_t id)
{
    for (int i = 0; i < 6; i++) {
        if (plane_ids[i] == id)
            return i;
    }
    return -1;
}

static int fake_drm(unsigned long req, void* arg)
{
    fake_calls++;
    if (req == DRM_IOCTL_MODE_CURSOR || req == DRM_IOCTL_MODE_CURSOR2) {
        fake_cursor_calls++;
        return 0;
    }
    if (req == DRM_IOCTL_MODE_GETPLANERESOURCES) {
        struct drm_mode_get_plane_res* r = arg;
        if (r->plane_id_ptr && r->count_planes >= 6)
            memcpy((void*)(uintptr_t)r->plane_id_ptr, plane_ids, sizeof plane_ids);
        r->count_planes = 6;
        return 0;
    }
    if (req == DRM_IOCTL_MODE_OBJ_GETPROPERTIES) {
        struct drm_mode_obj_get_properties* o = arg;
        int i = plane_index(o->obj_id);
        if (i < 0 || o->obj_type != DRM_MODE_OBJECT_PLANE || o->obj_id == fake_broken_plane) {
            errno = ENOENT;
            return -1;
        }
        if (o->count_props >= 2 && o->props_ptr && o->prop_values_ptr) {
            uint32_t* p = (uint32_t*)(uintptr_t)o->props_ptr;
            uint64_t* v = (uint64_t*)(uintptr_t)o->prop_values_ptr;
            p[0] = PROP_ZPOS;
            v[0] = (uint64_t)i;
            p[1] = PROP_TYPE;
            v[1] = plane_types[i];
        }
        o->count_props = 2;
        return 0;
    }
    if (req == DRM_IOCTL_MODE_GETPROPERTY) {
        struct drm_mode_get_property* g = arg;
        if (g->prop_id != PROP_TYPE && g->prop_id != PROP_ZPOS) {
            errno = ENOENT;
            return -1;
        }
        memset(g->name, 0, sizeof g->name);
        strcpy(g->name, g->prop_id == PROP_TYPE ? "type" : "zpos");
        return 0;
    }
    errno = EINVAL;
    return -1;
}

int ioctl(int fd, unsigned long req, ...)
{
    va_list ap;
    va_start(ap, req);
    void* arg = va_arg(ap, void*);
    va_end(ap);
    if (fd == FAKE_FD)
        return fake_drm(req, arg);
    return (int)syscall(SYS_ioctl, fd, req, arg);
}
