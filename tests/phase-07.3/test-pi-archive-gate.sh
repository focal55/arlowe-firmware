#!/usr/bin/env bash
# tests/phase-07.3/test-pi-archive-gate.sh
#
# Self-test for scripts/lib/pi-archive-gate.sh over a fabricated rootfs and a
# fabricated pi-gen tree under `mktemp -d`.
#
# Needs GNU coreutils (touch -d @N, stat -c), so it runs on Linux: the build
# host and CI. Anywhere else it prints SKIP.
if [[ "$(uname -s)" != Linux ]]; then
    echo "SKIP: this suite needs Linux (GNU touch -d @N, stat -c)." >&2
    exit 0
fi
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${REPO_ROOT}/scripts/lib/pi-archive-gate.sh"
WORK="$(mktemp -d)"
trap 'chmod -R u+w "${WORK}" 2>/dev/null; chattr -R -i "${WORK}" 2>/dev/null; rm -rf "${WORK}"' EXIT
PASSED=0
FAILED=0
SKIPPED=0
EPOCH=1700000000
LIST=etc/apt/sources.list.d/arlowe-pi-archive.list

# shellcheck source=scripts/lib/pi-archive-gate.sh
source "${LIB}" 2>/dev/null

# setup <case>: R is the rootfs, P the pi-gen dir, T the stock raspi.list template
setup() {
    local c="${WORK}/$1"
    R="${c}/rootfs"; P="${c}/pi-gen"; T="${P}/stage0/00-configure-apt/files/raspi.list"
    mkdir -p "${R}/var/local/arlowe-pi-archive" "${R}/etc/apt/sources.list.d" "${T%/*}"
    touch "${R}/var/local/arlowe-pi-archive/x.deb" "${R}/var/local/arlowe-pi-archive/Packages"
    echo 'deb [trusted=yes] file:/var/local/arlowe-pi-archive ./' > "${R}/${LIST}"
    printf 'deb http://archive.raspberrypi.com/debian/ RELEASE main\n# Uncomment line below then '"'"'apt-get update'"'"' to enable '"'"'apt-get source'"'"'\n#deb-src http://archive.raspberrypi.com/debian/ RELEASE main\n' > "${T}"
}
run() { OUT="$(pi_archive_swap_back "${R}" "${P}" bookworm "${EPOCH}" 2>&1)"; RC=$?; }
ok() {
    if [[ $? -eq 0 ]]; then echo "[OK]   $1"; PASSED=$((PASSED + 1))
    else
        echo "[FAIL] $1: rc=${RC:-}"; printf '       %s\n' "${OUT//$'\n'/$'\n'       }"
        FAILED=$((FAILED + 1))
    fi
}

setup swap; run
sed 's/RELEASE/bookworm/g' "${T}" > "${WORK}/expected"
[[ ${RC} -eq 0 && ! -e "${R}/var/local/arlowe-pi-archive" && ! -e "${R}/${LIST}" ]] &&
    cmp -s "${WORK}/expected" "${R}/etc/apt/sources.list.d/raspi.list" &&
    [[ "$(stat -c %a "${R}/etc/apt/sources.list.d/raspi.list")" == 644 ]]
ok "[swap-back] flat repo and its list gone; raspi.list is the stock template for bookworm, mode 644"

[[ "$(stat -c %Y "${R}/etc/apt/sources.list.d/raspi.list" "${R}/etc/apt/sources.list.d" "${R}/var/local" | sort -u)" == "${EPOCH}" ]]
ok "[swap-back-mtime] raspi.list, sources.list.d and var/local clamped to SOURCE_DATE_EPOCH"

setup notemplate; rm "${T}"; run
[[ ${RC} -eq 1 && -d "${R}/var/local/arlowe-pi-archive" && -e "${R}/${LIST}" ]]
ok "[swap-back-no-template] no raspi.list template: rc 1, flat repo left in place"

setup notremoved; rm "${R}/${LIST}"; mkdir "${R}/${LIST}"; touch "${R}/${LIST}/pinned"
chmod 555 "${R}/${LIST}"
if [[ ! -w "${R}/${LIST}" ]] || chattr +i "${R}/${LIST}/pinned" 2>/dev/null; then
    run
    [[ ${RC} -eq 1 && "${OUT}" == *arlowe-pi-archive.list* ]]
    ok "[swap-back-not-removed] a flat-repo list that survives removal: rc 1, named"
else
    echo "[SKIP] [swap-back-not-removed] running as root without chattr; cannot make removal fail"
    SKIPPED=$((SKIPPED + 1))
fi

echo "${PASSED} passed, ${FAILED} failed, ${SKIPPED} skipped"
[[ ${FAILED} -eq 0 ]]
