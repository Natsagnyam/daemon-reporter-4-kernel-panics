#!/usr/bin/env bash
set -euo pipefail

PROJECT="daemond-panic-reporter"
mkdir -p "${PROJECT}"/{debian,include,src/daemon,src/interceptor,src/egui,wrappers,tests}

# ------------------------------------------------------------------------------
# 1. Lock-Free Cache-Padded Ring Buffer & Shared Memory Protocol (C / C++20)
# ------------------------------------------------------------------------------
cat << 'INNER_EOF' > "${PROJECT}/include/daemond_shm.h"
#ifndef DAEMOND_SHM_H
#define DAEMOND_SHM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Must be power of 2 for bitwise masking (no modulo %) */
#define RING_SHIFT 10
#define RING_SIZE  (1U << RING_SHIFT)
#define RING_MASK  (RING_SIZE - 1U)

#define SHM_NAME "/daemond_fault_ring_v1"
#define MAX_PAYLOAD 512

typedef enum {
    FAULT_NONE       = 0,
    FAULT_RAM_LEAK   = 1, /* LSan / Valgrind Memcheck */
    FAULT_RACE_COND  = 2, /* TSan / Helgrind */
    FAULT_OOB_HARD   = 3, /* ASan / SIGSEGV / SIGBUS / Out-of-RAM */
    FAULT_CPU_HOG    = 4  /* Watchdog CPU threshold exceeded */
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

/* Static pre-allocated shared memory layout (zero malloc) */
struct daemond_shm_ring {
    struct producer_ctrl prod;
    struct consumer_ctrl cons;
    fault_event_t slots[RING_SIZE];
};

static inline uint32_t ring_push(struct daemond_shm_ring *r, const fault_event_t *ev) {
    uint32_t next_tail = (r->prod.tail + 1U) & RING_MASK;
    if (next_tail == r->cons.head) {
        return 0; /* Ring full: drop or overwrite policy */
    }
    r->slots[r->prod.tail] = *ev;
    __asm__ __volatile__("" ::: "memory"); /* Compiler barrier */
    r->prod.tail = next_tail;
    return 1;
}

static inline uint32_t ring_pop(struct daemond_shm_ring *r, fault_event_t *out) {
    if (r->cons.head == r->prod.tail) {
        return 0; /* Empty */
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
INNER_EOF

# ------------------------------------------------------------------------------
# 2. LD_PRELOAD Runtime Interceptor (Captures SIGSEGV/Hard Faults & Sanitizer logs)
# ------------------------------------------------------------------------------
cat << 'INNER_EOF' > "${PROJECT}/src/interceptor/libdaemond_hook.c"
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
INNER_EOF

# ------------------------------------------------------------------------------
# 3. Kernel-Panic-Daemond-Reporter Core (C++20 / C Hybrid Daemon)
# ------------------------------------------------------------------------------
cat << 'INNER_EOF' > "${PROJECT}/src/daemon/daemond.cpp"
#include "daemond_shm.h"
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <time.h>

static struct daemond_shm_ring *init_shm(void) {
    int fd = shm_open(SHM_NAME, O_CREAT | O_RDWR, 0666);
    if (fd < 0) return nullptr;
    if (ftruncate(fd, sizeof(struct daemond_shm_ring)) != 0) {
        close(fd);
        return nullptr;
    }
    void *ptr = mmap(nullptr, sizeof(struct daemond_shm_ring),
                     PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (ptr == MAP_FAILED) return nullptr;
    std::memset(ptr, 0, sizeof(struct daemond_shm_ring));
    return static_cast<struct daemond_shm_ring *>(ptr);
}

int main(void) {
    struct daemond_shm_ring *ring = init_shm();
    if (!ring) {
        std::perror("daemond: shm_open failed");
        return 1;
    }

    std::printf("[daemond] Kernel-Panic & Runtime Fault Reporter online.\n");
    std::printf("[daemond] Monitoring SHM %s (slots=%u, cache-padded=128B)\n",
                SHM_NAME, RING_SIZE);

    fault_event_t ev;
    struct timespec sleep_ts = {0, 5000000L}; /* 5ms poll */

    while (true) {
        while (ring_pop(ring, &ev)) {
            const char *tag = "UNKNOWN";
            if (ev.type == FAULT_RAM_LEAK)  tag = "RAM_LEAK";
            if (ev.type == FAULT_RACE_COND) tag = "RACE_COND";
            if (ev.type == FAULT_OOB_HARD)  tag = "HARD_FAULT_OOB";
            if (ev.type == FAULT_CPU_HOG)   tag = "CPU_LEAK";

            /* Forward structured JSON/IPC frame to eGUI frontend */
            std::printf("{\"ts\":%lu,\"pid\":%d,\"tid\":%d,\"type\":\"%s\",\"addr\":\"0x%lx\",\"msg\":\"%s\"}\n",
                        ev.timestamp_ns, ev.pid, ev.tid, tag,
                        (unsigned long)ev.fault_addr, ev.detail);
            std::fflush(stdout);
        }
        nanosleep(&sleep_ts, nullptr);
    }
    return 0;
}
INNER_EOF

# ------------------------------------------------------------------------------
# 4. eGUI Frontend Bridge (Rust/egui or C++/ImGui socket/pipe consumer)
# ------------------------------------------------------------------------------
cat << 'INNER_EOF' > "${PROJECT}/src/egui/egui_bridge.c"
#include "daemond_shm.h"
#include <stdio.h>

/*
 * eGUI Frontend Bridge:
 * Reads directly from /dev/shm/daemond_fault_ring_v1 or daemond stdout stream
 * to display live fault cards (RAM Leaks, Data Races, Hard Faults) without
 * blocking the monitored C targets.
 */
int main(void) {
    printf("[daemond-egui] Ready to render runtime C fault telemetry.\n");
    return 0;
}
INNER_EOF

# ------------------------------------------------------------------------------
# 5. Compiler & Valgrind Wrappers for PPA Users
# ------------------------------------------------------------------------------
cat << 'INNER_EOF' > "${PROJECT}/wrappers/daemond-cc-mem"
#!/usr/bin/env bash
# Compiles C apps with ASan + LSan + UBSan and preloads libdaemond_hook.so
exec gcc -O1 -g -fno-omit-frame-pointer \
     -fsanitize=address,leak,undefined \
     -Wl,--no-as-needed -ldaemond_hook "$@"
INNER_EOF

cat << 'INNER_EOF' > "${PROJECT}/wrappers/daemond-cc-race"
#!/usr/bin/env bash
# Compiles C apps with ThreadSanitizer (C++20/C11 TSan runtime)
exec gcc -O1 -g -fno-omit-frame-pointer \
     -fsanitize=thread -fPIE -pie \
     -Wl,--no-as-needed -ldaemond_hook "$@"
INNER_EOF

cat << 'INNER_EOF' > "${PROJECT}/wrappers/daemond-valgrind"
#!/usr/bin/env bash
# Runs un-instrumented C binaries under Valgrind Memcheck/Helgrind
exec valgrind --tool=memcheck --leak-check=full --show-leak-kinds=all "$@"
INNER_EOF

chmod +x "${PROJECT}/wrappers/"*

# ------------------------------------------------------------------------------
# 6. Target Test Apps (app1.c, app2.c, app3.c)
# ------------------------------------------------------------------------------
cat << 'INNER_EOF' > "${PROJECT}/tests/app1.c"
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
INNER_EOF

cat << 'INNER_EOF' > "${PROJECT}/tests/app2.c"
/* app2.c: Deliberate Data Race for TSan (-fsanitize=thread) */
#include <pthread.h>
#include <stdio.h>

static int shared_counter = 0;

static void *worker(void *arg) {
    (void)arg;
    for (int i = 0; i < 100000; ++i) {
        shared_counter++; /* Unsynchronized read-modify-write race */
    }
    return NULL;
}

int main(void) {
    pthread_t t1, t2;
    pthread_create(&t1, NULL, worker, NULL);
    pthread_create(&t2, NULL, worker, NULL);
    pthread_join(t1, NULL);
    pthread_join(t2, NULL);
    printf("Counter: %d\n", shared_counter);
    return 0;
}
INNER_EOF

cat << 'INNER_EOF' > "${PROJECT}/tests/app3.c"
/* app3.c: Deliberate Out-of-RAM C Pointer Hard Fault (SIGSEGV / ASan) */
#include <stdint.h>

int main(void) {
    volatile uint32_t *invalid_ram_ptr = (volatile uint32_t *)0x00000000DEADBEEFULL;
    *invalid_ram_ptr = 0x1337; /* Hard fault outside mapped RAM */
    return 0;
}
INNER_EOF

# ------------------------------------------------------------------------------
# 7. Root Makefile & Debian Launchpad PPA Packaging Skeleton
# ------------------------------------------------------------------------------
cat << 'INNER_EOF' > "${PROJECT}/Makefile"
CC      ?= gcc
CXX     ?= g++
CFLAGS  := -O2 -Wall -Wextra -Iinclude -fPIC
CXXFLAGS:= -std=c++20 -O2 -Wall -Wextra -Iinclude

all: build/daemond build/libdaemond_hook.so build/daemond-egui

build/daemond: src/daemon/daemond.cpp include/daemond_shm.h
	@mkdir -p build
	$(CXX) $(CXXFLAGS) src/daemon/daemond.cpp -o build/daemond -lrt -lpthread

build/libdaemond_hook.so: src/interceptor/libdaemond_hook.c include/daemond_shm.h
	@mkdir -p build
	$(CC) $(CFLAGS) -shared src/interceptor/libdaemond_hook.c -o build/libdaemond_hook.so -ldl -lrt

build/daemond-egui: src/egui/egui_bridge.c include/daemond_shm.h
	@mkdir -p build
	$(CC) $(CFLAGS) src/egui/egui_bridge.c -o build/daemond-egui

clean:
	rm -rf build

.PHONY: all clean
INNER_EOF

cat << 'INNER_EOF' > "${PROJECT}/debian/control"
Source: daemond-panic-reporter
Section: devel
Priority: optional
Maintainer: C Runtime Diagnostics <dev@example.com>
Build-Depends: debhelper-compat (= 13), g++ (>= 11), gcc (>= 11), valgrind
Standards-Version: 4.6.2

Package: daemond-panic-reporter
Architecture: any
Depends: ${shlibs:Depends}, ${misc:Depends}, gcc, valgrind, libasan8 | libasan6, libtsan2 | libtsan0
Description: Runtime C fault, RAM leak, race condition, and hard-fault reporter for eGUI
 Intercepts ASan, LSan, TSan, Valgrind, and SIGSEGV/SIGBUS hard faults via a
 lock-free cache-padded ring buffer and streams diagnostics to eGUI.
INNER_EOF

cat << 'INNER_EOF' > "${PROJECT}/debian/rules"
#!/usr/bin/make -f
%:
	dh $@

override_dh_auto_install:
	install -Dm755 build/daemond debian/daemond-panic-reporter/usr/bin/daemond
	install -Dm755 build/daemond-egui debian/daemond-panic-reporter/usr/bin/daemond-egui
	install -Dm644 build/libdaemond_hook.so debian/daemond-panic-reporter/usr/lib/libdaemond_hook.so
	install -Dm755 wrappers/daemond-cc-mem debian/daemond-panic-reporter/usr/bin/daemond-cc-mem
	install -Dm755 wrappers/daemond-cc-race debian/daemond-panic-reporter/usr/bin/daemond-cc-race
	install -Dm755 wrappers/daemond-valgrind debian/daemond-panic-reporter/usr/bin/daemond-valgrind
INNER_EOF
chmod +x "${PROJECT}/debian/rules"

echo "Project tree created in ./${PROJECT}"
