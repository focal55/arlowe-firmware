#!/bin/bash
# tests/phase-07.2/resolve-twice.sh
#
# Phase 7.2 SC5 evidence: two independent resolutions from the same commit
# produce byte-identical package version sets.
#
# WHY A DOUBLE RESOLVE AND NOT A DOUBLE BUILD
#
# A full image build is ~30 minutes; two would be an hour to observe one bit.
# The claim under test is that two builds RESOLVE the same package versions, and
# resolution is separable from installation. So this runs apt's resolver twice
# against the pinned snapshot and compares. The recorded input manifest
# (scripts/record-build-inputs.sh) is the durable mechanism that keeps this true
# across real builds; this job is the fast, every-PR proof that the pin holds.
#
# WHY THIS PROBE ASSERTS ITS OWN HEALTH BEFORE IT COMPARES ANYTHING
#
# `apt-get update` exits 0 even when every index fetch failed. A --print-uris run
# against that state resolves nothing, and two empty sorted lists compare
# byte-identical: the job whose entire purpose is to notice drift would report
# IDENTICAL while blind. That is this phase's own failure shape occurring inside
# the job built to detect it, so every assertion below runs BEFORE the
# comparison, never after. An emptiness check performed after a successful
# comparison is decorative.
#
# WHY EVERY INPUT IS READ FROM overlays/pi-gen/ RATHER THAN RESTATED HERE
#
# Restating the sources or the package list would make this job stop testing what
# ships the day someone edits the overlay -- it would keep passing against a copy
# of the world as it was when this file was written. The firmware package list is
# read from the OVERLAY copy specifically: pi-gen/stage0/ is gitignored and does
# not exist in a CI checkout, so the overlay is both the only copy available here
# and the copy that actually ships.
#
# SCOPE OF THE DETERMINISM CLAIM, stated rather than implied.
#
# The two resolutions run against the Debian snapshot ONLY. The Raspberry Pi
# archive is a rolling, unpinned source; the kernel deliberately does not come
# from apt resolution at all (six digest-pinned debs, 07.2-02), so folding a
# rolling source into the determinism comparison would import precisely the drift
# this phase exists to contain. The Pi archive is queried separately, at the end,
# by the madison controls -- which assert facts about it rather than determinism.
#
# Runs inside a debian:bookworm arm64 container. Apt-resolution evidence must
# never come from the trixie build host.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}" || exit 1

RELEASE="bookworm"
MIN_PACKAGES=20

PASSED=0
FAILED=0
pass() { printf '[PASS] %s\n' "$1"; PASSED=$(( PASSED + 1 )); }
fail() { printf '[FAIL] %s -- %s\n' "$1" "${2:-}"; FAILED=$(( FAILED + 1 )); }
die()  { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" == "0" ]] || die "must run as root inside a container (apt writes /etc/apt and /var/lib/apt)"
command -v apt-get >/dev/null || die "apt-get not found; this must run in a debian:bookworm container"

OVERLAY_APT="overlays/pi-gen/stage0/00-configure-apt/files"
FIRMWARE_PKGS="overlays/pi-gen/stage0/02-firmware/01-packages"
ARLOWE_PKGS="pi-gen/stage-arlowe/00-packages/00-packages-nr"
KERNEL_MANIFEST="third_party/kernel/manifest.yml"
for f in "${OVERLAY_APT}/sources.list" "${OVERLAY_APT}/99arlowe-pinned" \
         "${FIRMWARE_PKGS}" "${ARLOWE_PKGS}" "${KERNEL_MANIFEST}"; do
    [[ -f "${f}" ]] || die "required input missing from the checkout: ${f}"
done

# ---------------------------------------------------------------------------
# Step 1: install the shipping apt configuration, copied not restated.
#
# The RELEASE placeholder is substituted exactly as the overlay's own 00-run.sh
# does it, because that is the file under test.
#
# The base image's OWN sources are removed, and that removal is load-bearing
# rather than tidiness: debian:bookworm configures the rolling mirror in a deb822
# file at /etc/apt/sources.list.d/debian.sources, which apt reads IN ADDITION to
# /etc/apt/sources.list. Leaving it would let the resolver satisfy packages from
# the rolling mirror while the snapshot lines sat there looking authoritative --
# measured: with it in place, apt fetched deb.debian.org indexes alongside the
# snapshot ones. build-image.sh gates the built rootfs for exactly this (zero
# off-pin list files); this job holds itself to the same standard.
# ---------------------------------------------------------------------------
rm -f /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list
sed "s/RELEASE/${RELEASE}/g" "${OVERLAY_APT}/sources.list" > /etc/apt/sources.list
cp "${OVERLAY_APT}/99arlowe-pinned" /etc/apt/apt.conf.d/99arlowe-pinned

echo "=== active apt sources ==="
grep -vE '^[[:space:]]*(#|$)' /etc/apt/sources.list

# ---------------------------------------------------------------------------
# Step 2: update, then assert it actually fetched the snapshot.
#
# apt-get update's exit code proves nothing here, so it is not consulted as
# evidence. The evidence is the index files it left behind.
#
# NOTE the Packages(.lz4)? shape. bookworm's apt stores indexes compressed, so
# the files are named ..._Packages.lz4 and a pattern anchored on `_Packages$`
# matches zero files on a perfectly healthy run -- an assertion that can never
# pass, which fails the job forever and teaches whoever inherits it to delete the
# check. Measured against a real container rather than assumed.
# ---------------------------------------------------------------------------
apt-get update -qq
echo "=== apt index state ==="
find /var/lib/apt/lists -maxdepth 1 -type f -printf '  %f\n' | LC_ALL=C sort

SNAPSHOT_LISTS="$(find /var/lib/apt/lists -maxdepth 1 -type f \
    -regextype posix-extended -regex '.*/snapshot\.debian\.org_.*_Packages(\..*)?' | wc -l)"
ROLLING_LISTS="$(find /var/lib/apt/lists -maxdepth 1 -type f \
    -regextype posix-extended -regex '.*/deb\.debian\.org_.*_Packages(\..*)?' | wc -l)"

if (( SNAPSHOT_LISTS == 0 )); then
    printf '[FAIL] no snapshot.debian.org Packages index was fetched.\n' >&2
    printf '[FAIL] The apt index list is EMPTY of snapshot entries, so nothing can\n' >&2
    printf '[FAIL] resolve from the pin. apt-get update exits 0 when every fetch\n' >&2
    printf '[FAIL] fails, which is why its status is not the evidence here.\n' >&2
    printf '[FAIL] Most likely cause: the sources use https:// and this image ships\n' >&2
    printf '[FAIL] no ca-certificates, so every fetch failed TLS verification.\n' >&2
    exit 1
fi
pass "[index] ${SNAPSHOT_LISTS} snapshot.debian.org Packages index file(s) fetched"

if (( ROLLING_LISTS > 0 )); then
    fail "[index] ${ROLLING_LISTS} rolling-mirror index file(s) present" \
         "the resolution below would not be measuring the pin"
else
    pass "[index] 0 off-pin index files -- the resolution can only use the snapshot"
fi

# ---------------------------------------------------------------------------
# Step 3: the package set, read from the two shipping lists.
# ---------------------------------------------------------------------------
PACKAGES="$( { sed 's/#.*//' "${ARLOWE_PKGS}"
               sed 's/#.*//' "${FIRMWARE_PKGS}"
               echo initramfs-tools
             } | tr -s '[:space:]' '\n' | grep -v '^$' | LC_ALL=C sort -u )"
PACKAGE_COUNT="$(printf '%s\n' "${PACKAGES}" | wc -l)"
echo "=== resolving ${PACKAGE_COUNT} declared packages ==="
printf '%s\n' "${PACKAGES}" | tr '\n' ' '; echo

# --print-uris output is: 'URI' FILENAME SIZE HASH
# Take field 2. Parsing the URI instead would have to cope with apt's percent
# encoding (libstdc++-12-dev arrives as libstdc%2b%2b-12-dev), and a regex that
# chokes on it silently truncates names rather than failing.
resolve_once() {
    local out="$1"
    # shellcheck disable=SC2086
    apt-get install --print-uris -y --no-install-recommends ${PACKAGES} > "${out}.raw" 2>"${out}.err"
    local rc=$?
    if (( rc != 0 )); then
        printf '[FAIL] apt-get install --print-uris exited %d:\n' "${rc}" >&2
        tail -20 "${out}.err" >&2
        return "${rc}"
    fi
    # `|| true` on the grep so that "apt succeeded but resolved nothing" reaches
    # the floor check below with its specific message, instead of being reported
    # here as a resolver failure. Under `set -o pipefail` the bare grep would
    # fail the pipeline on zero matches and conflate the two.
    { grep "^'" "${out}.raw" || true; } | awk '{print $2}' | LC_ALL=C sort -u > "${out}"
}

# Each status captured explicitly and immediately. `resolve_once ... || die` would
# leave $? holding the status of the whole compound -- always 0 whenever die did
# not fire -- so the assertion below would pass by construction and measure
# nothing. Running them inside a pipeline would swallow the status the same way.
resolve_once /tmp/resolve-a
RC_A=$?
# A deliberate pause so two runs cannot share a same-second cache state and
# manufacture a false pass.
sleep 3
resolve_once /tmp/resolve-b
RC_B=$?

if (( RC_A != 0 || RC_B != 0 )); then
    printf '[FAIL] a resolution exited non-zero (rc=%d,%d); nothing below would be meaningful.\n' \
        "${RC_A}" "${RC_B}" >&2
    exit 1
fi
pass "[resolve] both resolutions exited 0"

# ---------------------------------------------------------------------------
# Step 4: floor FIRST, then compare. The order is the whole point.
# ---------------------------------------------------------------------------
N_A="$(wc -l < /tmp/resolve-a)"
N_B="$(wc -l < /tmp/resolve-b)"

if (( N_A >= MIN_PACKAGES && N_B >= MIN_PACKAGES )); then
    pass "[floor] resolved ${N_A} and ${N_B} packages (>= ${MIN_PACKAGES}) -- the probe measured something"
else
    printf '[FAIL] resolved %s and %s packages, below the floor of %s.\n' \
        "${N_A}" "${N_B}" "${MIN_PACKAGES}" >&2
    printf '[FAIL] Two empty or near-empty sets compare identical, so the comparison\n' >&2
    printf '[FAIL] below would report success while proving nothing. Refusing to run it.\n' >&2
    exit 1
fi

if cmp -s /tmp/resolve-a /tmp/resolve-b; then
    pass "[determinism] two resolutions 3s apart produced byte-identical sets (${N_A} packages)"
else
    fail "[determinism] the two resolutions disagree" "$(diff -u /tmp/resolve-a /tmp/resolve-b | head -20)"
fi

# ---------------------------------------------------------------------------
# Step 5: positive controls for the Pi-side pinning mechanism.
#
# The premise these rest on was previously stated backwards and must not be
# reintroduced: the Pi index DOES carry the versioned kernel, so "the index
# cannot supply it" is false and a control built on that would pass forever
# regardless of anything real. The two things that CAN change are asserted
# instead.
#
# Both package names are derived from third_party/kernel/manifest.yml rather
# than written here. A second copy of a pinned version string is how a pin
# half-applies.
#
# [trusted=yes] and no archive key: nothing is installed from this source, the
# checks only read advertised versions. Fetching the key would mean installing
# curl and gnupg first, and both -- along with ca-certificates -- are in the
# package list resolved above, so installing them would change the very set this
# job measures. Added AFTER the resolutions for the same reason.
# ---------------------------------------------------------------------------
MODULE_DIR="$(sed -n 's/^[[:space:]]*-[[:space:]]*"\([0-9][^"]*rpi-2712\)"[[:space:]]*$/\1/p' \
    "${KERNEL_MANIFEST}" | head -1)"
[[ -n "${MODULE_DIR}" ]] || die "cannot derive the pinned module directory from ${KERNEL_MANIFEST}"
KVER="${MODULE_DIR%%+*}"
FLAVOUR="${MODULE_DIR##*+rpt-}"
PINNED_PKG="linux-image-${MODULE_DIR}"
META_PKG="linux-image-${FLAVOUR}"

echo "=== Pi archive controls (pinned ${KVER}, flavour ${FLAVOUR}) ==="
echo "deb [trusted=yes] http://archive.raspberrypi.com/debian ${RELEASE} main" \
    > /etc/apt/sources.list.d/raspi.list
apt-get update -qq

PINNED_MADISON="$(apt-cache madison "${PINNED_PKG}" 2>/dev/null)"
if [[ -n "${PINNED_MADISON}" ]]; then
    pass "[retention] ${PINNED_PKG} is still carried by the Pi index"
else
    fail "[retention] ${PINNED_PKG} has fallen out of the Pi index/pool" \
         "the local cache is now the only source for the pinned kernel; third_party/kernel/INSTALL.md's mirroring advice has become mandatory rather than advisory"
fi

META_VERSIONS="$(apt-cache madison "${META_PKG}" 2>/dev/null \
    | awk -F'|' '{gsub(/[[:space:]]/,"",$2); print $2}' | LC_ALL=C sort -u)"
META_COUNT="$(printf '%s\n' "${META_VERSIONS}" | grep -c . || true)"

if (( META_COUNT == 1 )); then
    pass "[meta-unpinnable] ${META_PKG} advertises exactly one version (${META_VERSIONS})"
else
    fail "[meta-unpinnable] ${META_PKG} advertises ${META_COUNT} versions" \
         "the removal-not-pinning decision in ADR-0009 rested on there being exactly one: ${META_VERSIONS}"
fi

# Guarded on META_COUNT: with no versions at all, "does not contain ${KVER}" is
# true for an empty string and this would pass while measuring nothing -- the
# same vacuous-green shape the floor checks above exist to prevent.
if (( META_COUNT == 0 )); then
    fail "[meta-drift] ${META_PKG} advertises no version at all" \
         "cannot assess drift against ${KVER}; treating an empty result as 'not drifted' would be a green light from no measurement"
elif printf '%s\n' "${META_VERSIONS}" | grep -q "${KVER}"; then
    fail "[meta-drift] ${META_PKG} now resolves to the pinned ${KVER}" \
         "the drift that caused this phase has reversed; removing the meta packages is no longer load-bearing and someone should decide that deliberately rather than assume the pin is still doing the work"
else
    pass "[meta-drift] ${META_PKG} resolves to ${META_VERSIONS}, not ${KVER} -- removing the metas is still load-bearing"
fi

printf '\n%d passed, %d failed\n' "${PASSED}" "${FAILED}"
(( FAILED == 0 ))
