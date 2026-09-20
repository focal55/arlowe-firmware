#!/bin/bash
# Host-side step: clamp arlowe-authored rootfs mtimes to SOURCE_DATE_EPOCH, then
# assert the clamp actually took.
#
# WHY THIS EXISTS AT ALL
#
# SOURCE_DATE_EPOCH had no consumer. Before Phase 7.2 the string appeared exactly
# once in this repo -- a comment in 01-runtime/00-run-chroot.sh deferring the work
# to "plan 06-06's build orchestration", which never happened -- so Phase 6 SC5
# was never checkable: there was nothing to compare. Exporting the variable and
# calling the requirement met is precisely the shape of paper compliance this
# phase is correcting, so the variable gets one specific consumer whose claim can
# be DISPROVEN: "no arlowe-authored file carries an mtime later than the epoch".
# "The variable is exported" is not a falsifiable claim; this is.
#
# WHY THE SCOPE IS NARROW
#
# Only /opt/arlowe and /etc/systemd/system/arlowe-* are clamped, NOT the whole
# rootfs. Clamping Debian-installed files would fight dpkg, visibly break nothing,
# and make the assertion meaningless -- most of the rootfs is not ours to date,
# so a whole-rootfs claim would be broad theatre over a narrow truth. Honest
# narrow scope beats that.
#
# WHY AN ABSENT EPOCH IS A HARD FAILURE
#
# A silently skipped clamp is the exact failure mode this phase exists to
# eliminate: the build would go green while the thing it claims to do never ran.
# sudo builds a fresh environment, so SOURCE_DATE_EPOCH reaching this script
# depends on it being named in the explicit variable list on build-image.sh's
# `sudo ./build.sh` line, not merely exported. Dropping it from that list is a
# one-line mistake and this is what catches it.
#
# GNU find/touch only (-newermt, touch -d @epoch, -exec ... +). The build host is
# arm64 Debian; BSD equivalents differ and this never runs on macOS.
set -euo pipefail

ROOTFS_DIR="${ROOTFS_DIR:?ROOTFS_DIR is not set (pi-gen sets it; the self-test passes it)}"

EPOCH="${SOURCE_DATE_EPOCH:-}"
if [[ -z "${EPOCH}" ]]; then
    echo "[04-reproducibility] FAIL: SOURCE_DATE_EPOCH is unset." >&2
    echo "[04-reproducibility] It must be named in the explicit variable list on" >&2
    echo "[04-reproducibility] build-image.sh's 'sudo ... ./build.sh' line -- an" >&2
    echo "[04-reproducibility] exported-but-unlisted variable does not cross sudo." >&2
    echo "[04-reproducibility] Refusing to skip the clamp silently." >&2
    exit 1
fi
if [[ ! "${EPOCH}" =~ ^[0-9]+$ ]]; then
    echo "[04-reproducibility] FAIL: SOURCE_DATE_EPOCH is not a positive integer: '${EPOCH}'" >&2
    exit 1
fi

# /opt/arlowe is the anchor and its absence is a hard failure, not a no-op.
# This sub-stage runs last in stage-arlowe, after 01-runtime has installed the
# runtime tree, so a missing /opt/arlowe means the stage did not do its job. It
# also keeps the "0 paths clamped" outcome meaningful: with the anchor asserted,
# zero means everything was already at or below the epoch, rather than meaning
# there was nothing there to look at.
TARGETS=("${ROOTFS_DIR}/opt/arlowe")
if [[ ! -d "${TARGETS[0]}" ]]; then
    echo "[04-reproducibility] FAIL: ${TARGETS[0]} does not exist." >&2
    echo "[04-reproducibility] Nothing to clamp means stage-arlowe did not install" >&2
    echo "[04-reproducibility] the runtime tree; reporting success here would hide that." >&2
    exit 1
fi

# The arlowe units are additional targets, not required ones: which of them exist
# at this point is 01-runtime's business, and asserting a unit count here would
# duplicate the substrate gates in build-image.sh and go stale against them.
while IFS= read -r unit; do
    TARGETS+=("${unit}")
done < <(find "${ROOTFS_DIR}/etc/systemd/system" -maxdepth 1 -name 'arlowe-*' 2>/dev/null || true)

newer_than_epoch() {
    find "${TARGETS[@]}" -newermt "@${EPOCH}" -print
}

CLAMPED="$(newer_than_epoch | wc -l | tr -d ' ')"

# -h so a symlink's own mtime is set rather than its target's. find already uses
# lstat by default, so the listing and the fix agree about what is being dated.
if (( CLAMPED > 0 )); then
    find "${TARGETS[@]}" -newermt "@${EPOCH}" -exec touch -h -d "@${EPOCH}" {} +
fi

# The assertion is SEPARATE from the action on purpose. `find -exec touch +`
# batches, and a batch that partially fails still leaves find exiting 0, so the
# only honest confirmation is to re-ask the original question.
REMAINING="$(newer_than_epoch)"
if [[ -n "${REMAINING}" ]]; then
    echo "[04-reproducibility] FAIL: paths still newer than ${EPOCH} after the clamp:" >&2
    printf '%s\n' "${REMAINING}" | sed 's/^/    /' >&2
    exit 1
fi

echo "[04-reproducibility] clamped ${CLAMPED} path(s) to SOURCE_DATE_EPOCH=${EPOCH}"
echo "[04-reproducibility] asserted: 0 arlowe-authored paths newer than the epoch"
