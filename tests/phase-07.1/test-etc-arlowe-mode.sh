#!/usr/bin/env bash
# tests/phase-07.1/test-etc-arlowe-mode.sh
#
# Guards /etc/arlowe's root:arlowe 0770 against the post-build scripts that
# loop-mount the image. `install -d` resets the mode of an existing directory,
# so one stray `install -d -m 0755` there silently undoes the chroot's 0770 and
# arlowe (the dashboard, arlowe-pair) can no longer write the config overlay.
# The Phase 4 assertion checks 0770 on a docker tree, never on a built image.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/lib/recovery-stub.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0

check() {
    local name="$1"; shift
    if "$@"; then
        echo "[OK]   ${name}"
        PASSED=$((PASSED + 1))
    else
        echo "[FAIL] ${name}"
        FAILED=$((FAILED + 1))
    fi
}

# scan_etc_arlowe <file>... -- prints file:line for every `install -d` of the
# /etc/arlowe directory without 0770 and every chmod of it to another mode.
scan_etc_arlowe() {
    local target='etc/arlowe"?[[:space:]]*(\\)?$'
    grep -nHE -- "${target}" "$@" 2>/dev/null \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
        | awk -F: '
            { line = $0; sub(/^[^:]+:[0-9]+:/, "", line) }
            line ~ /(^|[^[:alnum:]_])install[[:space:]]/ && line ~ /[[:space:]]-d([[:space:]]|$)/ && line !~ /0770/ { print $1 ":" $2; next }
            line ~ /(^|[^[:alnum:]_])chmod[[:space:]]/ && line !~ /[[:space:]]0?770[[:space:]]/ { print $1 ":" $2 }
        '
}

repo_shell_files() {
    find "${REPO_ROOT}/scripts" "${REPO_ROOT}/pi-gen" -type f -name '*.sh'
    local f
    for f in "${REPO_ROOT}"/runtime/cli/*; do
        [[ -f "${f}" ]] && head -n 1 "${f}" | grep -qE '^#!.*(bash|/sh)$' && echo "${f}"
    done
}

no_output() { [[ -z "$1" ]]; }
one_line() { [[ -n "$1" && "$(printf '%s\n' "$1" | wc -l | tr -d ' ')" == 1 ]]; }

# --- the scan fires on the known-bad shape --------------------------------
# shellcheck disable=SC2016
printf '%s\n' 'sudo install -d -m 0755 "${mnt}/etc/arlowe"' > "${WORK}/bad.sh"
out="$(scan_etc_arlowe "${WORK}/bad.sh")"
check "[scan-negative] install -d -m 0755 of etc/arlowe is reported" one_line "${out}"
printf '%s\n' 'chmod 0755 /etc/arlowe' 'chmod 0770 /etc/arlowe' > "${WORK}/chmod.sh"
out="$(scan_etc_arlowe "${WORK}/chmod.sh")"
check "[scan-negative] chmod of etc/arlowe to 0755 is reported, to 0770 is not" one_line "${out}"

# shellcheck disable=SC2016
printf '%s\n' 'install -d -o root -g arlowe -m 0770 /etc/arlowe' \
    'sudo install -m 0644 "$map" "${mnt}/etc/arlowe/ab-partuuid-map"' > "${WORK}/good.sh"
out="$(scan_etc_arlowe "${WORK}/good.sh")"
check "[scan-positive] the contract's own install -d is not reported" no_output "${out}"

# --- the repo's build scripts ---------------------------------------------
files=()
while IFS= read -r f; do files+=("${f}"); done < <(repo_shell_files)
out="$(scan_etc_arlowe "${files[@]}")"
[[ -n "${out}" ]] && printf '%s\n' "${out//${REPO_ROOT}\//}" | sed 's/^/       offender: /'
check "[scan-repo] no build script resets /etc/arlowe's mode" no_output "${out}"

# --- behavioural: the slot-B PARTUUID map write keeps the chroot's mode -----
file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
sudo() { "$@"; }
slot="${WORK}/slot"
mkdir -p "${slot}/etc/arlowe"
chmod 0770 "${slot}/etc/arlowe"
printf 'A=x\nB=y\n' > "${WORK}/map"
_rstub_write_partuuid_map "${slot}" "${WORK}/map" >/dev/null
dir_mode="$(file_mode "${slot}/etc/arlowe")"
map_mode="$(file_mode "${slot}/etc/arlowe/ab-partuuid-map")"
check "[partuuid-map-keeps-mode] /etc/arlowe stays 770 (got ${dir_mode}), map is 644 (got ${map_mode})" \
    test "${dir_mode}" = 770 -a "${map_mode}" = 644

echo
echo "${PASSED} passed, ${FAILED} failed"
(( FAILED == 0 ))
