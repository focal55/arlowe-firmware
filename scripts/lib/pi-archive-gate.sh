#!/usr/bin/env bash
# scripts/lib/pi-archive-gate.sh
#
# Phase 7.3 Pi-archive checks over a built rootfs. Sourced, not executed.
#
#   pi_archive_swap_back <rootfs> <pigen_dir> <release> <source_date_epoch>
#
# During the build the rootfs resolves Pi packages from a flat file: repo at
# PI_REPO_IN_ROOTFS instead of archive.raspberrypi.com. The swap-back takes that
# repo and its source back out and installs the stock upstream raspi.list, taken
# from pi-gen's own template with RELEASE substituted, so the shipped file is
# byte-identical to stock Pi OS. The device ships the live Pi archive because:
#
#   1. It keeps the device identical to stock Pi OS for on-device debugging
#      (apt install i2c-tools).
#   2. The update channel is the A/B image, not apt.
#   3. Shipping no Pi source breaks every on-device Pi package install for no gain.
#   4. Shipping the flat repo would cost about 170 MiB of the slot.
#
# Consequence: an on-device `apt upgrade` mixes the rolling Pi archive with the
# frozen Debian snapshot the image ships. That is unsupported, not an update
# mechanism. Slot B is an rsync clone of mounted slot A, so it inherits all this.
#
# RETURN CODES: 0 pass, 1 at least one FAIL. Functions print their own
# [OK]/[FAIL] lines and never exit.

PI_REPO_IN_ROOTFS="/var/local/arlowe-pi-archive"
PI_REPO_LIST="arlowe-pi-archive.list"

pi_archive_swap_back() {
    local rootfs="$1" pigen="$2" release="$3" epoch="$4"
    local template="${pigen}/stage0/00-configure-apt/files/raspi.list"
    local srcdir="${rootfs}/etc/apt/sources.list.d"
    local repo="${rootfs}${PI_REPO_IN_ROOTFS}" list="${srcdir}/${PI_REPO_LIST}"
    local tmp rc=0

    # The flat repo must not go until its replacement is known to exist.
    if [[ ! -f "${template}" ]]; then
        echo "[FAIL] pi-gen raspi.list template missing: ${template}; flat repo left in place"
        return 1
    fi

    rm -rf "${repo}" "${list}" 2>/dev/null
    tmp="$(mktemp)"
    sed "s/RELEASE/${release}/g" "${template}" > "${tmp}"
    install -m 644 "${tmp}" "${srcdir}/raspi.list"
    rm -f "${tmp}"
    if ! touch -h -d "@${epoch}" "${srcdir}/raspi.list" "${srcdir}" "${rootfs}/var/local"; then
        echo "[FAIL] could not clamp mtimes to SOURCE_DATE_EPOCH ${epoch}"; rc=1
    fi

    if [[ -e "${repo}" ]]; then
        echo "[FAIL] flat repo still in the rootfs: ${PI_REPO_IN_ROOTFS}"; rc=1
    fi
    if [[ -e "${list}" ]]; then
        echo "[FAIL] flat-repo source still in the rootfs: /etc/apt/sources.list.d/${PI_REPO_LIST}"; rc=1
    fi
    if ! grep -qE "^[[:space:]]*deb http://archive\.raspberrypi\.com/debian/ ${release} main" "${srcdir}/raspi.list"; then
        echo "[FAIL] /etc/apt/sources.list.d/raspi.list has no active archive.raspberrypi.com ${release} line"; rc=1
    fi
    [[ ${rc} -eq 0 ]] && echo "[OK] Pi flat repo removed; rootfs ships the stock raspi.list."
    return "${rc}"
}
