#!/usr/bin/env bash
set -euo pipefail

cd /home/natska/daemon-reporter-4-kernel-panics
mkdir -p egui-viewer/src tests

# ------------------------------------------------------------------------------
# 1. Extend daemond_shm.h with FAULT_KERNEL_PANIC
# ------------------------------------------------------------------------------
cat << 'INNER_EOF' > include/daemond_shm.h
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
INNER_EOF

# ------------------------------------------------------------------------------
# 2. app4_panic.c: Kernel Panic Trigger (Safe SHM report + Optional SysRq 'c')
# ------------------------------------------------------------------------------
cat << 'INNER_EOF' > tests/app4_panic.c
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
INNER_EOF

# ------------------------------------------------------------------------------
# 3. Update daemond.cpp to emit KERNEL_PANIC and inspect /var/log/kern.log
# ------------------------------------------------------------------------------
cat << 'INNER_EOF' > src/daemon/daemond.cpp
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
INNER_EOF

# ------------------------------------------------------------------------------
# 4. Rust eGUI Live Fault & Kernel Panic Viewer (egui-viewer/)
# ------------------------------------------------------------------------------
cat << 'INNER_EOF' > egui-viewer/Cargo.toml
[package]
name = "daemond-egui-rust"
version = "0.1.0"
edition = "2021"

[dependencies]
eframe = "0.30"
egui = "0.30"
INNER_EOF

cat << 'INNER_EOF' > egui-viewer/src/main.rs
use eframe::egui;
use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;

#[derive(Clone, Debug)]
struct FaultRecord {
    ts: u64,
    pid: i32,
    tid: i32,
    app: String,
    fault_type: String,
    addr: String,
    msg: String,
}

fn extract_json_str(line: &str, key: &str) -> String {
    let pattern = format!("\"{}\":\"", key);
    if let Some(start_idx) = line.find(&pattern) {
        let rest = &line[start_idx + pattern.len()..];
        let mut out = String::new();
        let mut escaped = false;
        for ch in rest.chars() {
            if escaped {
                out.push(ch);
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == '"' {
                break;
            } else {
                out.push(ch);
            }
        }
        return out;
    }
    String::new()
}

fn extract_json_u64(line: &str, key: &str) -> u64 {
    let pattern = format!("\"{}\":", key);
    if let Some(start_idx) = line.find(&pattern) {
        let rest = &line[start_idx + pattern.len()..];
        let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
        return digits.parse::<u64>().unwrap_or(0);
    }
    0
}

fn extract_json_i32(line: &str, key: &str) -> i32 {
    let pattern = format!("\"{}\":", key);
    if let Some(start_idx) = line.find(&pattern) {
        let rest = &line[start_idx + pattern.len()..];
        let digits: String = rest
            .chars()
            .take_while(|c| c.is_ascii_digit() || *c == '-')
            .collect();
        return digits.parse::<i32>().unwrap_or(0);
    }
    0
}

struct DaemondGuiApp {
    events: Arc<Mutex<Vec<FaultRecord>>>,
    filter: String,
}

impl DaemondGuiApp {
    fn new(cc: &eframe::CreationContext<'_>, events: Arc<Mutex<Vec<FaultRecord>>>) -> Self {
        let ctx = cc.egui_ctx.clone();
        thread::spawn(move || {
            let child = Command::new("/home/natska/daemon-reporter-4-kernel-panics/build/daemond")
                .stdout(Stdio::piped())
                .spawn();

            if let Ok(mut proc) = child {
                if let Some(stdout) = proc.stdout.take() {
                    let reader = BufReader::new(stdout);
                    for line_res in reader.lines() {
                        if let Ok(line) = line_res {
                            if line.starts_with("{\"ts\":") {
                                let rec = FaultRecord {
                                    ts: extract_json_u64(&line, "ts"),
                                    pid: extract_json_i32(&line, "pid"),
                                    tid: extract_json_i32(&line, "tid"),
                                    app: extract_json_str(&line, "app"),
                                    fault_type: extract_json_str(&line, "type"),
                                    addr: extract_json_str(&line, "addr"),
                                    msg: extract_json_str(&line, "msg"),
                                };
                                if let Ok(mut guard) = events.lock() {
                                    guard.push(rec);
                                }
                                ctx.request_repaint();
                            }
                        }
                    }
                }
            }
        });

        Self {
            events,
            filter: "ALL".to_string(),
        }
    }
}

impl eframe::App for DaemondGuiApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        egui::TopBottomPanel::top("top_bar").show(ctx, |ui| {
            ui.horizontal(|ui| {
                ui.heading("C Runtime & Kernel Panic Reporter (eGUI)");
                ui.separator();
                for f in ["ALL", "KERNEL_PANIC", "RAM_LEAK", "RACE_COND", "HARD_FAULT_OOB"] {
                    if ui.selectable_label(self.filter == f, f).clicked() {
                        self.filter = f.to_string();
                    }
                }
                if ui.button("Clear").clicked() {
                    if let Ok(mut guard) = self.events.lock() {
                        guard.clear();
                    }
                }
            });
        });

        egui::CentralPanel::default().show(ctx, |ui| {
            let snapshot = self
                .events
                .lock()
                .map(|g| g.clone())
                .unwrap_or_default();

            egui::ScrollArea::vertical().show(ui, |ui| {
                for ev in snapshot.iter().rev() {
                    if self.filter != "ALL" && ev.fault_type != self.filter {
                        continue;
                    }
                    let badge_color = match ev.fault_type.as_str() {
                        "KERNEL_PANIC" => egui::Color32::from_rgb(220, 38, 38),
                        "HARD_FAULT_OOB" => egui::Color32::from_rgb(234, 88, 12),
                        "RACE_COND" => egui::Color32::from_rgb(202, 138, 4),
                        "RAM_LEAK" => egui::Color32::from_rgb(37, 99, 235),
                        _ => egui::Color32::GRAY,
                    };

                    egui::Frame::group(ui.style()).show(ui, |ui| {
                        ui.horizontal(|ui| {
                            ui.colored_label(badge_color, format!("[{}]", ev.fault_type));
                            ui.label(format!("app={} pid={} tid={} addr={}", ev.app, ev.pid, ev.tid, ev.addr));
                            ui.label(format!("ts={}ns", ev.ts));
                        });
                        ui.label(&ev.msg);
                    });
                    ui.add_space(4.0);
                }
            });
        });
    }
}

fn main() -> eframe::Result<()> {
    let events = Arc::new(Mutex::new(Vec::new()));
    let native_options = eframe::NativeOptions::default();
    eframe::run_native(
        "daemond-egui-rust",
        native_options,
        Box::new(move |cc| Ok(Box::new(DaemondGuiApp::new(cc, events)))),
    )
}
INNER_EOF

# ------------------------------------------------------------------------------
# 5. Update Makefile to include build/app4_panic and egui-viewer
# ------------------------------------------------------------------------------
cat << 'INNER_EOF' > Makefile
CC       ?= gcc
CXX      ?= g++
CFLAGS   := -O2 -Wall -Wextra -Iinclude -fPIC
CXXFLAGS := -std=c++20 -O2 -Wall -Wextra -Iinclude

all: build/daemond build/libdaemond_hook.so build/daemond-egui build/app1 build/app2 build/app3 build/app4_panic

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

build/app4_panic: tests/app4_panic.c include/daemond_shm.h
	@mkdir -p build
	$(CC) $(CFLAGS) tests/app4_panic.c -o build/app4_panic -lrt

egui-rust: build/daemond
	cd egui-viewer && cargo run --release

clean:
	rm -rf build

.PHONY: all clean egui-rust
INNER_EOF

echo "Added KERNEL_PANIC support (app4_panic + kern.log scan) and Rust eGUI viewer."
