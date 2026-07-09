#!/bin/bash
# Host-side step: stage this sub-stage's files/ into the chroot at /files/.
# pi-gen does NOT auto-copy a sub-stage's files/ into the rootfs, so
# 00-run-chroot.sh cannot find arlowe-firstboot.service or arlowe-grow-models.sh
# unless we place them where it looks first ("/files/<name>"). Without this,
# the grow-models script (which has no inline fallback) is silently skipped and
# the models partition never grows to fill on first boot (SC2).
set -euo pipefail

if [[ -z "${ROOTFS_DIR:-}" ]]; then
    echo "[03-firstboot/00-run.sh] ERROR: ROOTFS_DIR is not set." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "${SCRIPT_DIR}/files" ]]; then
    install -d -m 0755 "${ROOTFS_DIR}/files"
    cp -a "${SCRIPT_DIR}/files/." "${ROOTFS_DIR}/files/"
    echo "[03-firstboot] staged files/ into chroot at /files/"
else
    echo "[03-firstboot] WARNING: no files/ dir at ${SCRIPT_DIR}/files" >&2
fi
