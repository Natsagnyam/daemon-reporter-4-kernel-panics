#!/usr/bin/env bash
set -euo pipefail

cd /home/natska/daemon-reporter-4-kernel-panics
mkdir -p debian include src/daemon src/interceptor src/egui wrappers tests

# ------------------------------------------------------------------------------
# 1. Lock-Free Cache-Padded Ring Buffer & Shared Memory Protocol
# ------------------------------------------------------------------------------
cat << 'INNER_EOF' > include/daemond_shm.h
#ifndef DAEMOND_SHM_H
#define DAEMOND_SHM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Power-of-2 ring size for bitwise & masking (zero modulo %) */
#define RING_SHIFT  10
#define RING_SIZE   (1U << RING_SHIFT)
#define RING_MASK   (RING_SIZE - 1U)

#define SHM_NAME    "/daemond_fault_ring_v1"
#define MAX_PAYLOAD 512

typedef enum {
    FAULT_NONE      = 0,
    FAULT_RAM_LEAK  = 1, /* LSan / Valgrind Memcheck */
    FAULT_RACE_COND = 2, /* TSan (-fsanitize=thread) */
    FAULT_OOB_HARD  = 3, /* Out-of-RAM pointer / SIGSEGV / SIGBUS / ASan */
    FAULT_CPU_HOG   = 4  /* CPU time / spin leak threshold exceeded */
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

/* Static shared memory ring layout (zero heap malloc) */
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
INNER_EOF

# ------------------------------------------------------------------------------
# 2. Runtime Interceptor (SIGSEGV/SIGBUS Hard Faults + ASan/LSan/TSan Hooks)
# ------------------------------------------------------------------------------
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

static struct daemond_shm_ring *g_ring = NULL;
static stack_t g_altstack;
static uint8_t g_altstack_mem[SIGSTKSZ] __attribute__((aligned(64)));

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

# ------------------------------------------------------------------------------
# 3. Kernel-Panic-Daemond-Reporter Daemon (C++20)
# ------------------------------------------------------------------------------
cat << 'INNER_EOF' > src/daemon/daemond.cpp
#include "daemond_shm.h"
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t g_running = 1;

static void on_sig(int) {
    g_running = 0;
}

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
    std::signal(SIGINT, on_sig);
    std::signal(SIGTERM, on_sig);

    struct daemond_shm_ring *ring = init_shm();
    if (!ring) {
        std::perror("daemond: shm_open failed");
        return 1;
    }

    std::printf("[daemond] Listening on SHM %s (slots=%u)\n", SHM_NAME, RING_SIZE);
    std::fflush(stdout);

    fault_event_t ev;
    struct timespec sleep_ts = {0, 2000000L}; /* 2ms poll */

    while (g_running) {
        while (ring_pop(ring, &ev)) {
            const char *tag = "UNKNOWN";
            if (ev.type == FAULT_RAM_LEAK)  tag = "RAM_LEAK";
            if (ev.type == FAULT_RACE_COND) tag = "RACE_COND";
            if (ev.type == FAULT_OOB_HARD)  tag = "HARD_FAULT_OOB";
            if (ev.type == FAULT_CPU_HOG)   tag = "CPU_LEAK";

            std::printf("{\"ts\":%lu,\"pid\":%d,\"tid\":%d,\"app\":\"%s\",\"type\":\"%s\",\"addr\":\"0x%lx\",\"msg\":\"%s\"}\n",
                        ev.timestamp_ns, ev.pid, ev.tid, ev.app_name, tag,
                        (unsigned long)ev.fault_addr, ev.detail);
            std::fflush(stdout);
        }
        nanosleep(&sleep_ts, nullptr);
    }

    shm_unlink(SHM_NAME);
    return 0;
}
INNER_EOF

# ------------------------------------------------------------------------------
# 4. eGUI Frontend Receiver Stub
# ------------------------------------------------------------------------------
cat << 'INNER_EOF' > src/egui/egui_bridge.c
#include "daemond_shm.h"
#include <stdio.h>

int main(void) {
    printf("[daemond-egui] Frontend bridge ready for /dev/shm%s\n", SHM_NAME);
    return 0;
}
INNER_EOF

# ------------------------------------------------------------------------------
# 5. Sanitizers & Valgrind Wrapper Scripts
# ------------------------------------------------------------------------------
cat << 'INNER_EOF' > wrappers/daemond-cc-mem
#!/usr/bin/env bash
set -euo pipefail
exec gcc -O1 -g -fno-omit-frame-pointer \
     -fsanitize=address,leak,undefined \
     -I/home/natska/daemon-reporter-4-kernel-panics/include \
     -L/home/natska/daemon-reporter-4-kernel-panics/build \
     -Wl,-rpath,/home/natska/daemon-reporter-4-kernel-panics/build \
     -Wl,--no-as-needed -ldaemond_hook "$@"
INNER_EOF

cat << 'INNER_EOF' > wrappers/daemond-cc-race
#!/usr/bin/env bash
set -euo pipefail
exec gcc -O1 -g -fno-omit-frame-pointer \
     -fsanitize=thread -fPIE -pie \
     -I/home/natska/daemon-reporter-4-kernel-panics/include \
     -L/home/natska/daemon-reporter-4-kernel-panics/build \
     -Wl,-rpath,/home/natska/daemon-reporter-4-kernel-panics/build \
     -Wl,--no-as-needed -ldaemond_hook "$@"
INNER_EOF

cat << 'INNER_EOF' > wrappers/daemond-valgrind
#!/usr/bin/env bash
set -euo pipefail
exec valgrind --tool=memcheck --leak-check=full --show-leak-kinds=all "$@"
INNER_EOF

chmod +x wrappers/*

# ------------------------------------------------------------------------------
# 6. Target Test Cases: app1.c (RAM leak), app2.c (Race), app3.c (Hard Fault)
# ------------------------------------------------------------------------------
cat << 'INNER_EOF' > tests/app1.c
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
INNER_EOF

cat << 'INNER_EOF' > tests/app2.c
#include <pthread.h>
#include <stdio.h>

static int counter = 0;

static void *thread_fn(void *arg) {
    (void)arg;
    for (int i = 0; i < 100000; ++i) {
        counter++;
    }
    return NULL;
}

int main(void) {
    pthread_t t1, t2;
    pthread_create(&t1, NULL, thread_fn, NULL);
    pthread_create(&t2, NULL, thread_fn, NULL);
    pthread_join(t1, NULL);
    pthread_join(t2, NULL);
    printf("counter=%d\n", counter);
    return 0;
}
INNER_EOF

cat << 'INNER_EOF' > tests/app3.c
#include <stdint.h>

int main(void) {
    volatile uint64_t *oob_ptr = (volatile uint64_t *)0x00000000DEAD0000ULL;
    *oob_ptr = 0xCAFEBABEULL;
    return 0;
}
INNER_EOF

# ------------------------------------------------------------------------------
# 7. Makefile & Debian Launchpad PPA Files
# ------------------------------------------------------------------------------
cat << 'INNER_EOF' > Makefile
CC       ?= gcc
CXX      ?= g++
CFLAGS   := -O2 -Wall -Wextra -Iinclude -fPIC
CXXFLAGS := -std=c++20 -O2 -Wall -Wextra -Iinclude

all: build/daemond build/libdaemond_hook.so build/daemond-egui build/app1 build/app2 build/app3

build/daemond: src/daemon/daemond.cpp include/daemond_shm.h
	@mkdir -p build
	$(CXX) $(CXXFLAGS) src/daemon/daemond.cpp -o build/daemond -lrt -lpthread

build/libdaemond_hook.so: src/interceptor/libdaemond_hook.c include/daemond_shm.h
	@mkdir -p build
	$(CC) $(CFLAGS) -shared src/interceptor/libdaemond_hook.c -o build/libdaemond_hook.so -ldl -lrt

build/daemond-egui: src/egui/egui_bridge.c include/daemond_shm.h
	@mkdir -p build
	$(CC) $(CFLAGS) src/egui/egui_bridge.c -o build/daemond-egui

build/app1: tests/app1.c build/libdaemond_hook.so
	@mkdir -p build
	./wrappers/daemond-cc-mem tests/app1.c -o build/app1

build/app2: tests/app2.c build/libdaemond_hook.so
	@mkdir -p build
	./wrappers/daemond-cc-race tests/app2.c -lpthread -o build/app2

build/app3: tests/app3.c build/libdaemond_hook.so
	@mkdir -p build
	$(CC) -O1 -g -fno-omit-frame-pointer -Iinclude -Lbuild -Wl,-rpath,$(CURDIR)/build -Wl,--no-as-needed -ldaemond_hook tests/app3.c -o build/app3

clean:
	rm -rf build

.PHONY: all clean
INNER_EOF

cat << 'INNER_EOF' > debian/control
Source: daemon-reporter-4-kernel-panics
Section: devel
Priority: optional
Maintainer: Natsagnyam Namkhai <natska@example.com>
Build-Depends: debhelper-compat (= 13), g++ (>= 11), gcc (>= 11), valgrind
Standards-Version: 4.6.2

Package: daemon-reporter-4-kernel-panics
Architecture: any
Depends: ${shlibs:Depends}, ${misc:Depends}, gcc, valgrind
Description: Runtime C RAM leak, race condition, and hard-fault reporter daemon
 Captures LSan, TSan, ASan, Valgrind, and SIGSEGV/SIGBUS pointer hard faults
 into a cache-padded shared-memory ring buffer for eGUI reporting.
INNER_EOF

cat << 'INNER_EOF' > debian/rules
#!/usr/bin/make -f
%:
	dh $@

override_dh_auto_install:
	install -Dm755 build/daemond debian/daemon-reporter-4-kernel-panics/usr/bin/daemond
	install -Dm755 build/daemond-egui debian/daemon-reporter-4-kernel-panics/usr/bin/daemond-egui
	install -Dm644 build/libdaemond_hook.so debian/daemon-reporter-4-kernel-panics/usr/lib/libdaemond_hook.so
	install -Dm755 wrappers/daemond-cc-mem debian/daemon-reporter-4-kernel-panics/usr/bin/daemond-cc-mem
	install -Dm755 wrappers/daemond-cc-race debian/daemon-reporter-4-kernel-panics/usr/bin/daemond-cc-race
	install -Dm755 wrappers/daemond-valgrind debian/daemon-reporter-4-kernel-panics/usr/bin/daemond-valgrind
INNER_EOF
chmod +x debian/rules

echo "Initialized project inside /home/natska/daemon-reporter-4-kernel-panics"
