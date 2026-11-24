#include "daemond_shm.h"
#include <stdio.h>

int main(void) {
    printf("[daemond-egui] Frontend bridge ready for /dev/shm%s\n", SHM_NAME);
    return 0;
}
