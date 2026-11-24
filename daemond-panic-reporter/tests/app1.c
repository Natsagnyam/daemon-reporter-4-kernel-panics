/* app1.c: Deliberate RAM leak for LSan / Valgrind */
#include <stdlib.h>
#include <string.h>

int main(void) {
    char *leaked_buf = (char *)malloc(4096);
    if (leaked_buf) {
        memset(leaked_buf, 0xAA, 4096);
    }
    /* Missing free(leaked_buf) -> LSan reports RAM leak to daemond */
    return 0;
}
