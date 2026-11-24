#define _GNU_SOURCE
#include "daemond_shm.h"
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

static struct daemond_shm_ring *g_ring = NULL;
static stack_t g_altstack;
static uint8_t g_altstack_mem[SIGSTKSZ] __attribute__((aligned(64)));

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ((uint64_t)ts.tv_sec * 1000000000ULL) + (uint64_t)ts.tv_nsec;
}

static void hard_fault_handler(int sig, siginfo_t *info, void *ucontext) {
    (void)ucontext;
    if (g_ring) {
        fault_event_t ev;
        memset(&ev, 0, sizeof(ev));
        ev.timestamp_ns = now_ns();
        ev.pid = getpid();
        ev.tid = (int32_t)syscall(SYS_gettid);
        ev.type = FAULT_OOB_HARD;
        ev.fault_addr = (uintptr_t)(info ? info->si_addr : 0);
        snprintf(ev.app_name, sizeof(ev.app_name), "pid_%d", ev.pid);
        snprintf(ev.detail, sizeof(ev.detail),
                 "HARD FAULT (sig=%d) pointer outside mapped RAM at 0x%lx",
                 sig, (unsigned long)ev.fault_addr);
        ring_push(g_ring, &ev);
    }
    _exit(128 + sig);
}

/* Sanitizer death callback invoked by ASan / LSan / TSan before aborting */
void __sanitizer_report_error_summary(const char *error_summary) {
    if (!g_ring || !error_summary) return;
    fault_event_t ev;
    memset(&ev, 0, sizeof(ev));
    ev.timestamp_ns = now_ns();
    ev.pid = getpid();
    ev.tid = (int32_t)syscall(SYS_gettid);

    if (strstr(error_summary, "LeakSanitizer")) {
        ev.type = FAULT_RAM_LEAK;
    } else if (strstr(error_summary, "ThreadSanitizer")) {
        ev.type = FAULT_RACE_COND;
    } else {
        ev.type = FAULT_OOB_HARD;
    }

    snprintf(ev.app_name, sizeof(ev.app_name), "pid_%d", ev.pid);
    snprintf(ev.detail, sizeof(ev.detail), "%s", error_summary);
    ring_push(g_ring, &ev);
}

__attribute__((constructor))
static void daemond_hook_init(void) {
    int fd = shm_open(SHM_NAME, O_RDWR, 0666);
    if (fd >= 0) {
        g_ring = mmap(NULL, sizeof(struct daemond_shm_ring),
                      PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        close(fd);
        if (g_ring == MAP_FAILED) g_ring = NULL;
    }

    /* Alternate signal stack so stack overflows still report hard faults */
    g_altstack.ss_sp = g_altstack_mem;
    g_altstack.ss_size = sizeof(g_altstack_mem);
    g_altstack.ss_flags = 0;
    sigaltstack(&g_altstack, NULL);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = hard_fault_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS,  &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
}
