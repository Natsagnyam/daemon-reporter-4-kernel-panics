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
