#!/usr/bin/env bash
# tests/phase-07.3/test-stage0-apt-overlay.sh
#
# Self-test for the Pi source selection in
# overlays/pi-gen/stage0/00-configure-apt/00-run.sh. The overlay runs for real
# against a fake stage dir and rootfs; only on_chroot (the apt-get update and
# dist-upgrade inside the chroot) and gpg are stubbed. The flat repo fixture is
# built by scripts/lib/pi-archive-repo.sh from two tiny dpkg-deb-built debs.
#
# Runs on Linux only. On Linux, missing dpkg-dev is a FAILURE, not a skip.
if [[ "$(uname -s)" != Linux ]]; then
    echo "SKIP: this suite needs Linux (dpkg-deb, dpkg-scanpackages, GNU coreutils)." >&2
    exit 0
fi
set -uo pipefail
for tool in dpkg-deb dpkg-scanpackages python3; do
    command -v "${tool}" >/dev/null || { echo "FAIL: ${tool} not installed (apt-get install dpkg-dev python3-yaml)" >&2; exit 1; }
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OVERLAY="${REPO_ROOT}/overlays/pi-gen/stage0/00-configure-apt/00-run.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
PASSED=0
FAILED=0
A="alpha_1.0_arm64.deb"; B="beta_2.0_all.deb"
FLAT_LINE="deb [trusted=yes] file:/var/local/arlowe-pi-archive ./"

mkdeb() {
    local d="${WORK}/src/$1"
    mkdir -p "${d}/DEBIAN"
    printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: Test <test@example.invalid>\nDescription: fixture\n' \
        "$1" "$2" "$3" > "${d}/DEBIAN/control"
    dpkg-deb --root-owner-group -Zgzip --build "${d}" "${WORK}/pool/$4" >/dev/null
}
mkdir -p "${WORK}/pool"
mkdeb alpha 1.0 arm64 "${A}"
mkdeb beta 2.0 all "${B}"
{ echo 'pool_base: "file:///unused"'; echo 'packages:'
  for f in "${A}" "${B}"; do
      printf '  - {name: "%s", version: "%s", arch: "%s", filename: "%s", size: %s, sha256: "%s", url: "file:///unused/%s"}\n' \
          "${f%%_*}" "$(cut -d_ -f2 <<<"${f}")" "$(cut -d_ -f3 <<<"${f%.deb}")" "${f}" \
          "$(stat -c %s "${WORK}/pool/${f}")" "$(sha256sum "${WORK}/pool/${f}" | cut -d' ' -f1)" "${f}"
  done; } > "${WORK}/m.yml"
for f in "${A}" "${B}"; do printf '%s\t%s\n' "${f}" "${WORK}/pool/${f}"; done > "${WORK}/paths"
bash "${REPO_ROOT}/scripts/lib/pi-archive-repo.sh" --manifest "${WORK}/m.yml" --paths "${WORK}/paths" \
    --out "${WORK}/repo" >/dev/null || { echo "FAIL: fixture repo build failed" >&2; exit 1; }

mkdir -p "${WORK}/bin"
printf '#!/bin/sh\ncat\n' > "${WORK}/bin/gpg"; chmod +x "${WORK}/bin/gpg"
on_chroot() { cat >/dev/null; }
export -f on_chroot
export PATH="${WORK}/bin:${PATH}" RELEASE=bookworm APT_PROXY="" TEMP_REPO=""

# setup <case>: fresh stage dir (cwd for the overlay), rootfs and repo copy
setup() {
    C="${WORK}/$1"; S="${C}/stage"; R="${C}/rootfs"; REPO="${C}/repo"
    mkdir -p "${S}/files" "${C}/work" "${R}/etc/apt/sources.list.d" "${R}/etc/apt/apt.conf.d" "${R}/etc/apt/trusted.gpg.d"
    echo 'deb http://deb.debian.org/debian RELEASE main' > "${S}/files/sources.list"
    printf 'deb http://archive.raspberrypi.com/debian/ RELEASE main\n# Uncomment line below then %s\n#deb-src http://archive.raspberrypi.com/debian/ RELEASE main\n' \
        "'apt-get update' to enable 'apt-get source'" > "${S}/files/raspi.list"
    echo 'Acquire::Check-Valid-Until "false";' > "${S}/files/99arlowe-pinned"
    echo 'fake key' > "${S}/files/raspberrypi.gpg.key"
    cp -a "${WORK}/repo" "${REPO}"
    export ROOTFS_DIR="${R}" STAGE_WORK_DIR="${C}/work" ARLOWE_PI_REPO="${REPO}"
    unset ARLOWE_PI_ARCHIVE_MODE
}
run() { OUT="$(cd "${S}" && bash "${OVERLAY}" 2>&1)"; RC=$?; }
ok() {
    if [[ $? -eq 0 ]]; then echo "[OK]   $1"; PASSED=$((PASSED + 1))
    else
        echo "[FAIL] $1: rc=${RC:-}"; printf '       %s\n' "${OUT//$'\n'/$'\n'       }"
        FAILED=$((FAILED + 1))
    fi
}
IN_ROOTFS="var/local/arlowe-pi-archive"
LIST="etc/apt/sources.list.d"

setup pinned-default; run
[[ ${RC} -eq 0 \
   && "$(find "${R}/${IN_ROOTFS}" -mindepth 1 -printf '%f\n' 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')" == "Packages SHA256SUMS ${A} ${B} " \
   && "$(cat "${R}/${LIST}/arlowe-pi-archive.list" 2>/dev/null)" == "${FLAT_LINE}" \
   && ! -e "${R}/${LIST}/raspi.list" ]] &&
    (cd "${R}/${IN_ROOTFS}" && sha256sum --quiet -c SHA256SUMS)
ok "[pinned-default] mode unset: flat repo copied and verified in the rootfs, only the file: source, no raspi.list"

setup pinned-no-repo; unset ARLOWE_PI_REPO; run
[[ ${RC} -ne 0 && "${OUT}" == *ARLOWE_PI_REPO* && "${OUT}" == *sudo* && ! -e "${R}/${LIST}/arlowe-pi-archive.list" ]]
ok "[pinned-no-repo] ARLOWE_PI_REPO unset: fails, naming the variable and the sudo env list"

setup pinned-tampered; echo x >> "${REPO}/${B}"; run
[[ ${RC} -ne 0 && ! -e "${R}/${LIST}/arlowe-pi-archive.list" ]]
ok "[pinned-tampered] a deb changed after SHA256SUMS was written: fails before any source is written"

setup record; export ARLOWE_PI_ARCHIVE_MODE=record; run
[[ ${RC} -eq 0 \
   && "$(head -1 "${R}/${LIST}/raspi.list" 2>/dev/null)" == "deb http://archive.raspberrypi.com/debian/ bookworm main" \
   && "$(grep -c RELEASE "${R}/${LIST}/raspi.list")" == 0 \
   && ! -e "${R}/${IN_ROOTFS}" && ! -e "${R}/${LIST}/arlowe-pi-archive.list" ]]
ok "[record] upstream raspi.list with RELEASE substituted; no flat repo, no flat-repo list"

setup unknown-mode; export ARLOWE_PI_ARCHIVE_MODE=pinnedd; run
[[ ${RC} -ne 0 && "${OUT}" == *pinnedd* && ! -e "${R}/${LIST}/raspi.list" && ! -e "${R}/${LIST}/arlowe-pi-archive.list" ]]
ok "[unknown-mode] 'pinnedd' fails, naming the value; no Pi source written"

printf '\n%d passed, %d failed\n' "${PASSED}" "${FAILED}"
(( FAILED == 0 ))
