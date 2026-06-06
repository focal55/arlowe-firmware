#!/bin/bash
# Installs arlowe udev rules and polkit rule to system paths. Idempotent.
#
# Purpose:
#   Copies the three udev/polkit rule files from provision/ into the system
#   directories and reloads udev. This script is part of the Phase 3 provision
#   chain and is picked up automatically by tests/phase-3/docker/run-tests.sh.
#
# Idempotency contract:
#   Safe to re-run. install(1) overwrites existing files with identical contents;
#   no state is accumulated on repeated runs.
#
# Invocation patterns:
#   - Phase 3 Docker testbed: picked up by auto-discovery in run-tests.sh.
#   - Phase 6 pi-gen overlay stage: run as root during image build.
#   - Manual provisioning on the Pi: run as root via bash scripts/provision/install-arlowe-udev-polkit.sh
#
# Must be run as root (or via sudo).
set -euo pipefail

# This script lives at scripts/provision/install-arlowe-udev-polkit.sh.
# Resolve the repo root two levels up: scripts/provision -> scripts -> repo root.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UDEV_SRC="${REPO_ROOT}/provision/udev"
POLKIT_SRC="${REPO_ROOT}/provision/polkit"

# Verify source files exist before touching system dirs.
if [[ ! -d "${UDEV_SRC}" ]]; then
    echo "[install-udev-polkit] ERROR: udev source dir not found at ${UDEV_SRC}" >&2
    exit 1
fi
if [[ ! -d "${POLKIT_SRC}" ]]; then
    echo "[install-udev-polkit] ERROR: polkit source dir not found at ${POLKIT_SRC}" >&2
    exit 1
fi

# Create target directories if absent (idempotent via -d flag).
install -d -m 0755 /etc/udev/rules.d
install -d -m 0755 /etc/polkit-1/rules.d

# Install udev rules (mode 0644, root:root — standard for rules.d files).
install -m 0644 -o root -g root "${UDEV_SRC}"/*.rules /etc/udev/rules.d/

# Install polkit rules (mode 0644, root:root — standard for polkit rules.d).
install -m 0644 -o root -g root "${POLKIT_SRC}"/*.rules /etc/polkit-1/rules.d/

# Reload udev. In Docker containers without a running udev daemon this is a
# no-op; the error is suppressed with a diagnostic message so CI doesn't fail.
if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload 2>/dev/null \
        || echo "[install-udev-polkit] udevadm reload skipped (no running udev daemon — Docker testbed?)"
    udevadm trigger 2>/dev/null || true
fi

installed_count=$(ls /etc/udev/rules.d/9?-arlowe-*.rules /etc/polkit-1/rules.d/5?-arlowe-*.rules 2>/dev/null | wc -l)
echo "[install-udev-polkit] installed ${installed_count} rules"
