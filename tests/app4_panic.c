/*
 * app4_panic.c:
 * Default mode: pushes a simulated KERNEL_PANIC fault frame into SHM so
 * daemond + Rust eGUI can be tested safely without freezing the host OS.
 * --really-panic mode (requires root): writes 'c' to /proc/sysrq-trigger to
 * force a real kernel panic (only run inside a VM or isolated test host).
 */
#include "daemond_shm.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ((uint64_t)ts.tv_sec * 1000000000ULL) + (uint64_t)ts.tv_nsec;
}

static int trigger_real_kernel_panic(void) {
    int sysrq_fd = open("/proc/sys/kernel/sysrq", O_WRONLY);
    if (sysrq_fd >= 0) {
        if (write(sysrq_fd, "1\n", 2) < 0) {
            perror("write /proc/sys/kernel/sysrq");
        }
        close(sysrq_fd);
    }

    int trig_fd = open("/proc/sysrq-trigger", O_WRONLY);
    if (trig_fd < 0) {
        perror("open /proc/sysrq-trigger (run as root)");
        return 1;
    }
    printf("[app4_panic] Writing 'c' to /proc/sysrq-trigger -> KERNEL PANIC!\n");
    fflush(stdout);
    if (write(trig_fd, "c\n", 2) < 0) {
        perror("write /proc/sysrq-trigger");
        close(trig_fd);
        return 1;
    }
    close(trig_fd);
    return 0;
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--really-panic") == 0) {
        return trigger_real_kernel_panic();
    }

    int fd = shm_open(SHM_NAME, O_RDWR, 0666);
    if (fd < 0) {
        perror("shm_open (is daemond running?)");
        return 1;
    }

    struct daemond_shm_ring *ring = mmap(
        NULL, sizeof(struct daemond_shm_ring),
        PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (ring == MAP_FAILED) {
        perror("mmap");
        return 1;
    }

    fault_event_t ev;
    memset(&ev, 0, sizeof(ev));
    ev.timestamp_ns = now_ns();
    ev.pid = getpid();
    ev.tid = getpid();
    ev.type = FAULT_KERNEL_PANIC;
    ev.fault_addr = 0xffffffff81000000ULL;
    snprintf(ev.app_name, sizeof(ev.app_name), "app4_panic");
    snprintf(ev.detail, sizeof(ev.detail),
             "Kernel panic - not syncing: Harmful C fault (pass --really-panic as root for SysRq 'c')");

    if (!ring_push(ring, &ev)) {
        fprintf(stderr, "SHM ring full\n");
        return 1;
    }

    printf("[app4_panic] Dispatched KERNEL_PANIC event to daemond.\n");
    return 0;
}
