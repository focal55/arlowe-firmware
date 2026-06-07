#!/bin/bash
# Provisions the `arlowe` system user on Debian/Pi OS.
#
# Purpose:
#   Creates the `arlowe` system user and assigns supplementary groups required
#   by the shipping service units. This is the foundation USER-01 / USER-02 /
#   USER-03 requirements (Phase 3).
#
# Idempotency contract:
#   Safe to re-run. If the `arlowe` user already exists, the useradd step is
#   skipped. Group membership is updated via usermod -aG which is idempotent.
#   HOME perms are always enforced to 0750 arlowe:arlowe.
#
# Invocation patterns:
#   - Phase 3 Docker testbed: run inside privileged container as root.
#   - Phase 6 pi-gen overlay stage: run as root during image build.
#   - Plan 03-05 staging variant: re-exported ARLOWE_* vars re-target at
#     arlowe-staging; that script calls this one with env overrides.
#
# Must be run as root (or via sudo).
set -euo pipefail

ARLOWE_HOME=/var/lib/arlowe
ARLOWE_SHELL=/usr/sbin/nologin

# Create the system user and matching primary group atomically.
# --system allocates a UID in SYS_UID_MIN..SYS_UID_MAX (100..999 on Debian).
# --create-home ensures /var/lib/arlowe exists with correct ownership; we then
# enforce the mode below because useradd defaults to 0755 on Debian.
if ! id -u arlowe >/dev/null 2>&1; then
    useradd \
        --system \
        --user-group \
        --create-home \
        --home-dir "${ARLOWE_HOME}" \
        --shell "${ARLOWE_SHELL}" \
        --comment "Arlowe runtime service account" \
        arlowe
fi

# Assign supplementary groups required by the shipping service units.
# Only adds groups that exist — gpio/spi are Pi OS-specific and absent from a
# plain Debian install; this guard keeps the script portable across testbed
# (Docker) and production (Pi OS) without branching the script body.
# usermod -aG is idempotent — running it twice does not duplicate membership.
#
# Group justification (see 03-RESEARCH.md §3 for full rationale):
#   audio   — ALSA /dev/snd/* for arlowe-voice + arlowe-wake-word (pyaudio)
#   gpio    — /dev/gpiomem + /dev/gpiochip* for arlowe-face (WhisPlay SPI chip-select)
#   spi     — /dev/spidev* for arlowe-face (WhisPlay LCD panel)
# dialout + video were dropped after plan 03-05 hardware verification: no /dev/fb0
# (WhisPlay is SPI, not framebuffer) and the WM8960 codec is I2C/in-kernel, so the
# voice service opens no serial device. See 03-05-SUMMARY.md.
for grp in audio gpio spi; do
    if getent group "${grp}" >/dev/null 2>&1; then
        usermod -aG "${grp}" arlowe
    fi
done

# Enforce HOME perms — useradd --create-home creates 0755 by default on Debian;
# USER-02 requires 0750 (group-readable, world-denied) so /var/lib/arlowe
# contents default to arlowe-only with explicit group exposure where needed.
chmod 0750 "${ARLOWE_HOME}"
chown arlowe:arlowe "${ARLOWE_HOME}"

echo "[install-arlowe-user] arlowe user provisioned (uid=$(id -u arlowe), groups=$(id -nG arlowe | tr ' ' ','))"
