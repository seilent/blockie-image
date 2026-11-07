#include <stdio.h>
#include <stdlib.h>

extern int fake_flush;
extern int fake_finish;
void glFlush(void);

int main(void)
{
    glFlush();
    glFlush();
#ifdef NO_FINISH
    int ok = fake_finish == 0 && fake_flush == 2;
    printf("%s glFlush reaches the real glFlush when there is no glFinish\n", ok ? "ok  " : "FAIL");
#else
    int nested = getenv("FAKE_FINISH_FLUSHES") != NULL;
    int ok = fake_finish == 2 && fake_flush == (nested ? 2 : 0);
    printf("%s glFlush waits with glFinish%s\n", ok ? "ok  " : "FAIL",
        nested ? ", and a glFlush inside glFinish reaches the driver once" : "");
#endif
    return ok ? 0 : 1;
}
