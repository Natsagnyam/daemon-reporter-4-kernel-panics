# daemon-reporter-4-kernel-panics

Runtime C/C++ fault-detection daemon (`daemond`), sanitizer/signal hooks (`libdaemond_hook.so`), compiler wrappers, and a Rust `eframe`/`egui` live viewer for catching RAM leaks, data races, out-of-RAM pointer hard faults, and kernel panic events at runtime.

## Architecture

* **Shared Memory Ring (`include/daemond_shm.h`)**: Static shared-memory ring buffer (`/dev/shm/daemond_fault_ring_v1`) with cache-line-padded producer/consumer control structs (`__attribute__((aligned(64))`) and power-of-2 bitwise `&` masking (`RING_MASK`), zero heap `malloc` in the ring path.
* **Runtime Interceptor (`src/interceptor/libdaemond_hook.c`)**: Hooks `__sanitizer_report_error_summary` (LSan, TSan, ASan) and installs an alternate-stack (`sigaltstack`) handler for `SIGSEGV`, `SIGBUS`, and `SIGABRT`.
* **Reporter Daemon (`src/daemon/daemond.cpp`)**: Initializes the POSIX shared-memory ring, scans `/var/log/kern.log` for prior `Kernel panic` / `BUG:` lines, and streams JSON fault frames to stdout.
* **Rust eGUI Viewer (`egui-viewer/`)**: Spawns `build/daemond` and renders filterable fault cards (`KERNEL_PANIC`, `RAM_LEAK`, `RACE_COND`, `HARD_FAULT_OOB`).

## Build

```bash
cd /home/natska/daemon-reporter-4-kernel-panics
make
To build the Rust eGUI viewer as well:

Bash
cd /home/natska/daemon-reporter-4-kernel-panics
make egui-rust
Test Instructions
Option A: Live Rust eGUI View (Recommended)
Terminal 1 — Launch the Rust eGUI viewer (starts build/daemond):

Bash
cd /home/natska/daemon-reporter-4-kernel-panics
make egui-rust
Terminal 2 — Trigger each fault test case:

Bash
cd /home/natska/daemon-reporter-4-kernel-panics

# 1. RAM leak (app1.c)
./build/app1 || true

# 2. Data race condition (app2.c)
TSAN_OPTIONS="halt_on_error=0:log_path=stderr" setarch x86_64 -R ./build/app2 || true

# 3. Out-of-RAM pointer hard fault / SIGSEGV (app3.c)
./build/app3 || true

# 4. Safe KERNEL_PANIC frame to SHM (app4_panic.c)
# WARNING: Only pass --really-panic inside a VM or isolated test host.
./build/app4_panic
Inspect in eGUI: Use the top filter buttons (ALL, KERNEL_PANIC, RAM_LEAK, RACE_COND, HARD_FAULT_OOB) or Clear to reset the list.

Option B: CLI-Only Verification
Terminal 1 — Run daemond directly:

Bash
cd /home/natska/daemon-reporter-4-kernel-panics
./build/daemond
Terminal 2 — Execute the test binaries:

Bash
cd /home/natska/daemon-reporter-4-kernel-panics
./build/app1 || true
TSAN_OPTIONS="halt_on_error=0:log_path=stderr" setarch x86_64 -R ./build/app2 || true
./build/app3 || true
./build/app4_panic
Stop daemond: Press Ctrl+C in Terminal 1 to unlink /dev/shm/daemond_fault_ring_v1 and exit cleanly.

Commit & Push README
Bash
cd /home/natska/daemon-reporter-4-kernel-panics
git add README.md
git commit -m "Add README with build and fault test instructions"
git push origin main
