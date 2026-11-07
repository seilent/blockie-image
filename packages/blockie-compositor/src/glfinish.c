#define _GNU_SOURCE
#include <dlfcn.h>

typedef void (*gl_fn)(void);

static gl_fn next_finish;
static gl_fn next_flush;
static __thread int busy;

static gl_fn next(gl_fn* slot, const char* name)
{
    gl_fn f = __atomic_load_n(slot, __ATOMIC_ACQUIRE);
    if (!f) {
        f = (gl_fn)dlsym(RTLD_NEXT, name);
        __atomic_store_n(slot, f, __ATOMIC_RELEASE);
    }
    return f;
}

void glFlush(void)
{
    if (busy) {
        gl_fn f = next(&next_flush, "glFlush");
        if (f)
            f();
        return;
    }
    gl_fn f = next(&next_finish, "glFinish");
    if (!f)
        f = next(&next_flush, "glFlush");
    if (!f)
        return;
    busy = 1;
    f();
    busy = 0;
}
