#include <stdlib.h>

int fake_flush;
int fake_finish;

void glFlush(void)
{
    fake_flush++;
}

#ifndef NO_FINISH
void glFinish(void)
{
    fake_finish++;
    if (getenv("FAKE_FINISH_FLUSHES"))
        glFlush();
}
#endif
