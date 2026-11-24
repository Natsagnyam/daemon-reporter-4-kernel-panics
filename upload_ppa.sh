#!/usr/bin/env bash
set -euo pipefail

KEY_ID="${1:-67C42199DDA4FD4E}"
PPA_TARGET="ppa:natska/daemon-reporter-4-kernel-panics"

cd /home/natska/daemon-reporter-4-kernel-panics
make clean
debuild -S -sa -k"${KEY_ID}"

CHANGES_FILE=$(ls -t ../daemon-reporter-4-kernel-panics_*_source.changes | head -n 1)
echo "Uploading ${CHANGES_FILE} to ${PPA_TARGET} (signed with ${KEY_ID})..."
dput "${PPA_TARGET}" "${CHANGES_FILE}"
