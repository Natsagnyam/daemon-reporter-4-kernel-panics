#!/usr/bin/env bash
set -euo pipefail

cd /home/natska/daemon-reporter-4-kernel-panics

cat << 'INNER_EOF' > wrappers/daemond-cc-race
#!/usr/bin/env bash
set -euo pipefail
exec gcc -O1 -g -fno-omit-frame-pointer \
     -fsanitize=thread -fno-pie -no-pie \
     -I/home/natska/daemon-reporter-4-kernel-panics/include \
     -L/home/natska/daemon-reporter-4-kernel-panics/build \
     -Wl,-rpath,/home/natska/daemon-reporter-4-kernel-panics/build \
     -Wl,--no-as-needed -ldaemond_hook "$@"
INNER_EOF
chmod +x wrappers/daemond-cc-race

rm -f build/app2
make build/app2

echo "--- Testing app2 with ASLR disabled (setarch x86_64 -R) ---"
TSAN_OPTIONS="halt_on_error=0:log_path=stderr" setarch x86_64 -R ./build/app2 || true
