#!/usr/bin/env bash
# tests/phase-7/test-identity-store-check.sh
#
# Self-test for scripts/lib/identity-store-check.sh.
#
# Every fixture tree is built here at runtime under `mktemp -d` and removed on
# exit. Nothing under tests/phase-7/ is committed except this script: the
# fixtures include files named device.key and ca.pem, and committing them would
# both trip the phase's own "no tracked key material" gate and land them inside
# a scanned path, since pi-gen rsyncs runtime/ into the image with no excludes.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/lib/identity-store-check.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0

# Builds the shape a real build produces: install-arlowe-fs.sh creates
# /var/lib/arlowe/identity at 0700 inside the pi-gen chroot, plus the ordinary
# /opt/arlowe code tree.
new_root() {
  local root="${WORK}/$1"
  mkdir -p "${root}/opt/arlowe/config" "${root}/opt/arlowe/runtime/lib" \
           "${root}/etc/arlowe" "${root}/var/lib/arlowe/identity"
  chmod 0700 "${root}/var/lib/arlowe/identity"
  printf '%s\n' "$root"
}

# expect <0|1> <name> <root> [--factory]
expect() {
  local want="$1" name="$2"; shift 2
  local got=0
  check_identity_store "$@" >/dev/null 2>&1 || got=$?
  if [[ "$got" -eq "$want" ]]; then
    echo "PASS: ${name}"
  else
    echo "FAIL: ${name} (expected exit ${want}, got ${got})" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

# --- clean trees ------------------------------------------------------------

R="$(new_root clean)"
expect 0 "clean tree passes in device mode" "$R"

# This is precisely what install-arlowe-fs.sh leaves in the slot-A rootfs, so
# this case is the one proving the gate will not false-alarm the next build.
R="$(new_root build-shape)"
expect 0 "real build-time shape (present, empty, 0700) passes --factory" "$R" --factory

# --- material outside the identity store ------------------------------------

R="$(new_root opt-key)"
: > "${R}/opt/arlowe/config/device.key"
expect 1 "device.key under /opt/arlowe/config fails" "$R" --factory

R="$(new_root opt-pem)"
: > "${R}/opt/arlowe/runtime/lib/ca.pem"
expect 1 "ca.pem under /opt/arlowe/runtime/lib fails" "$R" --factory

R="$(new_root etc-crt)"
: > "${R}/etc/arlowe/device.crt"
expect 1 "device.crt under /etc/arlowe fails" "$R" --factory

R="$(new_root boot-key)"
mkdir -p "${R}/boot/firmware"
: > "${R}/boot/firmware/device.key"
expect 1 "device.key on the FAT boot partition fails" "$R" --factory

R="$(new_root opt-symlink)"
ln -s /var/lib/arlowe/identity/device.key "${R}/opt/arlowe/config/device.key"
expect 1 "symlink named device.key under /opt/arlowe fails without being followed" "$R"

# --- identity store modes ---------------------------------------------------

R="$(new_root loose-file)"
: > "${R}/var/lib/arlowe/identity/device.key"
chmod 0644 "${R}/var/lib/arlowe/identity/device.key"
expect 1 "identity file at 0644 fails" "$R"

R="$(new_root tight-file)"
: > "${R}/var/lib/arlowe/identity/device.key"
chmod 0600 "${R}/var/lib/arlowe/identity/device.key"
expect 0 "identity file at 0600 passes in device mode" "$R"

R="$(new_root loose-dir)"
chmod 0755 "${R}/var/lib/arlowe/identity"
expect 1 "identity store at 0755 instead of 0700 fails" "$R"

# --- store presence and factory emptiness -----------------------------------

R="$(new_root absent)"
rmdir "${R}/var/lib/arlowe/identity"
expect 1 "absent identity store fails --factory" "$R" --factory

R="$(new_root not-a-dir)"
rmdir "${R}/var/lib/arlowe/identity"
: > "${R}/var/lib/arlowe/identity"
expect 1 "identity store that is a regular file fails" "$R"

R="$(new_root provisioned)"
: > "${R}/var/lib/arlowe/identity/device-id"
chmod 0600 "${R}/var/lib/arlowe/identity/device-id"
expect 1 "provisioned device-id fails --factory" "$R" --factory
expect 0 "provisioned device-id passes in device mode" "$R"

# --- argument handling ------------------------------------------------------

R="$(new_root badflag)"
expect 1 "unknown flag is rejected" "$R" --bogus

echo "------------------------------------------------------------"
if [[ "$FAILURES" -ne 0 ]]; then
  echo "${FAILURES} case(s) failed" >&2
  exit 1
fi
echo "identity-store-check: all cases passed"
