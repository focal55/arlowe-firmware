#!/bin/bash
# Creates the on-disk filesystem layout for the arlowe runtime.
#
# Purpose:
#   Provisions /opt/arlowe/ (code root, root:arlowe 0750), /var/lib/arlowe/
#   (owner state, arlowe:arlowe 0750), and /etc/arlowe/ (config dir, root:arlowe
#   0770 group-writable per ADR-0003) per the Phase 3 layout contract
#   (docs/operations/phase-3-layout.md).
#
# Idempotency contract:
#   `install -d` is idempotent — it sets owner and mode on each invocation,
#   so re-running this script produces no state change. Running twice and
#   comparing stat outputs yields identical results.
#
# Mount-point caveat (Phase 6):
#   In the production image /var/lib/arlowe is a separate ext4 partition
#   (PART-04). This script must run AFTER the partition is mounted and BEFORE
#   the units start. The behavior is identical whether /var/lib/arlowe is a
#   directory or a mount point — install -d creates directory contents inside
#   the already-mounted filesystem.
#
# Explicit non-actions (cross-phase contracts):
#   - Does NOT create /opt/arlowe/config/defaults.yml  (Phase 4 owns content)
#   - Does NOT create /etc/arlowe/config.yml           (absence is CONFIG-03 pairing trigger)
#   - Does NOT create /var/lib/arlowe/.ssh/            (Phase 10 creates at support-mode activation)
#
# Must be run as root (or via sudo). Requires install-arlowe-user.sh to have
# run first (asserts arlowe user exists before touching arlowe-owned paths).
set -euo pipefail

# Verify prerequisite: arlowe user must exist before we chown paths to it.
getent passwd arlowe >/dev/null 2>&1 \
    || { echo "[install-arlowe-fs] ERROR: arlowe user not found; run install-arlowe-user.sh first" >&2; exit 1; }

# ---------------------------------------------------------------------------
# /opt/arlowe/ — code root; root:arlowe 0750; read-only at runtime
# ---------------------------------------------------------------------------

install -d -o root -g arlowe -m 0750 /opt/arlowe
install -d -o root -g arlowe -m 0755 /opt/arlowe/runtime
install -d -o root -g arlowe -m 0755 /opt/arlowe/runtime/voice
install -d -o root -g arlowe -m 0755 /opt/arlowe/runtime/face
install -d -o root -g arlowe -m 0755 /opt/arlowe/runtime/stt
install -d -o root -g arlowe -m 0755 /opt/arlowe/runtime/tts
install -d -o root -g arlowe -m 0755 /opt/arlowe/runtime/llm
install -d -o root -g arlowe -m 0755 /opt/arlowe/runtime/dashboard
install -d -o root -g arlowe -m 0755 /opt/arlowe/runtime/wake-word
install -d -o root -g arlowe -m 0755 /opt/arlowe/runtime/cli
install -d -o root -g arlowe -m 0755 /opt/arlowe/third_party
install -d -o root -g arlowe -m 0755 /opt/arlowe/models
# venvs/ is empty in Phase 3; Phase 6 populates from runtime/*/requirements.txt
install -d -o root -g arlowe -m 0755 /opt/arlowe/venvs
# config/ directory reserved; defaults.yml NOT created — Phase 4 owns file content
install -d -o root -g arlowe -m 0755 /opt/arlowe/config

# ---------------------------------------------------------------------------
# /var/lib/arlowe/ — owner state; arlowe:arlowe 0750
# ---------------------------------------------------------------------------

install -d -o arlowe -g arlowe -m 0750 /var/lib/arlowe
install -d -o arlowe -g arlowe -m 0750 /var/lib/arlowe/logs
install -d -o arlowe -g arlowe -m 0750 /var/lib/arlowe/logs/voice
install -d -o arlowe -g arlowe -m 0750 /var/lib/arlowe/logs/face
install -d -o arlowe -g arlowe -m 0750 /var/lib/arlowe/logs/stt
install -d -o arlowe -g arlowe -m 0750 /var/lib/arlowe/logs/tts
install -d -o arlowe -g arlowe -m 0750 /var/lib/arlowe/logs/llm
install -d -o arlowe -g arlowe -m 0750 /var/lib/arlowe/logs/dashboard
# conversations/ and identity/ are 0700 — sensitive; world + group denied
install -d -o arlowe -g arlowe -m 0700 /var/lib/arlowe/conversations
# identity/ reserved for Phase 7 PKI (device cert + key); Phase 8 pairing daemon writes here
install -d -o arlowe -g arlowe -m 0700 /var/lib/arlowe/identity
install -d -o arlowe -g arlowe -m 0750 /var/lib/arlowe/state
install -d -o arlowe -g arlowe -m 0750 /var/lib/arlowe/wake-word
# dashboard/cache is NEXT_PRIVATE_CACHE_DIR target (Next.js runtime cache)
install -d -o arlowe -g arlowe -m 0750 /var/lib/arlowe/dashboard
install -d -o arlowe -g arlowe -m 0750 /var/lib/arlowe/dashboard/cache

# ---------------------------------------------------------------------------
# /etc/arlowe/ — config overlay dir; root:arlowe 0770 (ADR-0003)
# Group-writable so the arlowe-user dashboard can write the config overlay
# via a scoped ReadWritePaths entry. Write surface is bounded to this dir only.
# config.yml intentionally NOT created — its absence is the CONFIG-03 pairing trigger
# ---------------------------------------------------------------------------

install -d -o root -g arlowe -m 0770 /etc/arlowe

# Summary output — aids diagnosis in pi-gen log and Docker testbed output
if command -v tree >/dev/null 2>&1; then
    tree -L 2 /opt/arlowe /var/lib/arlowe
else
    ls -la /opt/arlowe /var/lib/arlowe
fi

echo "[install-arlowe-fs] layout provisioned"
