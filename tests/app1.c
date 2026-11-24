#include <stdlib.h>
#include <string.h>

int main(void) {
    char *buf = (char *)malloc(8192);
    if (buf) {
        memset(buf, 0x5A, 8192);
    }
    /* Deliberate RAM leak: never freed */
    return 0;
}
