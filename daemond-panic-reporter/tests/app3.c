/* app3.c: Deliberate Out-of-RAM C Pointer Hard Fault (SIGSEGV / ASan) */
#include <stdint.h>

int main(void) {
    volatile uint32_t *invalid_ram_ptr = (volatile uint32_t *)0x00000000DEADBEEFULL;
    *invalid_ram_ptr = 0x1337; /* Hard fault outside mapped RAM */
    return 0;
}
