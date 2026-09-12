#!/bin/bash
# Installs arlowe CLI symlinks at /usr/local/sbin/arlowe-* pointing into
# /opt/arlowe/runtime/cli/. Idempotent. Invoked by pi-gen and the Docker testbed.
#
# Purpose:
#   The CLI helpers are how support-mode SSH (Phase 10) and ad-hoc debugging
#   invoke arlowe internals. They must be discoverable in PATH and prefixed
#   arlowe-* to avoid namespace pollution.
#
# Idempotency contract:
#   ln -sf replaces an existing symlink without error. Re-running this script
#   produces no state change.
#
# Target population:
#   This script creates symlinks only; it does NOT copy files into
#   /opt/arlowe/runtime/cli/. The image build rsyncs the runtime tree first and
#   invokes this script AFTER (pi-gen/stage-arlowe/01-runtime/00-run-chroot.sh
#   step 6), so every target exists by the time we link. A dangling symlink is
#   never expected and is a hard error below.
#
# CLIS entries are BARE filenames under runtime/cli/. The link gets the
#   arlowe- prefix; the file must not carry it. runtime/cli/arlowe-ab did, so
#   arlowe-ab pointed at a nonexistent runtime/cli/ab and SC3 was untestable for
#   months (F7 #21). runtime/cli/identity follows the convention.
#
# Must be run as root (or via sudo).
set -euo pipefail

CLIS=(face speak stt record boot-check purge-logs run-logrotate wake-train ab identity)
TARGET_DIR=/opt/arlowe/runtime/cli
LINK_DIR=/usr/local/sbin

install -d -m 0755 "${LINK_DIR}"

for cli in "${CLIS[@]}"; do
    link="${LINK_DIR}/arlowe-${cli}"
    target="${TARGET_DIR}/${cli}"
    # ln -sf happily creates a dangling symlink, so a CLIS entry that does not
    # match a real file installs silently and only surfaces as "command not
    # found" on the device (F7 #21 -- arlowe-ab shipped broken this way).
    if [[ ! -e "${target}" ]]; then
        echo "[install-arlowe-cli] ERROR: no such CLI target: ${target}" >&2
        exit 1
    fi
    ln -sf "${target}" "${link}"
done

echo "[install-arlowe-cli] installed ${#CLIS[@]} symlinks in ${LINK_DIR}"
