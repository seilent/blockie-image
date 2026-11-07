#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>

#define FAKE_FD 1000

extern int fake_cursor_calls;
extern int fake_calls;
extern uint32_t fake_broken_plane;

static int fails;

static void check(int ok, const char* what)
{
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok)
        fails++;
}

static int cursor(unsigned long req, uint32_t flags, uint32_t handle)
{
    struct drm_mode_cursor2 c = { .flags = flags, .crtc_id = 1, .handle = handle, .width = 64, .height = 64 };
    errno = 0;
    return ioctl(FAKE_FD, req, &c);
}

static uint32_t planes(uint32_t room, uint32_t* ids)
{
    struct drm_mode_get_plane_res r = { .plane_id_ptr = (uintptr_t)ids, .count_planes = room };
    if (ioctl(FAKE_FD, DRM_IOCTL_MODE_GETPLANERESOURCES, &r))
        return 0;
    return r.count_planes;
}

static int libdrm_style(uint32_t* out, uint32_t* retries)
{
    *retries = 0;
    for (;;) {
        struct drm_mode_get_plane_res res = { 0 };
        if (ioctl(FAKE_FD, DRM_IOCTL_MODE_GETPLANERESOURCES, &res))
            return -1;
        struct drm_mode_get_plane_res counts = res;
        uint32_t* ids = calloc(res.count_planes, sizeof *ids);
        res.plane_id_ptr = (uintptr_t)ids;
        if (ioctl(FAKE_FD, DRM_IOCTL_MODE_GETPLANERESOURCES, &res)) {
            free(ids);
            return -1;
        }
        if (counts.count_planes < res.count_planes) {
            free(ids);
            (*retries)++;
            continue;
        }
        memcpy(out, ids, res.count_planes * sizeof *ids);
        free(ids);
        return (int)res.count_planes;
    }
}

static int count_lines(const char* path, const char* needle)
{
    FILE* f = fopen(path, "r");
    if (!f)
        return -1;
    char line[256];
    int n = 0;
    while (fgets(line, sizeof line, f)) {
        if (strstr(line, needle))
            n++;
    }
    fclose(f);
    return n;
}

int main(int argc, char** argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: test-nocursor <stderr capture file>\n");
        return 2;
    }
    int cap = open(argv[1], O_WRONLY | O_CREAT | O_TRUNC, 0600);
    int saved = dup(2);
    if (cap < 0 || saved < 0 || dup2(cap, 2) < 0)
        return 2;

    int r = cursor(DRM_IOCTL_MODE_CURSOR, DRM_MODE_CURSOR_BO, 0);
    int hide = r == 0 && fake_cursor_calls == 0;
    r = cursor(DRM_IOCTL_MODE_CURSOR, DRM_MODE_CURSOR_BO, 7);
    int set = r == -1 && errno == EOPNOTSUPP && fake_cursor_calls == 0;
    r = cursor(DRM_IOCTL_MODE_CURSOR, DRM_MODE_CURSOR_MOVE, 0);
    int move = r == -1 && errno == EOPNOTSUPP && fake_cursor_calls == 0;
    r = cursor(DRM_IOCTL_MODE_CURSOR2, DRM_MODE_CURSOR_BO, 0);
    int hide2 = r == 0 && fake_cursor_calls == 0;
    r = cursor(DRM_IOCTL_MODE_CURSOR2, DRM_MODE_CURSOR_BO | DRM_MODE_CURSOR_MOVE, 9);
    int set2 = r == -1 && errno == EOPNOTSUPP && fake_cursor_calls == 0;
    errno = 0;
    r = ioctl(FAKE_FD, DRM_IOCTL_MODE_CURSOR, NULL);
    int null = r == -1 && errno == EFAULT && fake_cursor_calls == 0;

    uint32_t none = planes(0, NULL);
    uint32_t ids[6] = { 0 };
    uint32_t n = planes(6, ids);
    int filtered = n == 4 && ids[0] == 31 && ids[1] == 32 && ids[2] == 34 && ids[3] == 35;
    uint32_t small[6] = { 33, 33, 33, 33, 33, 33 };
    uint32_t ns = planes(2, small);
    uint32_t two[6] = { 0 };
    uint32_t retries = 0;
    int nd = libdrm_style(two, &retries);
    fake_broken_plane = 33;
    uint32_t kept[6] = { 0 };
    uint32_t nk = planes(6, kept);
    fake_broken_plane = 0;

    int p[2];
    int n_read = -1;
    int through = 0;
    if (pipe(p) == 0 && write(p[1], "abc", 3) == 3)
        through = ioctl(p[0], FIONREAD, &n_read) == 0 && n_read == 3;
    int before = fake_calls;
    errno = 0;
    r = ioctl(FAKE_FD, DRM_IOCTL_VERSION, &(struct drm_version) { 0 });
    int drm_through = r == -1 && errno == EINVAL && fake_calls == before + 1;

    fflush(stderr);
    dup2(saved, 2);
    close(cap);

    check(hide, "cursor hide returns 0 and never reaches the driver");
    check(set, "cursor set is refused with EOPNOTSUPP before the driver");
    check(move, "cursor move is refused with EOPNOTSUPP before the driver");
    check(hide2, "cursor2 hide returns 0 and never reaches the driver");
    check(set2, "cursor2 set is refused with EOPNOTSUPP before the driver");
    check(null, "cursor ioctl without an argument fails with EFAULT");
    check(fake_cursor_calls == 0, "no cursor ioctl reached the driver");
    check(count_lines(argv[1], "blockie-nocursor: refused a cursor ioctl") == 1, "a refusal is logged once");
    check(none == 6, "plane count query keeps the driver count");
    check(filtered, "plane list drops the cursor planes and keeps the order");
    check(count_lines(argv[1], "blockie-nocursor: hid 2 cursor planes of 6") >= 1, "hidden planes are logged");
    check(ns == 6 && small[0] == 33 && small[5] == 33, "a short plane buffer is left to the driver");
    check(nd == 4 && retries == 0 && two[2] == 34, "libdrm two pass read gets 4 planes without a retry");
    check(nk == 5 && kept[2] == 33, "a plane whose type cannot be read is kept");
    check(through, "other ioctls reach the kernel");
    check(drm_through, "other DRM ioctls reach the driver");
    return fails ? 1 : 0;
}
