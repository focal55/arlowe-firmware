#!/bin/bash
# Idempotent installer for arlowe systemd units. Copies units/*.service to
# /etc/systemd/system/ and runs daemon-reload. Invoked by pi-gen and by the
# Phase 3 Docker testbed.
set -euo pipefail

UNIT_SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET=/etc/systemd/system

install -d -m 0755 "$TARGET"

CHANGED=0
for unit in "$UNIT_SRC_DIR"/*.service; do
    name=$(basename "$unit")
    # Skip copy if identical — no daemon-reload churn on re-runs
    if ! cmp -s "$unit" "$TARGET/$name" 2>/dev/null; then
        install -m 0644 -o root -g root "$unit" "$TARGET/$name"
        CHANGED=1
    fi
done

if [[ "${CHANGED}" == "1" ]]; then
    # Skip daemon-reload when systemd is not running as PID 1 (e.g., Docker testbed
    # running with --entrypoint /bin/bash). systemd-analyze verify works without it.
    if [[ "$(cat /proc/1/comm 2>/dev/null)" == "systemd" ]]; then
        systemctl daemon-reload
    else
        echo "[install-units] skipping daemon-reload (systemd not PID 1)"
    fi
fi

# shellcheck disable=SC2012
count=$(ls "$UNIT_SRC_DIR"/*.service 2>/dev/null | wc -l)
echo "[install-units] ${count} units present in ${TARGET}"
