#!/usr/bin/env bash
set -euo pipefail

cd /home/natska/daemon-reporter-4-kernel-panics
mkdir -p debian/source

cat << 'INNER_EOF' > debian/source/format
3.0 (native)
INNER_EOF

cat << 'INNER_EOF' > debian/changelog
daemon-reporter-4-kernel-panics (0.1.0-1~ppa1~noble1) noble; urgency=medium

  * Initial PPA release for daemond runtime fault reporter and hooks.
  * Captures RAM leaks (LSan/Valgrind), race conditions (TSan), out-of-RAM
    pointer hard faults (SIGSEGV/SIGBUS), and kernel panic diagnostics.

 -- Natsagnyam Namkhai <natska@example.com>  Tue, 24 Nov 2026 17:36:00 +0800
INNER_EOF

cat << 'INNER_EOF' > upload_ppa.sh
#!/usr/bin/env bash
set -euo pipefail

SERIES="${1:-noble}"
PPA_TARGET="ppa:natska/daemon-reporter-4-kernel-panics"

cd /home/natska/daemon-reporter-4-kernel-panics
make clean
debuild -S -sa

CHANGES_FILE=$(ls -t ../daemon-reporter-4-kernel-panics_*_source.changes | head -n 1)
echo "Uploading ${CHANGES_FILE} to ${PPA_TARGET} (${SERIES})..."
dput "${PPA_TARGET}" "${CHANGES_FILE}"
