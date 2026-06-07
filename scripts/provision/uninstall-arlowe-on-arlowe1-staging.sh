#!/bin/bash
# Paired tear-down for install-arlowe-on-arlowe1-staging.sh. Restores the dev Pi to
# its pre-staging state: stops/removes staging units, rules, symlinks, trees, and
# the arlowe-staging user. Idempotent — a no-op when no staging user is present.
#
# Run on the dev Pi as root: sudo bash uninstall-arlowe-on-arlowe1-staging.sh
set -euo pipefail

if ! id arlowe-staging >/dev/null 2>&1; then
    echo "[uninstall] no arlowe-staging user; nothing to tear down."
    exit 0
fi

# Stop + disable + remove all staging unit files. Staging units are the only
# ones matching *-staging.service (prefix-renamed from arlowe-/qwen-/whisper-stt).
shopt -s nullglob
for unit in /etc/systemd/system/*-staging.service; do
    name="$(basename "$unit")"
    systemctl stop "$name" 2>/dev/null || true
    systemctl disable "$name" 2>/dev/null || true
    rm -f "$unit"
done
systemctl daemon-reload

for cli in face speak stt record boot-check purge-logs run-logrotate wake-train; do
    rm -f "/usr/local/sbin/arlowe-staging-$cli"
done

rm -f /etc/udev/rules.d/9?-arlowe-staging-*.rules
rm -f /etc/polkit-1/rules.d/5?-arlowe-staging-*.rules
command -v udevadm >/dev/null 2>&1 && { udevadm control --reload 2>/dev/null || true; }

rm -rf /opt/arlowe-staging /var/lib/arlowe-staging /etc/arlowe-staging

deluser --remove-home arlowe-staging >/dev/null 2>&1 \
    || userdel -r arlowe-staging >/dev/null 2>&1 || true

echo "[uninstall] arlowe-staging tear-down complete. Verify: id arlowe-staging (should fail)."
