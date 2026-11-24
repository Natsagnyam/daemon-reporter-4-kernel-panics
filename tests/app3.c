#include <stdint.h>

int main(void) {
    volatile uint64_t *oob_ptr = (volatile uint64_t *)0x00000000DEAD0000ULL;
    *oob_ptr = 0xCAFEBABEULL;
    return 0;
}
