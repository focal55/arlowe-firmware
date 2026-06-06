#!/bin/bash
# Phase 3 SC5 assertion: CLI symlinks + boot-check default flip.
#
# Validates:
#   1. Each of the 8 /usr/local/sbin/arlowe-* symlinks exists.
#   2. Each symlink points to /opt/arlowe/runtime/cli/<unprefixed-name>.
#   3. Each symlink target exists (Docker testbed pre-stages marker files;
#      Phase 6 populates with real CLI scripts).
#   4. Each symlink is owned by root.
#   5. boot-check's ARLOWE_SYSTEMCTL_FLAGS default is '' (system-level),
#      not '--user' (Phase 1 legacy).
#   6. boot-check still honors the ARLOWE_SYSTEMCTL_FLAGS env override
#      for backward compatibility with ad-hoc --user invocations.
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }

CLIS=(face speak stt record boot-check purge-logs run-logrotate wake-train)

for cli in "${CLIS[@]}"; do
    link="/usr/local/sbin/arlowe-${cli}"
    target="/opt/arlowe/runtime/cli/${cli}"

    test -L "${link}"                     || fail "${link} is not a symlink"
    actual=$(readlink "${link}")
    test "${actual}" = "${target}"        || fail "${link} points to ${actual}, expected ${target}"

    # Target must exist — Docker testbed pre-stages empty marker files;
    # in production Phase 6 populates with real CLI scripts.
    test -e "${target}"                   || fail "${link} target ${target} does not exist"

    sym_owner=$(stat -c %U "${link}")
    test "${sym_owner}" = "root"          || fail "${link} owned by ${sym_owner}, expected root"
done

# Boot-check default-flip: ARLOWE_SYSTEMCTL_FLAGS default must be '' not '--user'.
grep -E '^\s*SYSTEMCTL_FLAGS="\$\{ARLOWE_SYSTEMCTL_FLAGS:-\}"' /opt/arlowe/runtime/cli/boot-check \
    || fail "boot-check did not flip default from --user to '' (system-level)"

# Backward-compat: --user mode is still supported by env override.
grep -q 'ARLOWE_SYSTEMCTL_FLAGS:-' /opt/arlowe/runtime/cli/boot-check \
    || fail "boot-check no longer honors ARLOWE_SYSTEMCTL_FLAGS override"

# Sanitization spot-check.
if grep -E 'focal55|/home/focal55|joe@focal55|iol-monorepo' /opt/arlowe/runtime/cli/boot-check; then
    fail "boot-check contains a banned literal"
fi

echo "[05-cli-symlinks] PASS"
