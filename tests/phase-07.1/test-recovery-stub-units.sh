#!/usr/bin/env bash
# tests/phase-07.1/test-recovery-stub-units.sh
#
# Self-test for _rstub_remove_runtime_units in scripts/lib/recovery-stub.sh.
#
# Every fixture is a slot-B /etc/systemd/system as the clone leaves it: the
# repo's units installed and enabled the way units/install-units.sh does it
# (absolute symlinks into multi-user.target.wants), next to units this repo does
# not own. Built under `mktemp -d` and removed on exit.
#
# [voice-and-face] is the load-bearing case: those two units start as
# `python -m <module>` and name no pruned directory, so a removal keyed on Exec*
# paths would leave them enabled.
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

# make_slot_b <root> <units-src>
make_slot_b() {
    local root="$1" units_src="$2" sysd unit name
    sysd="${root}/etc/systemd/system"
    mkdir -p "${sysd}/multi-user.target.wants" "${sysd}/sockets.target.wants"
    for unit in "${units_src}"/*.service; do
        name="$(basename "${unit}")"
        cp "${unit}" "${sysd}/${name}"
        ln -s "/etc/systemd/system/${name}" "${sysd}/multi-user.target.wants/${name}"
    done
    printf '[Unit]\nDescription=first boot\n' > "${sysd}/arlowe-firstboot.service"
    ln -s /etc/systemd/system/arlowe-firstboot.service \
        "${sysd}/multi-user.target.wants/arlowe-firstboot.service"
    ln -s /lib/systemd/system/ssh.service "${sysd}/multi-user.target.wants/ssh.service"
    ln -s /lib/systemd/system/ssh.service "${sysd}/sshd.service"
}

remaining_repo_units() {
    local sysd="$1" units_src="$2" unit name
    for unit in "${units_src}"/*.service; do
        name="$(basename "${unit}")"
        find "${sysd}" -name "${name}" \( -type f -o -type l -o -type d \)
        find "${sysd}" -name "${name}.d"
    done
}

no_repo_unit_left() {
    [[ -z "$(remaining_repo_units "$1" "$2")" ]]
}

# --- the repo's real unit set ---------------------------------------------
r="${WORK}/real"
make_slot_b "${r}" "${REPO_ROOT}/units"
sysd="${r}/etc/systemd/system"
mkdir -p "${sysd}/qwen-api.service.d" "${sysd}/arlowe-voice.service.requires"
printf '[Service]\nNice=5\n' > "${sysd}/qwen-api.service.d/override.conf"
ln -s /etc/systemd/system/qwen-tokenizer.service \
    "${sysd}/arlowe-voice.service.requires/qwen-tokenizer.service"
_rstub_remove_runtime_units "${r}" "${REPO_ROOT}/units" >/dev/null

check "[real] no unit file, drop-in, or wants/requires link from units/ remains" \
    no_repo_unit_left "${sysd}" "${REPO_ROOT}/units"
check "[voice-and-face] python -m units are removed with the rest" \
    test ! -e "${sysd}/arlowe-voice.service" -a ! -L "${sysd}/multi-user.target.wants/arlowe-face.service"
check "[foreign] a unit this repo does not ship stays enabled" \
    test -L "${sysd}/multi-user.target.wants/ssh.service" -a -L "${sysd}/sshd.service"
check "[firstboot] the pi-gen-staged firstboot unit is not in scope" \
    test -f "${sysd}/arlowe-firstboot.service" -a -L "${sysd}/multi-user.target.wants/arlowe-firstboot.service"

# --- a unit added to units/ later is covered with no edit to the stub -------
src="${WORK}/units-plus-one"
mkdir -p "${src}"
cp "${REPO_ROOT}/units/"*.service "${src}/"
printf '[Unit]\nDescription=new\n[Install]\nWantedBy=multi-user.target\n' \
    > "${src}/arlowe-newthing.service"
r="${WORK}/plus-one"
make_slot_b "${r}" "${src}"
_rstub_remove_runtime_units "${r}" "${src}" >/dev/null
check "[new-unit] a unit added to units/ is removed without editing the stub" \
    no_repo_unit_left "${r}/etc/systemd/system" "${src}"

echo
echo "${PASSED} passed, ${FAILED} failed"
(( FAILED == 0 ))
