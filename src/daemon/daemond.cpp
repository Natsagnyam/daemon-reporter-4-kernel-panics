#include "daemond_shm.h"
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <string>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t g_running = 1;

static void on_sig(int) {
    g_running = 0;
}

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (static_cast<uint64_t>(ts.tv_sec) * 1000000000ULL) +
           static_cast<uint64_t>(ts.tv_nsec);
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

static void scan_kern_log_panics(struct daemond_shm_ring *ring) {
    std::ifstream kern("/var/log/kern.log");
    if (!kern.is_open()) return;

    std::string line;
    int matched = 0;
    while (std::getline(kern, line) && matched < 16) {
        if (line.find("Kernel panic") != std::string::npos ||
            line.find("BUG:") != std::string::npos) {
            fault_event_t ev;
            std::memset(&ev, 0, sizeof(ev));
            ev.timestamp_ns = now_ns();
            ev.pid = 0;
            ev.tid = 0;
            ev.type = FAULT_KERNEL_PANIC;
            ev.fault_addr = 0;
            std::snprintf(ev.app_name, sizeof(ev.app_name), "kernel");
            std::snprintf(ev.detail, sizeof(ev.detail), "%s", line.c_str());
            ring_push(ring, &ev);
            ++matched;
        }
    }
}

static void print_json_escaped(const char *s) {
    for (; *s; ++s) {
        if (*s == '"' || *s == '\\') {
            std::putchar('\\');
        }
        if (*s == '\n' || *s == '\r') {
            std::putchar(' ');
            continue;
        }
        std::putchar(*s);
    }
}

int main(void) {
    std::signal(SIGINT, on_sig);
    std::signal(SIGTERM, on_sig);

    struct daemond_shm_ring *ring = init_shm();
    if (!ring) {
        std::perror("daemond: shm_open failed");
        return 1;
    }

    scan_kern_log_panics(ring);

    std::printf("[daemond] Listening on SHM %s (slots=%u)\n", SHM_NAME, RING_SIZE);
    std::fflush(stdout);

    fault_event_t ev;
    struct timespec sleep_ts = {0, 2000000L}; /* 2ms poll */

    while (g_running) {
        while (ring_pop(ring, &ev)) {
            const char *tag = "UNKNOWN";
            if (ev.type == FAULT_RAM_LEAK)     tag = "RAM_LEAK";
            if (ev.type == FAULT_RACE_COND)    tag = "RACE_COND";
            if (ev.type == FAULT_OOB_HARD)     tag = "HARD_FAULT_OOB";
            if (ev.type == FAULT_CPU_HOG)      tag = "CPU_LEAK";
            if (ev.type == FAULT_KERNEL_PANIC) tag = "KERNEL_PANIC";

            std::printf("{\"ts\":%lu,\"pid\":%d,\"tid\":%d,\"app\":\"",
                        ev.timestamp_ns, ev.pid, ev.tid);
            print_json_escaped(ev.app_name);
            std::printf("\",\"type\":\"%s\",\"addr\":\"0x%lx\",\"msg\":\"",
                        tag, (unsigned long)ev.fault_addr);
            print_json_escaped(ev.detail);
            std::printf("\"}\n");
            std::fflush(stdout);
        }
        nanosleep(&sleep_ts, nullptr);
    }

    shm_unlink(SHM_NAME);
    return 0;
}
