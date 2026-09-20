#!/usr/bin/env bash
# tests/phase-07.2/test-record-build-inputs.sh
#
# Self-test for scripts/record-build-inputs.sh. No real rootfs, no network.
#
# The fixture is a whole ROOTFS, not just a dpkg admindir. The recorder reads
# three separate things out of the rootfs -- the package database, the apt
# sources, and the kernel module directories -- so a fixture supplying only one
# of them would exercise only one and the other two would be untested while the
# suite reported green.
#
#   --emit-fixture   build the fixture, print its path, exit 0.
#                    The determinism probe in the plan's <verify> runs against
#                    it, because `--rootfs /` is a rootfs this recorder is
#                    SPECIFIED to reject: the arm64 build host runs trixie, whose
#                    /etc/apt/sources.list is 0 bytes because Debian moved to
#                    deb822. Wrapping that refusal in `|| true` would leave two
#                    empty manifests, and cmp would call them deterministic while
#                    sort -c called them sorted -- two green lines from two empty
#                    files. The refusal is asserted as its own case instead.
#
# Needs GNU coreutils and dpkg-query: runs on the build host and in CI, not on
# macOS. Same constraint as test-pigen-overlay.sh, and the same up-front skip so
# a Mac run says so once instead of failing six cases confusingly.

if ! command -v dpkg-query >/dev/null 2>&1; then
    echo "SKIP: this suite requires dpkg-query. Run it on the build host or in CI." >&2
    exit 0
fi

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RECORDER="${REPO_ROOT}/scripts/record-build-inputs.sh"

# Fixed values so two recordings cannot differ for an environmental reason and
# be mistaken for a recorder bug.
export SOURCE_DATE_EPOCH=1700000000
export ARLOWE_WORKTREE_CLEAN=true

FIXTURE_SNAPSHOT="20260915T000000Z"
# Deliberately NOT the real pinned kernel version: if the recorder ever read
# /lib/modules from the host or third_party/kernel/manifest.yml instead of from
# the fixture rootfs, a matching value would hide it.
FIXTURE_KVER="9.9.9+rpt-rpi-2712"

# ---------------------------------------------------------------------------
# Fixture builder. Emits a rootfs at $1.
#
# mode: "snapshot" (default) | "empty-sources" | "deb822"
# ---------------------------------------------------------------------------
make_fixture() {
    local root="$1" mode="${2:-snapshot}"

    mkdir -p "${root}/var/lib/dpkg" \
             "${root}/etc/apt/sources.list.d" \
             "${root}/lib/modules/${FIXTURE_KVER}"

    # A dpkg admin database dpkg-query can actually read. Deliberately written
    # OUT of C-sorted order so the sortedness case is testing the recorder's
    # sort rather than the fixture's insertion order.
    cat > "${root}/var/lib/dpkg/status" <<'EOF'
Package: zlib1g
Status: install ok installed
Priority: required
Section: libs
Architecture: arm64
Version: 1:1.2.13.dfsg-1
Description: compression library

Package: adduser
Status: install ok installed
Priority: important
Section: admin
Architecture: all
Version: 3.134
Description: add and remove users

Package: mount
Status: install ok installed
Priority: required
Section: admin
Architecture: arm64
Version: 2.38.1-5+deb12u1
Description: tools for mounting filesystems

Package: base-files
Status: install ok installed
Priority: required
Section: admin
Architecture: arm64
Version: 12.4+deb12u5
Description: base system miscellaneous files
EOF
    : > "${root}/var/lib/dpkg/available"

    case "${mode}" in
        snapshot)
            cat > "${root}/etc/apt/sources.list" <<EOF
deb http://snapshot.debian.org/archive/debian/${FIXTURE_SNAPSHOT} bookworm main contrib non-free non-free-firmware
deb http://snapshot.debian.org/archive/debian-security/${FIXTURE_SNAPSHOT} bookworm-security main contrib non-free non-free-firmware
EOF
            ;;
        empty-sources)
            : > "${root}/etc/apt/sources.list"
            ;;
        deb822)
            # The build host's own shape: sources.list is 0 bytes and everything
            # lives in a deb822 .sources file. The recorder must refuse this.
            : > "${root}/etc/apt/sources.list"
            cat > "${root}/etc/apt/sources.list.d/debian.sources" <<EOF
Types: deb
URIs: http://snapshot.debian.org/archive/debian/${FIXTURE_SNAPSHOT}
Suites: bookworm
Components: main
EOF
            ;;
    esac
}

PASSED=0
FAILED=0
pass() { printf '[PASS] %s\n' "$1"; PASSED=$(( PASSED + 1 )); }
fail() { printf '[FAIL] %s -- %s\n' "$1" "${2:-}"; FAILED=$(( FAILED + 1 )); }

# --emit-fixture: build a fixture somewhere durable and print the path.
if [[ "${1:-}" == "--emit-fixture" ]]; then
    F="$(mktemp -d)"
    make_fixture "${F}/rootfs" snapshot
    printf '%s\n' "${F}/rootfs"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

make_fixture "${WORK}/rootfs" snapshot

# ---------------------------------------------------------------------------
# [determinism] two recordings byte-identical, with a non-empty pkg table
# asserted FIRST.
#
# Ordering is the point. Two empty manifests compare identical, so a comparison
# that passes before anything has been shown to be in the file is evidence of
# nothing at all.
# ---------------------------------------------------------------------------
"${RECORDER}" --rootfs "${WORK}/rootfs" --out "${WORK}/m1" > "${WORK}/rec1.log" 2>&1
RC1=$?
"${RECORDER}" --rootfs "${WORK}/rootfs" --out "${WORK}/m2" > "${WORK}/rec2.log" 2>&1
RC2=$?

if (( RC1 != 0 || RC2 != 0 )); then
    fail "[recording] both recordings exit 0" "rc=${RC1},${RC2}; see below"
    cat "${WORK}/rec1.log"
else
    pass "[recording] both recordings exit 0"
fi

PKG_N="$(grep -c '^pkg' "${WORK}/m1" 2>/dev/null || true)"
if (( PKG_N >= 3 )); then
    pass "[floor] recorded ${PKG_N} pkg rows (>= 3) -- the probe measured something"
else
    fail "[floor] pkg table has ${PKG_N} rows" "an empty manifest compares identical to another empty one"
fi

if cmp -s "${WORK}/m1" "${WORK}/m2"; then
    pass "[determinism] two recordings of one rootfs are byte-identical"
else
    fail "[determinism] recordings differ" "$(diff -u "${WORK}/m1" "${WORK}/m2" | head -20)"
fi

# ---------------------------------------------------------------------------
# [sorted] pkg rows are LC_ALL=C sorted, with a negative control.
#
# The fixture's status file deliberately lists zlib1g, adduser, mount,
# base-files in that order, i.e. not sorted.
#
# An earlier version of this case tried to distinguish C collation from locale
# collation using an uppercase package name. That was wrong twice over and the
# suite caught it: dpkg normalises package names to lowercase (Base-Files is
# parsed and reported as base-files), and proving the locale dimension at all
# would need a UTF-8 locale generated on the host, which would make the case
# pass or silently degrade depending on the machine.
#
# So the claim is the narrower true one -- the rows are in C order -- and it
# gets a negative control instead: the same check, fed a deliberately unsorted
# permutation, must FAIL. Without that, `sort -c` passing tells us nothing about
# whether `sort -c` can ever fail here.
# ---------------------------------------------------------------------------
grep '^pkg' "${WORK}/m1" > "${WORK}/pkgs"
if LC_ALL=C sort -c "${WORK}/pkgs" 2>/dev/null; then
    pass "[sorted] pkg rows are LC_ALL=C sorted"
else
    fail "[sorted] pkg rows are not LC_ALL=C sorted" "$(head -5 "${WORK}/pkgs")"
fi

LC_ALL=C sort -r "${WORK}/pkgs" > "${WORK}/pkgs-reversed"
if cmp -s "${WORK}/pkgs" "${WORK}/pkgs-reversed"; then
    fail "[sorted-control] reversed copy equals the original" "the control cannot discriminate"
elif LC_ALL=C sort -c "${WORK}/pkgs-reversed" 2>/dev/null; then
    fail "[sorted-control] sort -c accepted an unsorted file" "the sortedness check is vacuous"
else
    pass "[sorted-control] sort -c rejects an unsorted permutation -- the check can fail"
fi

# ---------------------------------------------------------------------------
# [observed-snapshot] debian_snapshot comes from the FIXTURE rootfs, and is not
# the overlay's value.
#
# The fixture deliberately shares the overlay's timestamp, because that is the
# realistic case -- so equality alone proves nothing. The load-bearing check is
# the one below it: the recorder must not name the overlay path at all.
# ---------------------------------------------------------------------------
REC_SNAP="$(awk -F'\t' '$1=="debian_snapshot"{print $2}' "${WORK}/m1")"
FIX_SNAP="$(grep -hoE '[0-9]{8}T[0-9]{6}Z' "${WORK}/rootfs/etc/apt/sources.list" | head -1)"
if [[ -n "${REC_SNAP}" && "${REC_SNAP}" == "${FIX_SNAP}" ]]; then
    pass "[observed-snapshot] recorded ${REC_SNAP}, matching the fixture's sources.list"
else
    fail "[observed-snapshot] recorded '${REC_SNAP}'" "fixture says '${FIX_SNAP}'"
fi

if grep -q 'overlays/pi-gen' "${RECORDER}"; then
    fail "[observed-snapshot] recorder references overlays/pi-gen in code" \
         "$(grep -n 'overlays/pi-gen' "${RECORDER}" | grep -v '^\s*#' | head -3)"
else
    pass "[observed-snapshot] recorder never reads the overlay declaration"
fi

# ---------------------------------------------------------------------------
# [observed-kernel] kernel_version comes from the fixture's /lib/modules, not
# from third_party/kernel/manifest.yml. The fixture uses 9.9.9, which no
# manifest contains, so a recorder reading the manifest would fail here.
# ---------------------------------------------------------------------------
REC_KVER="$(awk -F'\t' '$1=="kernel_version"{print $2}' "${WORK}/m1")"
if [[ "${REC_KVER}" == "9.9.9" ]]; then
    pass "[observed-kernel] kernel_version 9.9.9 read from the fixture's /lib/modules"
else
    fail "[observed-kernel] kernel_version is '${REC_KVER}'" "expected 9.9.9 from the fixture"
fi

# ---------------------------------------------------------------------------
# [unpinned-rootfs] a rootfs whose sources.list names no snapshot is REFUSED.
#
# Both shapes, because the deb822 one is not hypothetical: the arm64 build
# host's own /etc/apt/sources.list is 0 bytes for exactly this reason, so
# `--rootfs /` there hits this path every time.
# ---------------------------------------------------------------------------
for mode in empty-sources deb822; do
    make_fixture "${WORK}/bad-${mode}" "${mode}"
    OUT_BAD="${WORK}/m-${mode}"
    "${RECORDER}" --rootfs "${WORK}/bad-${mode}" --out "${OUT_BAD}" > "${WORK}/bad-${mode}.log" 2>&1
    RC=$?
    if (( RC != 0 )); then
        if [[ ! -s "${OUT_BAD}" ]]; then
            pass "[unpinned-rootfs:${mode}] refused (rc=${RC}) and wrote no manifest"
        else
            fail "[unpinned-rootfs:${mode}] refused but still wrote a manifest" "$(head -3 "${OUT_BAD}")"
        fi
    else
        fail "[unpinned-rootfs:${mode}] recorder exited 0" "an unpinned rootfs must not become the baseline"
    fi
done

# ---------------------------------------------------------------------------
# [empty-admindir] a readable but EMPTY dpkg database is refused.
#
# dpkg-query --admindir <dir with an empty status file> -W exits 0 with no
# output. Without this check the result is a valid-looking manifest with zero
# packages, and the FIRST build would commit it as the permanent baseline --
# the self-test above would not catch that, because it only compares two
# recordings of a good fixture.
# ---------------------------------------------------------------------------
make_fixture "${WORK}/empty-db" snapshot
: > "${WORK}/empty-db/var/lib/dpkg/status"
"${RECORDER}" --rootfs "${WORK}/empty-db" --out "${WORK}/m-emptydb" > "${WORK}/emptydb.log" 2>&1
RC=$?
if (( RC != 0 )) && [[ ! -s "${WORK}/m-emptydb" ]]; then
    pass "[empty-admindir] zero resolved packages is a hard failure, not an empty baseline"
else
    fail "[empty-admindir] recorder exited ${RC}" "$(head -5 "${WORK}/emptydb.log")"
fi

# ---------------------------------------------------------------------------
# [diff] 0 identical / 1 differing / 2 missing reference.
# ---------------------------------------------------------------------------
"${RECORDER}" --diff "${WORK}/m1" --reference "${WORK}/m2" > /dev/null 2>&1
RC=$?
if (( RC == 0 )); then pass "[diff] identical manifests exit 0"
else fail "[diff] identical manifests" "rc=${RC}, expected 0"; fi

"${RECORDER}" --diff "${WORK}/m1" --reference "${WORK}/no-such-reference" > /dev/null 2>&1
RC=$?
if (( RC == 2 )); then pass "[diff] missing reference exits 2, distinct from 'differs'"
else fail "[diff] missing reference" "rc=${RC}, expected 2"; fi

# A one-version change, which is the realistic drift, not a wholesale rewrite.
sed 's/^pkg\tmount\t2\.38\.1-5+deb12u1\t/pkg\tmount\t2.38.1-6+deb12u2\t/' "${WORK}/m1" > "${WORK}/m3"
if cmp -s "${WORK}/m1" "${WORK}/m3"; then
    fail "[diff] fixture mutation" "sed did not change the manifest; the differing case would be vacuous"
else
    "${RECORDER}" --diff "${WORK}/m3" --reference "${WORK}/m1" > "${WORK}/diff.log" 2>&1
    RC=$?
    if (( RC == 1 )) && grep -q '2.38.1-6+deb12u2' "${WORK}/diff.log"; then
        pass "[diff] a one-version change exits 1 and names the new version"
    else
        fail "[diff] one-version change" "rc=${RC}; log: $(head -12 "${WORK}/diff.log")"
    fi
fi

# ---------------------------------------------------------------------------
# [accept] ARLOWE_INPUTS_ACCEPT=1 prints the diff, then re-records.
# ---------------------------------------------------------------------------
cp "${WORK}/m1" "${WORK}/ref-accept"
ARLOWE_INPUTS_ACCEPT=1 "${RECORDER}" --diff "${WORK}/m3" --reference "${WORK}/ref-accept" > "${WORK}/accept.log" 2>&1
RC=$?
if (( RC == 0 )) && cmp -s "${WORK}/m3" "${WORK}/ref-accept" \
        && grep -q '2.38.1-6+deb12u2' "${WORK}/accept.log"; then
    pass "[accept] ARLOWE_INPUTS_ACCEPT=1 printed the diff before re-recording"
else
    fail "[accept] accept path" "rc=${RC}; log: $(head -12 "${WORK}/accept.log")"
fi

printf '\n%d passed, %d failed\n' "${PASSED}" "${FAILED}"
(( FAILED == 0 ))
