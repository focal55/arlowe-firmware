#!/usr/bin/env bash
# scripts/lib/pi-archive-gate.sh
#
# Phase 7.3 Pi-archive checks over a built rootfs. Sourced, not executed.
#
#   verify_pi_archive_resolution <rootfs>
#   pi_archive_run_check <rootfs> <manifest> <kernel_manifest>
#   pi_archive_swap_back <rootfs> <pigen_dir> <release> <source_date_epoch>
#
# The first two read the apt lists, so they run before the swap-back and before
# build-image.sh deletes the lists.
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
# RETURN CODES: 0 pass, 1 at least one FAIL, 2 could not test. Functions print
# their own [OK]/[FAIL]/[ERROR] lines and never exit.

PI_REPO_IN_ROOTFS="/var/local/arlowe-pi-archive"
PI_REPO_LIST="arlowe-pi-archive.list"
# apt's list name for `file:/var/local/arlowe-pi-archive ./`. Deliberately not
# derived from PI_REPO_IN_ROOTFS: a gate that computes its expectation from the
# thing it checks cannot notice the two drifting apart.
PI_REPO_LIST_PREFIX="_var_local_arlowe-pi-archive_._Packages"
PI_GATE_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PI_RUNBOOK="docs/operations/phase-07.3-pi-archive-pinning.md"

# _pi_lists <lists_dir> <name glob>: matching regular files, NUL-separated, sorted
_pi_lists() { find "$1" -maxdepth 1 -type f -name "$2" -print0 | sort -z; }

verify_pi_archive_resolution() {
    local rootfs="$1" apt="$1/etc/apt" lists="$1/var/lib/apt/lists" declared rc=0
    local -a flat offpin
    if [[ ! -d "${lists}" ]]; then
        echo "[ERROR] no apt lists dir at ${lists}; the Pi archive pin cannot be tested"
        return 2
    fi
    declared="$(
        find "${apt}/sources.list" "${apt}/sources.list.d" -maxdepth 1 -type f -name '*.list' \
            -exec grep -HvE '^[[:space:]]*(#|$)' {} + 2>/dev/null
        find "${apt}/sources.list.d" -maxdepth 1 -type f -name '*.sources' \
            -exec grep -HiE '^[[:space:]]*URIs:' {} + 2>/dev/null
    )"
    declared="$(grep -F 'archive.raspberrypi.com' <<< "${declared}")"
    if [[ -n "${declared}" ]]; then
        echo "[FAIL] the built rootfs declares the live Pi archive:"; echo "${declared}"; rc=1
    fi
    mapfile -d '' -t flat < <(_pi_lists "${lists}" "${PI_REPO_LIST_PREFIX}*")
    if (( ${#flat[@]} == 0 )); then
        echo "[FAIL] no apt list file starts with ${PI_REPO_LIST_PREFIX}; nothing resolved from the flat repo"
        rc=1
    fi
    # apt deletes a removed source's lists on update, so a survivor means that source was active.
    mapfile -d '' -t offpin < <(_pi_lists "${lists}" 'archive.raspberrypi.com_*')
    if (( ${#offpin[@]} > 0 )); then
        echo "[FAIL] ${#offpin[@]} apt list file(s) name the live Pi archive:"
        printf '  %s\n' "${offpin[@]##*/}"; rc=1
    fi
    (( rc == 0 )) && echo "[OK] Pi archive resolution pinned: ${#flat[@]} flat-repo list files, 0 off-pin."
    return "${rc}"
}

# Installed from a deb pinned elsewhere (third_party/axcl/manifest.yml), not from
# either archive. stage-arlowe deliberately leaves axclhost half-configured: its
# postinst cannot modprobe inside a chroot, so the build installs the built .ko
# itself (01-runtime/00-run-chroot.sh). Exempting it from the dpkg-state check
# below is safe because it is attributed as local, never to an archive.
PI_LOCAL_PACKAGES=(axclhost)

# dpkg-status stanzas in any state but `install ok installed` or `deinstall ok
# config-files`, as "name: status", skipping PI_LOCAL_PACKAGES. check counts only
# installed stanzas, so an unfinished archive package would otherwise escape
# attribution entirely.
_pi_unclean_status() {
    awk -v loc="${PI_LOCAL_PACKAGES[*]}" '
         BEGIN { n = split(loc, a, " "); for (i = 1; i <= n; i++) skip[a[i]] = 1 }
         function emit() { if (p != "" && !(p in skip) && s != "install ok installed" && s != "deinstall ok config-files")
                               print p ": " (s == "" ? "no Status" : s) }
         /^Package:/ { p = $2 } /^Status:/ { s = substr($0, 9) }
         /^$/ { emit(); p = ""; s = "" }
         END { emit() }' "$1"
}

pi_archive_run_check() {
    local rootfs="$1" manifest="$2" kmanifest="$3" rc=0 unclean f
    local status="$1/var/lib/dpkg/status" lists="$1/var/lib/apt/lists"
    local -a flat deb args
    if [[ ! -r "${status}" || ! -d "${lists}" ]]; then
        echo "[ERROR] ${status} or ${lists} missing; the completeness check cannot run"
        return 2
    fi
    unclean="$(_pi_unclean_status "${status}")"
    if [[ -n "${unclean}" ]]; then
        echo "[FAIL] dpkg left packages in an unfinished state; check cannot attribute them:"
        echo "  ${unclean//$'\n'/$'\n'  }"
        return 1
    fi
    mapfile -d '' -t flat < <(_pi_lists "${lists}" "${PI_REPO_LIST_PREFIX}*")
    if (( ${#flat[@]} != 1 )); then
        echo "[ERROR] ${#flat[@]} flat-repo list files match ${PI_REPO_LIST_PREFIX}*; need exactly one"
        printf '  %s\n' "${flat[@]##*/}"
        return 2
    fi
    mapfile -d '' -t deb < <(_pi_lists "${lists}" 'snapshot.debian.org_*binary-arm64_Packages*')
    if (( ${#deb[@]} == 0 )); then
        echo "[ERROR] no snapshot.debian.org binary-arm64 list in ${lists}; nothing to attribute Debian packages to"
        return 2
    fi
    args=(check --status "${status}" --manifest "${manifest}" --kernel-manifest "${kmanifest}"
          --flat-list "${flat[0]}")
    for f in "${deb[@]}"; do args+=(--debian-list "${f}"); done
    for f in "${PI_LOCAL_PACKAGES[@]}"; do args+=(--allow-local "${f}"); done
    python3 "${PI_GATE_REPO_ROOT}/scripts/lib/pi-archive-manifest.py" "${args[@]}" || rc=$?
    if (( rc == 1 )); then
        echo "[FAIL] Pi archive completeness check failed; see ${PI_RUNBOOK}, section 3 (Reading a failure)."
        echo "       If pi-gen instead stopped with 'Unable to locate package' or 'has no installation"
        echo "       candidate' for a Pi-only name, the manifest lacks that package: bump through record mode."
    fi
    return "${rc}"
}

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
