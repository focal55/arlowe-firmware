#!/bin/bash
# Phase 3 plan 05: install a parallel `arlowe-staging` user + layout + units +
# rules on the dev Pi, side-by-side with the existing daily-driver setup
# (which it never touches), to verify SC4 sandbox write-deny against REAL systemd
# and resolve the speculative group / device questions from research §12.
#
# Reuse strategy: the production install scripts (plans 01/02/04) hardcode the
# literal `arlowe`; this script sed-transforms copies of them into a temp dir and
# runs those, so plans 01-04's committed scripts are never edited. The udev/polkit
# RULE FILES (plan 03) are transformed + renamed directly here, because the
# production udev/polkit installer resolves repo paths relative to its own location
# and so cannot be run from a temp copy.
#
# Staging naming:
#   user/group   arlowe          -> arlowe-staging
#   paths        /opt|/var/lib|/etc/arlowe -> .../arlowe-staging
#   units        arlowe-face     -> arlowe-staging-face   (prefix; required by the
#                qwen-api        -> qwen-staging-api        polkit prefix-match rule)
#                whisper-stt     -> whisper-stt-staging
#   rules        90-arlowe-axera -> 90-arlowe-staging-axera
#
# Run on the dev Pi as root: sudo bash install-arlowe-on-arlowe1-staging.sh
# Tear down with uninstall-arlowe-on-arlowe1-staging.sh.
set -euo pipefail

# Hard-scope to the dev Pi: refuse anywhere the hostname doesn't start with "arlowe".
if [[ ! -r /etc/hostname ]] || ! grep -qE '^arlowe' /etc/hostname; then
    echo "Refusing: hostname does not start with 'arlowe'. This script is scoped to the dev Pi." >&2
    exit 1
fi

# Refuse to coexist with a production install — that path belongs to the Phase 6 image.
if id arlowe >/dev/null 2>&1; then
    echo "Production 'arlowe' user exists; this looks like a Phase 6 image, not the dev Pi." >&2
    echo "Refusing to run the staging install side-by-side with production." >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- user / fs / cli: sed-transform the production scripts, then run the copies.
# These three have no repo-relative file lookups, so running them from /tmp is safe.
for script in install-arlowe-user install-arlowe-fs install-arlowe-cli; do
    sed 's|arlowe|arlowe-staging|g' "$REPO_ROOT/scripts/provision/$script.sh" \
        > "$TMP/$script-staging.sh"
done
bash "$TMP/install-arlowe-user-staging.sh"
bash "$TMP/install-arlowe-fs-staging.sh"

# --- udev + polkit: transform + rename the rule files, install directly.
install -d -m 0755 /etc/udev/rules.d /etc/polkit-1/rules.d
for rule in "$REPO_ROOT"/provision/udev/*.rules; do
    dest="9$(basename "$rule" | sed 's|^9||; s|arlowe|arlowe-staging|')"
    sed 's|arlowe|arlowe-staging|g' "$rule" > "$TMP/$dest"
    install -m 0644 -o root -g root "$TMP/$dest" "/etc/udev/rules.d/$dest"
done
for rule in "$REPO_ROOT"/provision/polkit/*.rules; do
    dest="$(basename "$rule" | sed 's|arlowe|arlowe-staging|')"
    # Broad arlowe sub handles user + arlowe-/qwen- prefixes; whisper-stt has no
    # "arlowe" so its exact-match unit name needs its own substitution.
    sed -e 's|arlowe|arlowe-staging|g' \
        -e 's|whisper-stt\.service|whisper-stt-staging.service|g' \
        "$rule" > "$TMP/$dest"
    install -m 0644 -o root -g root "$TMP/$dest" "/etc/polkit-1/rules.d/$dest"
done
if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload 2>/dev/null || true
    udevadm trigger 2>/dev/null || true
fi

# --- units: prefix-rename + content transform + port remap (only ports that the
# unit files actually declare; face/stt/qwen ports are code/config-driven).
for unit in "$REPO_ROOT"/units/*.service; do
    name="$(basename "$unit" .service)"
    staging_name="$(echo "$name" | sed -e 's|^arlowe-|arlowe-staging-|' \
                                       -e 's|^qwen-|qwen-staging-|' \
                                       -e 's|^whisper-stt$|whisper-stt-staging|').service"
    sed -e 's|arlowe|arlowe-staging|g' \
        -e 's|qwen-|qwen-staging-|g' \
        -e 's|whisper-stt|whisper-stt-staging|g' \
        -e 's|PORT=3000|PORT=3001|g' \
        -e 's|localhost:8080|localhost:8081|g' \
        -e 's|localhost:8082|localhost:8083|g' \
        "$unit" > "$TMP/$staging_name"
    install -m 0644 -o root -g root "$TMP/$staging_name" "/etc/systemd/system/$staging_name"
done
systemctl daemon-reload

# --- CLI symlinks: sed the production installer (creates arlowe-staging-* links
# into /opt/arlowe-staging/runtime/cli), then populate the targets from the repo
# so the links resolve (Phase 6 populates these on a real image).
sed 's|arlowe|arlowe-staging|g' "$REPO_ROOT/scripts/provision/install-arlowe-cli.sh" \
    > "$TMP/install-arlowe-cli-staging.sh"
bash "$TMP/install-arlowe-cli-staging.sh"
for cli in face speak stt record boot-check purge-logs run-logrotate wake-train; do
    [[ -f "$REPO_ROOT/runtime/cli/$cli" ]] \
        && install -m 0755 -o root -g arlowe-staging "$REPO_ROOT/runtime/cli/$cli" \
           "/opt/arlowe-staging/runtime/cli/$cli"
done

echo "[install-arlowe-on-arlowe1-staging] staging environment provisioned."
echo "  Next: tests/phase-3/staging/06-sandbox-write-deny.sh + 07-hardware-speculative.sh"
echo "  Tear down: uninstall-arlowe-on-arlowe1-staging.sh"
