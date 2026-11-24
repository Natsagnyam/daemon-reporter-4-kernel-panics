#ifndef DAEMOND_SHM_H
#define DAEMOND_SHM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RING_SHIFT  10
#define RING_SIZE   (1U << RING_SHIFT)
#define RING_MASK   (RING_SIZE - 1U)

#define SHM_NAME    "/daemond_fault_ring_v1"
#define MAX_PAYLOAD 512

typedef enum {
    FAULT_NONE         = 0,
    FAULT_RAM_LEAK     = 1, /* LSan / Valgrind Memcheck */
    FAULT_RACE_COND    = 2, /* TSan (-fsanitize=thread) */
    FAULT_OOB_HARD     = 3, /* Out-of-RAM pointer / SIGSEGV / SIGBUS / ASan */
    FAULT_CPU_HOG      = 4, /* CPU time / spin leak threshold exceeded */
    FAULT_KERNEL_PANIC = 5  /* Kernel panic / Oops / SysRq crash event */
} fault_type_t;

typedef struct {
    uint64_t     timestamp_ns;
    int32_t      pid;
    int32_t      tid;
    fault_type_t type;
    uintptr_t    fault_addr;
    char         app_name[64];
    char         detail[MAX_PAYLOAD];
} fault_event_t;

/*
 * Rule: No Atomic Battle.
 * Separate structures are ensured to be on different Cache Lines via padding.
 */
struct producer_ctrl {
    uint8_t pad_top[124];
    volatile uint32_t tail;
    uint8_t pad_bot[124];
} __attribute__((aligned(64)));

struct consumer_ctrl {
    uint8_t pad_top[124];
    volatile uint32_t head;
    uint8_t pad_bot[124];
} __attribute__((aligned(64)));

struct daemond_shm_ring {
    struct producer_ctrl prod;
    struct consumer_ctrl cons;
    fault_event_t slots[RING_SIZE];
};

static inline uint32_t ring_push(struct daemond_shm_ring *r, const fault_event_t *ev) {
    uint32_t next_tail = (r->prod.tail + 1U) & RING_MASK;
    if (next_tail == r->cons.head) {
        return 0;
    }
    r->slots[r->prod.tail] = *ev;
    __asm__ __volatile__("" ::: "memory");
    r->prod.tail = next_tail;
    return 1;
}

static inline uint32_t ring_pop(struct daemond_shm_ring *r, fault_event_t *out) {
    if (r->cons.head == r->prod.tail) {
        return 0;
    }
    *out = r->slots[r->cons.head];
    __asm__ __volatile__("" ::: "memory");
    r->cons.head = (r->cons.head + 1U) & RING_MASK;
    return 1;
}

#ifdef __cplusplus
}
#endif
#endif /* DAEMOND_SHM_H */
