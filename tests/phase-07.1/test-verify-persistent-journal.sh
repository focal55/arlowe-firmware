#!/usr/bin/env bash
# tests/phase-07.1/test-verify-persistent-journal.sh
#
# Self-test for scripts/lib/verify-persistent-journal.sh.
#
# Every fixture rootfs is built under `mktemp -d` and removed on exit.
#
# [pi-gen-default] is the load-bearing case: it is the rootfs every image shipped
# until this gate existed — pi-gen stage2 seds Storage=volatile into the main
# journald.conf and nothing overrides it — and it must FAIL.
#
# The two drop-in ordering cases exist because "a file saying persistent is
# present" is not the same claim as "journald will be persistent". journald
# applies drop-ins in basename order across /etc and /usr/lib, last assignment
# wins, and an /etc file masks a /usr/lib file of the same name.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/lib/verify-persistent-journal.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0

# A rootfs in the shape this repo intends to ship: pi-gen's volatile main file,
# overridden by the arlowe drop-in, with the journal bind-mounted from owner_state.
make_good_rootfs() {
    local r="$1"
    mkdir -p "${r}/etc/systemd/journald.conf.d" "${r}/var/log/journal" \
        "${r}/var/lib/arlowe/journal"
    printf '[Journal]\nStorage=volatile\n' > "${r}/etc/systemd/journald.conf"
    printf '[Journal]\nStorage=persistent\n' \
        > "${r}/etc/systemd/journald.conf.d/50-arlowe-persistent.conf"
    printf '%s\n' \
        'proc  /proc  proc  defaults  0  0' \
        '/var/lib/arlowe/journal  /var/log/journal  none  bind,nofail,x-systemd.requires-mounts-for=/var/lib/arlowe  0  0' \
        > "${r}/etc/fstab"
}

# expect <name> <pass|fail> <rootfs> [substring the output must contain]
expect() {
    local name="$1" want="$2" rootfs="$3" needle="${4:-}"
    local out rc
    out="$(verify_persistent_journal "${rootfs}" 2>&1)"
    rc=$?
    local ok=1
    if [[ "${want}" == pass && ${rc} -ne 0 ]]; then ok=0; fi
    if [[ "${want}" == fail && ${rc} -ne 1 ]]; then ok=0; fi
    if [[ -n "${needle}" && "${out}" != *"${needle}"* ]]; then ok=0; fi
    if (( ok )); then
        echo "[OK]   ${name}"
        PASSED=$((PASSED + 1))
    else
        echo "[FAIL] ${name}: wanted ${want} (rc=${rc})${needle:+ mentioning \"${needle}\"}"
        printf '       %s\n' "${out//$'\n'/$'\n'       }"
        FAILED=$((FAILED + 1))
    fi
}

r="${WORK}/pi-gen-default"
make_good_rootfs "${r}"
rm -f "${r}/etc/systemd/journald.conf.d/50-arlowe-persistent.conf"
expect "[pi-gen-default] volatile main file with no override fails" fail "${r}" "volatile"

r="${WORK}/good"
make_good_rootfs "${r}"
expect "[good] drop-in overrides pi-gen's volatile setting" pass "${r}"

r="${WORK}/later-dropin-wins"
make_good_rootfs "${r}"
mkdir -p "${r}/usr/lib/systemd/journald.conf.d"
printf '[Journal]\nStorage=volatile\n' > "${r}/usr/lib/systemd/journald.conf.d/60-vendor.conf"
expect "[later-dropin-wins] a /usr/lib drop-in sorting later overrides ours" fail "${r}" "60-vendor.conf"

r="${WORK}/etc-masks-usrlib"
make_good_rootfs "${r}"
mkdir -p "${r}/usr/lib/systemd/journald.conf.d"
printf '[Journal]\nStorage=volatile\n' \
    > "${r}/usr/lib/systemd/journald.conf.d/50-arlowe-persistent.conf"
expect "[etc-masks-usrlib] /etc masks a same-named /usr/lib drop-in" pass "${r}"

r="${WORK}/no-bind"
make_good_rootfs "${r}"
printf 'proc  /proc  proc  defaults  0  0\n' > "${r}/etc/fstab"
expect "[no-bind] persistent but on the slot root fails" fail "${r}" "/var/log/journal"

r="${WORK}/no-skeleton"
make_good_rootfs "${r}"
rmdir "${r}/var/lib/arlowe/journal"
expect "[no-skeleton] bind source absent from the owner_state skeleton fails" fail "${r}" "/var/lib/arlowe/journal"

r="${WORK}/no-rootfs"
out="$(verify_persistent_journal "${r}" 2>&1)"
rc=$?
if [[ ${rc} -eq 2 ]]; then
    echo "[OK]   [no-rootfs] unreadable rootfs is a hard error, not a pass or a fail"
    PASSED=$((PASSED + 1))
else
    echo "[FAIL] [no-rootfs] wanted rc=2, got rc=${rc}: ${out}"
    FAILED=$((FAILED + 1))
fi

# Root can search a 0000 directory, so this case only means something unprivileged.
if (( EUID != 0 )); then
    r="${WORK}/unsearchable"
    make_good_rootfs "${r}"
    chmod 000 "${r}/var/lib/arlowe"
    out="$(verify_persistent_journal "${r}" 2>&1)"
    rc=$?
    chmod 755 "${r}/var/lib/arlowe"
    if [[ ${rc} -eq 2 ]]; then
        echo "[OK]   [unsearchable] a 0750 arlowe dir read unprivileged is a hard error, not a false FAIL"
        PASSED=$((PASSED + 1))
    else
        echo "[FAIL] [unsearchable] wanted rc=2, got rc=${rc}: ${out}"
        FAILED=$((FAILED + 1))
    fi
fi

echo
echo "${PASSED} passed, ${FAILED} failed"
(( FAILED == 0 ))
