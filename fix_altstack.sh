#!/usr/bin/env bash
set -euo pipefail

cd /home/natska/daemon-reporter-4-kernel-panics

cat << 'INNER_EOF' > src/interceptor/libdaemond_hook.c
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

#define DAEMOND_ALTSTACK_BYTES 65536U

static struct daemond_shm_ring *g_ring = NULL;
static stack_t g_altstack;
static uint8_t g_altstack_mem[DAEMOND_ALTSTACK_BYTES] __attribute__((aligned(64)));

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ((uint64_t)ts.tv_sec * 1000000000ULL) + (uint64_t)ts.tv_nsec;
}

static void resolve_prog_name(char *buf, size_t len) {
    ssize_t n = readlink("/proc/self/exe", buf, len - 1);
    if (n > 0) {
        buf[n] = '\0';
        char *slash = strrchr(buf, '/');
        if (slash) {
            memmove(buf, slash + 1, strlen(slash + 1) + 1);
        }
        return;
    }
    snprintf(buf, len, "pid_%d", getpid());
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
        resolve_prog_name(ev.app_name, sizeof(ev.app_name));
        snprintf(ev.detail, sizeof(ev.detail),
                 "[%s] HARD FAULT sig=%d si_code=%d pointer outside RAM at 0x%lx",
                 ev.app_name, sig, info ? info->si_code : 0,
                 (unsigned long)ev.fault_addr);
        ring_push(g_ring, &ev);
    }
    _exit(128 + sig);
}

void __sanitizer_report_error_summary(const char *error_summary) {
    if (!g_ring || !error_summary) return;
    fault_event_t ev;
    memset(&ev, 0, sizeof(ev));
    ev.timestamp_ns = now_ns();
    ev.pid = getpid();
    ev.tid = (int32_t)syscall(SYS_gettid);
    resolve_prog_name(ev.app_name, sizeof(ev.app_name));

    if (strstr(error_summary, "LeakSanitizer")) {
        ev.type = FAULT_RAM_LEAK;
    } else if (strstr(error_summary, "ThreadSanitizer")) {
        ev.type = FAULT_RACE_COND;
    } else {
        ev.type = FAULT_OOB_HARD;
    }

    snprintf(ev.detail, sizeof(ev.detail), "[%s] %s", ev.app_name, error_summary);
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
INNER_EOF

make
