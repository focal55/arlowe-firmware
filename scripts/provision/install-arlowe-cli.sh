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
#   /opt/arlowe/runtime/cli/. Phase 6 populates the targets during image build.
#   Symlinks may dangle briefly in the provision ordering; that is expected.
#
# Must be run as root (or via sudo).
set -euo pipefail

CLIS=(face speak stt record boot-check purge-logs run-logrotate wake-train ab)
TARGET_DIR=/opt/arlowe/runtime/cli
LINK_DIR=/usr/local/sbin

install -d -m 0755 "${LINK_DIR}"

for cli in "${CLIS[@]}"; do
    link="${LINK_DIR}/arlowe-${cli}"
    target="${TARGET_DIR}/${cli}"
    ln -sf "${target}" "${link}"
done

echo "[install-arlowe-cli] installed ${#CLIS[@]} symlinks in ${LINK_DIR}"
