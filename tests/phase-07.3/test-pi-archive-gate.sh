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

# --- verify_pi_archive_resolution / pi_archive_run_check ---------------------
SNAP=snapshot.debian.org_archive_debian_20260915T000000Z_dists_bookworm
FLATL=_var_local_arlowe-pi-archive_._Packages
PIDEB='deb http://archive.raspberrypi.com/debian/ bookworm main'
sha() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
# stanza <name> <version> <arch> <filename>
stanza() { printf 'Package: %s\nVersion: %s\nArchitecture: %s\nFilename: %s\nSize: 1\nSHA256: %s\n\n' "$@" "$(sha "$1")"; }

# groot <dir>: R is a rootfs as a good pinned build leaves it before the swap-back; M and K
# are a manifest and kernel manifest beside it. Each snapshot list attributes one installed
# package, so a check handed only one of them fails. oldpkg is a normal rc package.
groot() {
    local c="$1" n v a L
    R="${c}/rootfs"; M="${c}/manifest.yml"; K="${c}/kernel.yml"; L="${c}/rootfs/var/lib/apt/lists"
    mkdir -p "${L}/partial" "${R}/etc/apt/sources.list.d" "${R}/var/lib/dpkg"
    echo 'deb http://snapshot.debian.org/archive/debian/20260915T000000Z/ bookworm main non-free-firmware' \
        > "${R}/etc/apt/sources.list"
    echo 'deb [trusted=yes] file:/var/local/arlowe-pi-archive ./' > "${R}/${LIST}"
    touch "${L}/lock"
    stanza pionly-a 1.0 arm64 ./pionly-a_1.0_arm64.deb > "${L}/${FLATL}"
    stanza debonly 5.0 arm64 pool/main/d/debonly/debonly_5.0_arm64.deb > "${L}/${SNAP}_main_binary-arm64_Packages"
    stanza fwonly 2.0 all pool/non-free-firmware/f/fwonly/fwonly_2.0_all.deb \
        > "${L}/${SNAP}_non-free-firmware_binary-arm64_Packages"
    printf 'packages:\n  - {name: "pionly-a", version: "1.0", arch: "arm64", filename: "pionly-a_1.0_arm64.deb", size: 1, sha256: "%s", url: "http://pi.example/p.deb"}\nresolve_only: []\n' \
        "$(sha pionly-a)" > "${M}"
    printf 'kernel:\n  deb_version: "6.12.96-1+rpt1"\n  debs:\n    - filename: "linux-image-6.12.96+rpt-rpi-2712_6.12.96-1+rpt1_arm64.deb"\n' > "${K}"
    {
        for row in "pionly-a 1.0 arm64" "debonly 5.0 arm64" "fwonly 2.0 all" "axclhost 3.10.2 all" \
                   "linux-image-6.12.96+rpt-rpi-2712 1:6.12.96-1+rpt1 arm64"; do
            read -r n v a <<< "${row}"
            printf 'Package: %s\nStatus: install ok installed\nArchitecture: %s\nVersion: %s\n\n' "${n}" "${a}" "${v}"
        done
        printf 'Package: oldpkg\nStatus: deinstall ok config-files\nArchitecture: arm64\nVersion: 0.1\n\n'
    } > "${R}/var/lib/dpkg/status"
}
gate() { OUT="$(verify_pi_archive_resolution "${R}" 2>&1)"; RC=$?; }
chk() { OUT="$(pi_archive_run_check "${R}" "${M}" "${K}" 2>&1)"; RC=$?; }
L_() { echo "${R}/var/lib/apt/lists"; }

groot "${WORK}/g-pass"; gate
[[ ${RC} -eq 0 && "${OUT}" == *"Pi archive resolution pinned: 1 flat-repo list files, 0 off-pin."* ]]
ok "[gate-pass] flat-repo list, snapshot lists, no Pi source or list: rc 0 with the count"

groot "${WORK}/g-live"; echo "${PIDEB}" > "${R}/etc/apt/sources.list.d/raspi.list"; gate
[[ ${RC} -eq 1 && "${OUT}" == *"${PIDEB}"* ]]
ok "[gate-declared-live] an active archive.raspberrypi.com line: rc 1, line printed"

groot "${WORK}/g-comment"; printf '# %s\n#%s\n' "${PIDEB}" "${PIDEB}" > "${R}/etc/apt/sources.list.d/raspi.list"; gate
[[ ${RC} -eq 0 ]]
ok "[gate-declared-commented] the same line commented out: rc 0"

groot "${WORK}/g-deb822"
printf 'Types: deb\nURIs: http://archive.raspberrypi.com/debian/\nSuites: bookworm\nComponents: main\n' \
    > "${R}/etc/apt/sources.list.d/raspi.sources"; gate
[[ ${RC} -eq 1 && "${OUT}" == *raspi.sources* ]]
ok "[gate-deb822] a deb822 .sources naming archive.raspberrypi.com: rc 1"

groot "${WORK}/g-noflat"; rm "$(L_)/${FLATL}"; gate
[[ ${RC} -eq 1 ]]
ok "[gate-no-flat-list] no flat-repo list file: rc 1"

groot "${WORK}/g-offpin"; touch "$(L_)/archive.raspberrypi.com_debian_dists_bookworm_main_binary-arm64_Packages"; gate
[[ ${RC} -eq 1 && "${OUT}" == *archive.raspberrypi.com_debian_dists_bookworm_main_binary-arm64_Packages* ]]
ok "[gate-offpin-list] a surviving archive.raspberrypi.com list: rc 1, named"

groot "${WORK}/g-nolists"; rm -rf "$(L_)"; gate
[[ ${RC} -eq 2 ]]
ok "[gate-no-lists-dir] no apt lists dir: rc 2 (could not test), never 0"

CHK_LINE="[pi-archive] check: 1 manifest packages installed at the pinned version, 5 installed packages attributed, 0 unattributed"
groot "${WORK}/c-pass"; chk
[[ ${RC} -eq 0 && "${OUT}" == *"${CHK_LINE}"* ]]
ok "[run-check-pass] both snapshot lists, the flat list and axclhost allow-listed: rc 0 with the summary"

groot "${WORK}/with space/c pass"; chk
[[ ${RC} -eq 0 && "${OUT}" == *"${CHK_LINE}"* ]]
ok "[run-check-paths-with-spaces] a rootfs under a path with spaces: rc 0, no word-splitting"

groot "${WORK}/c-nosnap"; rm "$(L_)/${SNAP}"_*; chk
[[ ${RC} -eq 2 && "${OUT}" == *snapshot.debian.org* ]]
ok "[run-check-no-snapshot-lists] no snapshot list: rc 2, checker never called without --debian-list"

groot "${WORK}/c-twoflat"; cp "$(L_)/${FLATL}" "$(L_)/${FLATL}.xz"; chk
[[ ${RC} -eq 2 && "${OUT}" == *"2 flat-repo list files"* ]]
ok "[run-check-two-flat-lists] two files match the flat-list prefix: rc 2, ambiguous"

groot "${WORK}/c-unclean"
sed -i '/^Package: pionly-a$/,/^$/s/^Status: .*/Status: install ok half-configured/' "${R}/var/lib/dpkg/status"; chk
[[ ${RC} -eq 1 && "${OUT}" == *"pionly-a: install ok half-configured"* ]]
ok "[run-check-dpkg-unclean] a half-configured package fails the gate and is named"

groot "${WORK}/c-local-unclean"
printf 'Package: axclhost\nStatus: install ok half-configured\nArchitecture: arm64\nVersion: 3.10.2\n\n' >> "${R}/var/lib/dpkg/status"; chk
[[ ${RC} -eq 0 ]]
ok "[run-check-local-unclean] a half-configured local package (axclhost, as every build leaves it) passes"

groot "${WORK}/c-fail"
printf 'Package: stray\nStatus: install ok installed\nArchitecture: arm64\nVersion: 1\n\n' >> "${R}/var/lib/dpkg/status"; chk
[[ ${RC} -eq 1 && "${OUT}" == *"stray 1 arm64: unattributed"* && "${OUT}" == *phase-07.3-pi-archive-pinning.md* ]]
ok "[run-check-fail-propagates] a check failure: rc 1, the checker's reason and the runbook pointer"

echo "${PASSED} passed, ${FAILED} failed, ${SKIPPED} skipped"
[[ ${FAILED} -eq 0 ]]
