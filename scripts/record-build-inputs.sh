#!/usr/bin/env bash
# scripts/record-build-inputs.sh
#
# Writes a deterministic manifest of the inputs a build actually used, and diffs
# it against a committed reference.
#
#   record-build-inputs.sh --rootfs DIR --out FILE
#   record-build-inputs.sh --diff FILE --reference FILE
#
# PIN versus RECORD, a distinction this script must not blur.
#
# third_party/*/manifest.yml and the snapshot timestamp are PINS: inputs we
# chose. This manifest is a RECORD: an observation of everything that resolved,
# roughly 400 Debian packages nobody individually chose. Phase 7.2 SC5 asks for a
# recorded manifest that a gate diffs, not for 400 hand-maintained pins -- which
# is what snapshot.debian.org exists to make unnecessary. So the record covers
# everything resolved, the pins cover only what we control, and the gate diffs
# the record.
#
# OBSERVED versus DECLARED, the rule that makes the record worth keeping.
#
# Every field describing the BUILD is read from the built rootfs, never from the
# declaration that was supposed to produce it. debian_snapshot in particular is
# parsed out of ${ROOTFS}/etc/apt/sources.list and NEVER out of the overlay's own
# copy of that file: the overlay is what we asked for, the rootfs is what we got.
# Recording the overlay's value would assert a snapshot the rootfs may never have
# come from -- and then freeze that assertion as the committed authority, which
# is worse than recording nothing.
#
# The overlay's path is deliberately not written out anywhere in this file, this
# comment included. The check that this script cannot read the overlay is a plain
# `grep -c <that path> scripts/record-build-inputs.sh` expecting 0, and a mention
# here -- even one saying "we do not read this" -- would make that check fail on
# its own documentation, or worse, invite someone to teach it to skip comments
# and thereby to skip a real hit inside a heredoc. Same reasoning as the rolling
# mirror's absence from the overlay files in 07.2-01.
#
# pigen_ref and the pin rows are the exception and are genuinely declarations:
# they record what we chose. build-image.sh separately gates that the rootfs
# matches them. The manifest header says which is which so the split is on the
# page rather than in someone's head.
#
# SUDO. The pi-gen rootfs is root-owned (install-arlowe-fs.sh makes /opt/arlowe
# 0750 root:arlowe), so reading it needs sudo -- the same reason `du` and the
# substrate gates in build-image.sh use it. The self-test's fixture rootfs is
# owned by the invoking user and must NOT need sudo, or the self-test would block
# on a password prompt in CI. So sudo is used only when the admin database is
# genuinely unreadable, and never to paper over a different failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MANIFEST_VERSION="v1"

die() { printf '[record-build-inputs] FAIL: %s\n' "$*" >&2; exit 1; }

usage() {
    cat >&2 <<'EOF'
usage:
  record-build-inputs.sh --rootfs DIR --out FILE
  record-build-inputs.sh --diff FILE --reference FILE

exit codes for --diff:
  0  identical (or reference re-recorded under ARLOWE_INPUTS_ACCEPT=1)
  1  differs -- unified diff printed
  2  reference does not exist (first build has no baseline; not a failure)
EOF
    exit 64
}

MODE=""
ROOTFS=""
OUT=""
DIFF_FILE=""
REFERENCE=""

while (( $# > 0 )); do
    case "$1" in
        --rootfs)    MODE="record"; ROOTFS="${2:-}"; shift 2 ;;
        --out)       OUT="${2:-}"; shift 2 ;;
        --diff)      MODE="diff"; DIFF_FILE="${2:-}"; shift 2 ;;
        --reference) REFERENCE="${2:-}"; shift 2 ;;
        -h|--help)   usage ;;
        *)           printf '[record-build-inputs] unknown argument: %s\n' "$1" >&2; usage ;;
    esac
done

# ---------------------------------------------------------------------------
# --diff
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "diff" ]]; then
    [[ -n "${DIFF_FILE}" && -n "${REFERENCE}" ]] || usage
    [[ -f "${DIFF_FILE}" ]] || die "manifest to compare does not exist: ${DIFF_FILE}"

    # Exit 2 is deliberately distinct from exit 1. The first build has no
    # baseline, and "there is nothing to compare against yet" is not the same
    # event as "the inputs moved". Collapsing them would make the very first
    # build look like a drift failure, and the usual response to that is to
    # switch the gate off.
    if [[ ! -f "${REFERENCE}" ]]; then
        printf '[record-build-inputs] no reference at %s -- nothing to compare against.\n' "${REFERENCE}" >&2
        exit 2
    fi

    DIFF_OUT="$(diff -u \
        --label "reference: ${REFERENCE}" \
        --label "this build: ${DIFF_FILE}" \
        "${REFERENCE}" "${DIFF_FILE}" || true)"
    if [[ -z "${DIFF_OUT}" ]]; then
        printf '[record-build-inputs] inputs identical to the reference.\n'
        exit 0
    fi

    # Print the diff BEFORE acting on it either way. Under ARLOWE_INPUTS_ACCEPT
    # this is what makes accepting a bump a decision rather than a reflex.
    printf '%s\n' "${DIFF_OUT}"

    if [[ "${ARLOWE_INPUTS_ACCEPT:-}" == "1" ]]; then
        cp "${DIFF_FILE}" "${REFERENCE}"
        printf '[record-build-inputs] ARLOWE_INPUTS_ACCEPT=1 -- reference re-recorded: %s\n' "${REFERENCE}"
        printf '[record-build-inputs] commit it in the same change as the pin bump above.\n'
        exit 0
    fi

    printf '[record-build-inputs] build inputs differ from the recorded reference.\n' >&2
    printf '[record-build-inputs] If this bump is deliberate, re-record with:\n' >&2
    printf '[record-build-inputs]   ARLOWE_INPUTS_ACCEPT=1 %s --diff %s --reference %s\n' \
        "${BASH_SOURCE[0]}" "${DIFF_FILE}" "${REFERENCE}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# --rootfs
# ---------------------------------------------------------------------------
[[ "${MODE}" == "record" ]] || usage
[[ -n "${ROOTFS}" && -n "${OUT}" ]] || usage
[[ -d "${ROOTFS}" ]] || die "rootfs is not a directory: ${ROOTFS}"

# Strip the trailing slash and leave "/" as the empty string: every path below is
# built as "${ROOTFS}/etc/..." so an empty prefix yields /etc/... rather than the
# //etc/... that a restored "/" would produce. POSIX gives a leading "//"
# implementation-defined meaning, and it reads like a bug in every error message.
ROOTFS="${ROOTFS%/}"

NEED_SUDO=0
if [[ ! -r "${ROOTFS}/var/lib/dpkg/status" ]]; then
    NEED_SUDO=1
fi
# A function rather than an array prefix: an empty array expands badly under
# `set -u` on older bash, and this has to work identically for a root-owned
# pi-gen rootfs and a user-owned fixture.
as_reader() {
    if (( NEED_SUDO )); then sudo "$@"; else "$@"; fi
}

# --- source_date_epoch / worktree_clean -------------------------------------
# From the build environment when build-image.sh set them; derived from the repo
# otherwise, so a standalone run is still deterministic. Never the wall clock:
# `date` would guarantee two recordings of the same rootfs never match, which is
# the one property this file exists to have.
EPOCH="${SOURCE_DATE_EPOCH:-}"
if [[ -z "${EPOCH}" ]]; then
    EPOCH="$(git -C "${REPO_ROOT}" log -1 --format=%ct 2>/dev/null || true)"
fi
[[ "${EPOCH}" =~ ^[0-9]+$ ]] || die "no usable SOURCE_DATE_EPOCH (env unset and no commit in ${REPO_ROOT})"

CLEAN="${ARLOWE_WORKTREE_CLEAN:-}"
if [[ -z "${CLEAN}" ]]; then
    if [[ -n "$(git -C "${REPO_ROOT}" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
        CLEAN="false"
    else
        CLEAN="true"
    fi
fi

# --- pigen_ref (DECLARED) ---------------------------------------------------
# Read from build-image.sh rather than restated. A second copy of a pin is how a
# pin half-applies.
PIGEN_REF="$(sed -n 's/^PIGEN_REF="\(.*\)"$/\1/p' "${REPO_ROOT}/scripts/build-image.sh" | head -1)"
[[ -n "${PIGEN_REF}" ]] || die "cannot read PIGEN_REF from scripts/build-image.sh"

# --- debian_snapshot (OBSERVED) ---------------------------------------------
# Parsed from the BUILT ROOTFS. See the header: never from the overlay.
SOURCES_LIST="${ROOTFS}/etc/apt/sources.list"
SNAPSHOT=""
if [[ -f "${SOURCES_LIST}" ]]; then
    SNAPSHOT="$(as_reader grep -hoE 'snapshot\.debian\.org/archive/debian/[0-9]{8}T[0-9]{6}Z' "${SOURCES_LIST}" 2>/dev/null \
        | sed 's#.*/##' | LC_ALL=C sort -u | head -1 || true)"
fi
if [[ -z "${SNAPSHOT}" ]]; then
    printf '[record-build-inputs] FAIL: %s names no snapshot.debian.org timestamp.\n' "${SOURCES_LIST}" >&2
    printf '[record-build-inputs] An UNPINNED rootfs must not be blessed as the reference baseline --\n' >&2
    printf '[record-build-inputs] recording an empty or defaulted debian_snapshot would freeze a claim\n' >&2
    printf '[record-build-inputs] the rootfs does not support, and every later diff would compare to it.\n' >&2
    printf '[record-build-inputs] Note a deb822 layout is NOT accepted as a substitute: a host that moved\n' >&2
    printf '[record-build-inputs] its sources to /etc/apt/sources.list.d/*.sources leaves sources.list at 0\n' >&2
    printf '[record-build-inputs] bytes, and that host is not a built arlowe rootfs. Pass the pi-gen rootfs.\n' >&2
    exit 1
fi

# --- kernel_version (OBSERVED) ----------------------------------------------
# From the module directories in the rootfs, not from third_party/kernel/manifest.yml.
# The manifest is the pin; this is what the rootfs actually carries, and
# build-image.sh separately asserts the two agree.
MODULE_DIRS="$(as_reader ls -1 "${ROOTFS}/lib/modules" 2>/dev/null | LC_ALL=C sort || true)"
[[ -n "${MODULE_DIRS}" ]] || die "${ROOTFS}/lib/modules holds no kernel module directories"
# 6.12.96+rpt-rpi-2712 -> 6.12.96. Distinct versions are joined rather than
# reduced to one: a rootfs carrying two kernels must produce a visibly different
# manifest, not a silently chosen winner.
KERNEL_VERSION="$(printf '%s\n' "${MODULE_DIRS}" | sed 's/+.*$//' | LC_ALL=C sort -u | paste -sd, -)"

# --- pin rows (DECLARED) ----------------------------------------------------
# Walked generically out of every third_party/*/manifest.yml rather than naming
# four files here, so a new pinned dependency is recorded without editing this
# script -- the same reason the shellcheck file list uses find.
PIN_ROWS="$(python3 - "${REPO_ROOT}" <<'PY'
import os, sys, glob, yaml

repo = sys.argv[1]
rows = []

def walk(node, manifest_dir):
    """Emit (path, sha256) for every mapping carrying both filename and sha256."""
    if isinstance(node, dict):
        fn, sha = node.get("filename"), node.get("sha256")
        if isinstance(fn, str) and isinstance(sha, str):
            rows.append(("%s/%s" % (manifest_dir, fn), sha))
        for v in node.values():
            walk(v, manifest_dir)
    elif isinstance(node, list):
        for v in node:
            walk(v, manifest_dir)

for path in sorted(glob.glob(os.path.join(repo, "third_party", "*", "manifest.yml"))):
    rel = os.path.relpath(os.path.dirname(path), repo)
    with open(path) as fh:
        walk(yaml.safe_load(fh), rel)

for p, s in sorted(set(rows)):
    print("pin\t%s\t%s" % (p, s))
PY
)"
[[ -n "${PIN_ROWS}" ]] || die "no pinned artifacts found under third_party/*/manifest.yml"

# ax-llm is a git submodule, so its pin is a gitlink commit rather than a digest
# in a manifest. Read it from the index; do not transcribe it. A checkout with no
# .git (an rsync'd build tree, for instance) simply omits the row rather than
# aborting -- git exits 128 there, and under `set -o pipefail` that would kill an
# otherwise valid recording.
AXLLM_COMMIT="$(git -C "${REPO_ROOT}" ls-files -s third_party/ax-llm 2>/dev/null \
    | awk '$1 == "160000" {print $2}' || true)"
if [[ -n "${AXLLM_COMMIT}" ]]; then
    PIN_ROWS="$(printf '%s\npin\tthird_party/ax-llm\t%s\n' "${PIN_ROWS}" "${AXLLM_COMMIT}")"
fi
PIN_ROWS="$(printf '%s\n' "${PIN_ROWS}" | grep -v '^$' | LC_ALL=C sort)"

# --- pkg rows (OBSERVED) ----------------------------------------------------
# SC2016 is correct that ${Package} does not expand, and that is the point:
# these are dpkg-query's OWN template placeholders and the shell must leave them
# alone. Double quotes here would expand them to empty strings and emit one blank
# row per installed package.
# shellcheck disable=SC2016
PKG_ROWS="$(as_reader dpkg-query --admindir "${ROOTFS}/var/lib/dpkg" \
    -W -f='pkg\t${Package}\t${Version}\t${Architecture}\n' 2>/dev/null \
    | LC_ALL=C sort || true)"

PKG_COUNT="$(printf '%s\n' "${PKG_ROWS}" | grep -c '^pkg' || true)"
# HARD FAIL on zero rows, and this is the single most important check here.
# `dpkg-query --admindir <dir whose status file is empty> -W` exits 0 with no
# output, so an empty or unreadable admin database yields a zero-package manifest
# at exit 0. The self-test and the determinism probe would catch that; the first
# real build would NOT -- it hits the "no reference yet" warn, continues, and
# commits the empty result as the permanent baseline every later diff compares
# against. An empty reference is worse than no reference.
if (( PKG_COUNT == 0 )); then
    printf '[record-build-inputs] FAIL: dpkg-query resolved 0 packages from %s/var/lib/dpkg.\n' "${ROOTFS}" >&2
    printf '[record-build-inputs] dpkg-query exits 0 on an empty admin database, so this would\n' >&2
    printf '[record-build-inputs] otherwise be recorded as a valid manifest with no packages in it.\n' >&2
    exit 1
fi

# --- emit -------------------------------------------------------------------
# LF only, no trailing whitespace, no field that varies between two recordings of
# the same rootfs. An unsorted or timestamped field makes the diff gate fire on
# noise, and a gate that fires on noise is switched off within a week.
mkdir -p "$(dirname "${OUT}")"
{
    printf '# arlowe build inputs manifest %s\n' "${MANIFEST_VERSION}"
    printf '#\n'
    printf '# OBSERVED (read from the built rootfs -- what the build actually got):\n'
    printf '#   debian_snapshot, kernel_version, every pkg row\n'
    printf '# DECLARED (read from this repo -- what the build was told to use):\n'
    printf '#   pigen_ref, every pin row\n'
    printf '# ENVIRONMENT:\n'
    printf '#   source_date_epoch, worktree_clean\n'
    printf '#\n'
    printf '# Generated by scripts/record-build-inputs.sh. Do not hand-edit: the\n'
    printf '# committed copy is a baseline a gate diffs against, and an edited baseline\n'
    printf '# asserts something no build produced. Re-record a deliberate bump with\n'
    printf '# ARLOWE_INPUTS_ACCEPT=1.\n'
    printf 'source_date_epoch\t%s\n' "${EPOCH}"
    printf 'worktree_clean\t%s\n' "${CLEAN}"
    printf 'pigen_ref\t%s\n' "${PIGEN_REF}"
    printf 'debian_snapshot\t%s\n' "${SNAPSHOT}"
    printf 'kernel_version\t%s\n' "${KERNEL_VERSION}"
    printf '%s\n' "${PIN_ROWS}"
    printf '%s\n' "${PKG_ROWS}"
} > "${OUT}"

printf '[record-build-inputs] wrote %s\n' "${OUT}"
printf '[record-build-inputs]   debian_snapshot %s (observed)  kernel %s (observed)\n' \
    "${SNAPSHOT}" "${KERNEL_VERSION}"
printf '[record-build-inputs]   %s pinned artifacts, %s packages\n' \
    "$(printf '%s\n' "${PIN_ROWS}" | grep -c '^pin')" "${PKG_COUNT}"
