#!/usr/bin/env bash
# scripts/build-image.sh
#
# Full pipeline: verify deps → pi-gen (model-free rootfs + models tree) →
# measure both → repartition(5) → clone A + seed models →
# sanitize + identity-store gates → emit .img.
#
# Supported build host: arm64 Linux only.
# The Mac is NOT supported — pi-gen requires loop devices and privileged mounts
# that Docker Desktop on macOS cannot provide.
#
# Required host packages: parted, losetup, rsync, ripgrep (rg), mkfs.vfat,
#   mkfs.ext4, python3-yaml (for verify-third-party).
#
# Environment knobs (set before running):
#   AXCL_DEB              Path to axcl_host_aarch64_V3.10.2.deb
#   ARLOWE_MODELS_DIR     Directory holding downloaded model artifacts (cache)
#   ARLOWE_MODELS_STAGE   Override models staging tree output dir
#   CARD_SIZE_GB          Target card size in GB (default: 32; 16 is supported)
#   OUTPUT_IMG            Output .img path (default: build/arlowe.img)
#
# Extension hooks for boot config + recovery stub:
#   If scripts/lib/boot-config.sh exists, it is sourced and its
#   write_boot_config function is called after slot-A rsync, before sanitize.
#   If scripts/lib/recovery-stub.sh exists, it is sourced and its
#   write_recovery_stub function is called after write_boot_config.
#   Both receive the PARTUUID map file as their first argument.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CARD_SIZE_GB="${CARD_SIZE_GB:-32}"
OUTPUT_IMG="${OUTPUT_IMG:-${REPO_ROOT}/build/arlowe.img}"
PI_GEN_DIR="${REPO_ROOT}/pi-gen"

# shellcheck source=scripts/lib/identity-store-check.sh
source "${SCRIPT_DIR}/lib/identity-store-check.sh"

SUBSTRATE_LIB="${SCRIPT_DIR}/lib/verify-unit-execstart.sh"
# shellcheck source=scripts/lib/verify-unit-execstart.sh
source "${SUBSTRATE_LIB}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { printf '%s\n' "$*"; }
ok()   { printf "${GREEN}[OK]${NC}   %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
fail() { printf "${RED}[FAIL]${NC} %s\n" "$*" >&2; }

# ---------------------------------------------------------------------------
# Step 1: verify-third-party — fail the build early if deps missing/mismatched
# ---------------------------------------------------------------------------
log "=== Step 1: verify third-party deps ==="
if ! "${SCRIPT_DIR}/verify-third-party.sh"; then
    fail "Dependency verification failed — aborting build."
    exit 1
fi
ok "Third-party deps verified."

# ---------------------------------------------------------------------------
# Step 2: drive pi-gen to produce the model-free rootfs + models staging tree
# ---------------------------------------------------------------------------
log "=== Step 2: pi-gen build ==="

# Provision upstream pi-gen at a pinned bookworm tag. Only the arlowe overlay
# (config, stage-arlowe) is tracked in git; upstream is fetched here. The pin is
# load-bearing: pi-gen master targets trixie, whose debian.sources names the
# keyring .pgp (bookworm ships .gpg) and whose stage2 pulls trixie-only rpi-*
# packages -- both break a RELEASE=bookworm build (F6).
PIGEN_REF="2026-06-18-raspios-bookworm-arm64"
PIGEN_MARKER="${PI_GEN_DIR}/.arlowe-pigen-ref"

if [[ -f "${PIGEN_MARKER}" && "$(cat "${PIGEN_MARKER}")" == "${PIGEN_REF}" ]]; then
    ok "pi-gen pinned at ${PIGEN_REF}"
else
    if [[ -f "${PI_GEN_DIR}/build.sh" ]]; then
        log "pi-gen present but not at the pinned ref — re-provisioning"
    fi
    log "Cloning pi-gen at ${PIGEN_REF}..."
    PIGEN_TMP="$(mktemp -d)"
    trap 'rm -rf "${PIGEN_TMP}"' EXIT
    git clone --quiet --branch "${PIGEN_REF}" --depth 1 \
        https://github.com/RPi-Distro/pi-gen.git "${PIGEN_TMP}/pi-gen"
    rm -rf "${PIGEN_TMP}/pi-gen/.git"
    # Carry the arlowe overlay across so the fresh checkout keeps our stage.
    rm -rf "${PIGEN_TMP}/pi-gen/config" "${PIGEN_TMP}/pi-gen/stage-arlowe"
    cp -a "${PI_GEN_DIR}/config" "${PIGEN_TMP}/pi-gen/config"
    cp -a "${PI_GEN_DIR}/stage-arlowe" "${PIGEN_TMP}/pi-gen/stage-arlowe"
    sudo rm -rf "${PI_GEN_DIR}"
    mv "${PIGEN_TMP}/pi-gen" "${PI_GEN_DIR}"
    printf '%s\n' "${PIGEN_REF}" > "${PIGEN_MARKER}"
    trap - EXIT
    rm -rf "${PIGEN_TMP}"
    ok "pi-gen provisioned at ${PIGEN_REF}"
fi

# pi-gen sets WORK_DIR; default to a canonical build-local path so the
# models marker file (written by stage-arlowe/02-models/00-run.sh) is
# locatable even outside pi-gen's environment.
export WORK_DIR="${WORK_DIR:-${REPO_ROOT}/build/pi-gen-work}"
mkdir -p "${WORK_DIR}"

# Forward env knobs into pi-gen's environment.
export AXCL_DEB="${AXCL_DEB:-}"
export ARLOWE_MODELS_CACHE="${ARLOWE_MODELS_DIR:-${WORK_DIR}/arlowe-models-cache}"
export ARLOWE_MODELS_STAGE="${ARLOWE_MODELS_STAGE:-${WORK_DIR}/arlowe-models-stage}"

log "pi-gen work dir: ${WORK_DIR}"
log "models cache:    ${ARLOWE_MODELS_CACHE}"
log "models stage:    ${ARLOWE_MODELS_STAGE}"

# Native pi-gen build on an arm64 Linux host.
# The config file in pi-gen/ sets STAGE_LIST="stage0 stage1 stage2 stage-arlowe".
# Use SKIP_IMAGES=1 here: we do our own 5-partition image assembly below; we only
# need the rootfs work directory, not pi-gen's 2-partition .img output.
(
    cd "${PI_GEN_DIR}"
    sudo SKIP_IMAGES=1 \
        WORK_DIR="${WORK_DIR}" \
        AXCL_DEB="${AXCL_DEB}" \
        ARLOWE_MODELS_CACHE="${ARLOWE_MODELS_CACHE}" \
        ARLOWE_MODELS_STAGE="${ARLOWE_MODELS_STAGE}" \
        ./build.sh
)

ok "pi-gen build complete."

# Locate the model-free rootfs work directory.
# pi-gen names its per-stage rootfs directories: WORK_DIR/<STAGE_NAME>/rootfs
PIGEN_ROOTFS="${WORK_DIR}/stage-arlowe/rootfs"
if [[ ! -d "${PIGEN_ROOTFS}" ]]; then
    # Fallback: pi-gen sometimes names it differently across versions.
    PIGEN_ROOTFS="$(find "${WORK_DIR}" -maxdepth 3 -name rootfs -type d | grep stage-arlowe | head -1 || true)"
fi
if [[ ! -d "${PIGEN_ROOTFS}" ]]; then
    fail "Cannot locate stage-arlowe rootfs under ${WORK_DIR}"
    exit 1
fi
ok "Model-free rootfs at: ${PIGEN_ROOTFS}"

# Assert the packages stage-arlowe declares actually landed in the rootfs.
# An unread package list is invisible at build time: pi-gen reads NN-packages-nr
# only from inside a sub-stage directory, so a misplaced list builds a clean
# image that fails at first boot instead (F7 #16/#18 — growpart, node, rpi.gpio
# were absent from every image ever built).
PACKAGE_LIST="${PI_GEN_DIR}/stage-arlowe/00-packages/00-packages-nr"
if [[ ! -f "${PACKAGE_LIST}" ]]; then
    fail "Declared package list not found at ${PACKAGE_LIST}"
    exit 1
fi

mapfile -t DECLARED_PKGS < <(sed 's/#.*//' "${PACKAGE_LIST}" | tr -s '[:space:]' '\n' | grep -v '^$')
MISSING_PKGS=()
for pkg in "${DECLARED_PKGS[@]}"; do
    sudo awk -v p="${pkg}" '
        $1 == "Package:" { cur = ($2 == p) }
        cur && $1 == "Status:" && /install ok installed/ { found = 1 }
        END { exit(found ? 0 : 1) }
    ' "${PIGEN_ROOTFS}/var/lib/dpkg/status" || MISSING_PKGS+=("${pkg}")
done

if (( ${#MISSING_PKGS[@]} > 0 )); then
    fail "Declared packages absent from the built rootfs: ${MISSING_PKGS[*]}"
    fail "stage-arlowe's package list did not install — confirm it sits inside a sub-stage directory."
    exit 1
fi
ok "All ${#DECLARED_PKGS[@]} declared packages present in rootfs."

# ---------------------------------------------------------------------------
# UNIT SUBSTRATE GATES — the inverse of the packages guard directly above.
#
# That guard proves DECLARED packages landed, so by construction it cannot see a
# dependency nobody declared. These two derive their expectations from the
# rootfs's own /etc/systemd/system/*.service glob instead of from any maintained
# list, so they cover exactly the things nobody remembered to declare. Adding an
# eighth unit extends them with no edit here or in the library.
#
#   verify_unit_execstart          every Exec* executable and script argument
#                                  named by a unit resolves inside the rootfs.
#   verify_unit_runtime_versions   the interpreter each unit names meets a
#                                  declared version floor. The path gate cannot
#                                  tell a Node 20 from a Node 18, and the
#                                  dashboard unit names /usr/bin/node, where
#                                  00-packages-nr puts bookworm's 18.20.4:
#                                  existence-only, that unit passes and the
#                                  dashboard still never starts.
#
# Order is load-bearing, not cosmetic: probing a path is only meaningful once it
# resolves. Both run even when the first fails, so one rootfs build reports every
# substrate defect rather than revealing them one per build.
#
# Neither covers module-import resolution — that is `unit-import-bookworm`, plan
# 07.1-05 — nor end-to-end runtime behaviour, which is SC6. See ADR-0008.
#
# PLACEMENT is deliberate: adjacent to the packages guard, after the rootfs is
# fully provisioned and before anything is measured or partitioned. A substrate
# defect therefore costs one rootfs build, not a full partition-and-image cycle.
#
# SUDO for the same reason `du` uses it at step 3: install-arlowe-fs.sh creates
# /opt/arlowe as 0750 root:arlowe, and this user is neither root nor in the
# image's arlowe group, so unprivileged existence tests on the whole tree return
# false. The library detects an unsearchable directory and hard-errors (exit 2)
# rather than reporting the target as missing, so a privilege mistake can never
# masquerade as a substrate defect.
#
# SLOT-B COVERAGE IS A KNOWN GAP. The slot-B recovery rootfs also carries a unit
# (arlowe-recovery.service), but it does not exist yet at this point — it is
# written in step 4b, after partitioning. Running these gates there would also
# be wrong as things stand: recovery-stub.sh clones slot A and prunes
# /opt/arlowe/runtime/{voice,llm,stt,tts,dashboard,wake-word,face,lib} while
# leaving every slot-A unit in /etc/systemd/system, so a CORRECT slot B names
# targets that are deliberately absent and would FAIL. That mismatch is a real
# finding and is recorded in this plan's SUMMARY; it needs the prune to drop the
# units too, which is not this plan's change to make.
# ---------------------------------------------------------------------------

# ARLOWE_VERSION_PROBE replaces the version gate's chroot probe with a stub. It
# exists for tests/phase-07.1/test-verify-unit-execstart.sh and nothing else.
# This ASSERTS rather than `unset`s: unsetting normalises the anomaly into
# silence, whereas an inherited value means someone is either running the
# self-test's plumbing against a real build or trying to make the gate lie, and
# both are events a build should announce. A gate that can be silently disabled
# by an environment variable is not a gate.
# (CI is already covered — build-image.yml's `sudo --preserve-env=...` strips it.
# The residual exposure is a local run on the build host.)
if [[ -n "${ARLOWE_VERSION_PROBE+x}" ]]; then
    fail "ARLOWE_VERSION_PROBE is set in the build environment (value: '${ARLOWE_VERSION_PROBE}')."
    fail "That variable stubs out the interpreter version probe and exists only for"
    fail "tests/phase-07.1/test-verify-unit-execstart.sh. A real build must measure."
    fail "Unset it and re-run; the build will not proceed with a gate that can be faked."
    exit 1
fi

log "Running unit substrate gates over the built rootfs..."
EXECSTART_RC=0
sudo bash -c 'set -uo pipefail; source "$1"; verify_unit_execstart "$2"' \
    _ "${SUBSTRATE_LIB}" "${PIGEN_ROOTFS}" || EXECSTART_RC=$?
VERSIONS_RC=0
sudo bash -c 'set -uo pipefail; source "$1"; verify_unit_runtime_versions "$2"' \
    _ "${SUBSTRATE_LIB}" "${PIGEN_ROOTFS}" || VERSIONS_RC=$?

if (( EXECSTART_RC == 2 || VERSIONS_RC == 2 )); then
    fail "A unit substrate gate could not perform its test (see the ERROR above)."
    fail "That is neither a pass nor a failure — the build stops rather than guess."
    exit 1
fi
if (( EXECSTART_RC != 0 || VERSIONS_RC != 0 )); then
    fail "Unit substrate gates FAILED — the rootfs names runtime artifacts it does not contain,"
    fail "or ships an interpreter below its declared floor. Every failure is listed above."
    exit 1
fi
ok "Unit substrate gates passed: every Exec* target resolves and every interpreter meets its floor."

# Locate the models staging tree (written by 02-models/00-run.sh).
MODELS_STAGE_MARKER="${WORK_DIR}/arlowe-models-stage-path"
if [[ -f "${MODELS_STAGE_MARKER}" ]]; then
    ARLOWE_MODELS_STAGE="$(cat "${MODELS_STAGE_MARKER}")"
fi
if [[ ! -d "${ARLOWE_MODELS_STAGE}" ]]; then
    fail "Models staging tree not found at ${ARLOWE_MODELS_STAGE} (marker: ${MODELS_STAGE_MARKER})"
    exit 1
fi
ok "Models staging tree at: ${ARLOWE_MODELS_STAGE}"

# ---------------------------------------------------------------------------
# Step 3: MEASURE — du rootfs and models staging tree
# ---------------------------------------------------------------------------
log "=== Step 3: measure rootfs + models ==="

# sudo: the pi-gen rootfs has root-owned 0700 dirs (identity/, /root, ssl/private,
# ...) that a non-root du can't read — it would both error out (pipefail) and
# undercount the rootfs, yielding a too-small slot. Measure as root for accuracy.
ROOTFS_BYTES="$(sudo du -sb "${PIGEN_ROOTFS}" | awk '{print $1}')"
MODELS_BYTES="$(sudo du -sb "${ARLOWE_MODELS_STAGE}" | awk '{print $1}')"

log "Measured model-free rootfs: $(( ROOTFS_BYTES / 1024 / 1024 )) MiB (${ROOTFS_BYTES} bytes)"
log "Measured models tree:       $(( MODELS_BYTES / 1024 / 1024 )) MiB (${MODELS_BYTES} bytes)"

# Slot size = rootfs measurement + 25% headroom, but never below the ADR-0004
# reference floor. A percentage-only headroom collapses to near-nothing on a
# small rootfs: the Phase-6 checkpoint measured ~1.6 GiB, so +25% gave a 2 GiB
# slot that booted 97% full (55 MiB free) with no room for apt/updates/tmp.
# ADR-0004's reference is therefore a FLOOR — measured wins only when larger.
# Round up to the nearest 64 MiB boundary for partition alignment.
_ALIGN_BYTES=$(( 64 * 1024 * 1024 ))

# ADR-0004 reference values (floors; measured values win only when larger).
_ADR_SLOT_REF_MIB=3072
_ADR_MODELS_REF_MIB=6144

_SLOT_RAW=$(( ROOTFS_BYTES + ROOTFS_BYTES / 4 ))
_SLOT_FLOOR_BYTES=$(( _ADR_SLOT_REF_MIB * 1024 * 1024 ))
if (( _SLOT_RAW < _SLOT_FLOOR_BYTES )); then
    log "Measured slot (rootfs + 25% = $(( _SLOT_RAW / 1024 / 1024 )) MiB) is under the ADR-0004 ${_ADR_SLOT_REF_MIB} MiB floor; using the floor."
    _SLOT_RAW="${_SLOT_FLOOR_BYTES}"
fi
SLOT_BYTES=$(( (_SLOT_RAW + _ALIGN_BYTES - 1) / _ALIGN_BYTES * _ALIGN_BYTES ))

log "Slot size (rootfs + 25% headroom, ADR-0004 ${_ADR_SLOT_REF_MIB} MiB floor, 64 MiB aligned): $(( SLOT_BYTES / 1024 / 1024 )) MiB"

if (( SLOT_BYTES / 1024 / 1024 > _ADR_SLOT_REF_MIB * 2 )); then
    warn "Measured slot size materially exceeds ADR-0004 ~${_ADR_SLOT_REF_MIB} MiB reference — proceeding with measured value."
fi
if (( MODELS_BYTES / 1024 / 1024 > _ADR_MODELS_REF_MIB * 2 )); then
    warn "Measured models size materially exceeds ADR-0004 ~${_ADR_MODELS_REF_MIB} MiB reference — proceeding with measured value."
fi

ok "Measurements complete; proceeding with measured sizes."

# ---------------------------------------------------------------------------
# Step 4: repartition(5) + clone A + seed models
# ---------------------------------------------------------------------------
log "=== Step 4: 5-partition image assembly ==="

mkdir -p "$(dirname "${OUTPUT_IMG}")"

# Source the partition-image library and call the build function.
PARTITION_LIB="${SCRIPT_DIR}/lib/partition-image.sh"
if [[ ! -f "${PARTITION_LIB}" ]]; then
    fail "Partition library not found at ${PARTITION_LIB}"
    exit 1
fi

# shellcheck source=scripts/lib/partition-image.sh
source "${PARTITION_LIB}"

# build_partition_image populates OUTPUT_PARTUUID_MAP_FILE for later steps.
OUTPUT_PARTUUID_MAP_FILE="${WORK_DIR}/arlowe-partuuid-map"

build_partition_image \
    --card-size-gb   "${CARD_SIZE_GB}" \
    --slot-bytes     "${SLOT_BYTES}" \
    --models-bytes   "${MODELS_BYTES}" \
    --rootfs         "${PIGEN_ROOTFS}" \
    --models-stage   "${ARLOWE_MODELS_STAGE}" \
    --output-img     "${OUTPUT_IMG}" \
    --partuuid-map   "${OUTPUT_PARTUUID_MAP_FILE}"

ok "5-partition image assembled."

# ---------------------------------------------------------------------------
# Extension hooks: boot config + recovery stub (sourced when present)
# ---------------------------------------------------------------------------
log "=== Step 4b: boot-config + recovery-stub extension hooks (if present) ==="

BOOT_CONFIG_LIB="${SCRIPT_DIR}/lib/boot-config.sh"
RECOVERY_STUB_LIB="${SCRIPT_DIR}/lib/recovery-stub.sh"

if [[ -f "${BOOT_CONFIG_LIB}" ]]; then
    log "Sourcing boot-config.sh"
    # shellcheck source=/dev/null
    source "${BOOT_CONFIG_LIB}"
    write_boot_config "${OUTPUT_PARTUUID_MAP_FILE}" "${OUTPUT_IMG}"
    ok "boot-config written."
else
    log "(scripts/lib/boot-config.sh absent — skipping)"
fi

if [[ -f "${RECOVERY_STUB_LIB}" ]]; then
    log "Sourcing recovery-stub.sh"
    # shellcheck source=/dev/null
    source "${RECOVERY_STUB_LIB}"
    write_recovery_stub "${OUTPUT_PARTUUID_MAP_FILE}" "${OUTPUT_IMG}"
    ok "recovery stub written."
else
    log "(scripts/lib/recovery-stub.sh absent — skipping)"
fi

# ---------------------------------------------------------------------------
# Step 5: IMAGE GATES — two checks over the assembled slot-A rootfs:
#   a) sanitize scan-dir (SANIT-08)
#   b) identity-store scan in --factory mode (SC3 / IDENT-03)
# Both run inside this one read-only loop-mount. A second mount is not an
# option: a read-write loop-mount rewrites the ext4 superblock after the .bmap
# is generated, and bmaptool flash then aborts on a checksum mismatch.
# ---------------------------------------------------------------------------
log "=== Step 5: image gates (sanitize + identity store) ==="

SANITIZE_SCRIPT="${SCRIPT_DIR}/sanitize/check.sh"
if [[ ! -f "${SANITIZE_SCRIPT}" ]]; then
    fail "Sanitize script not found at ${SANITIZE_SCRIPT}"
    exit 1
fi

# Require ripgrep on the build host (check.sh exits 2 if rg is absent).
if ! command -v rg >/dev/null 2>&1; then
    fail "ripgrep (rg) is required for the sanitize gate but was not found."
    fail "Install it on the build host: apt-get install ripgrep"
    exit 1
fi

SLOT_A_MOUNTPOINT="$(mktemp -d)"
# Loop-mount the image and find the slot-A partition device.
LOOP_DEV="$(sudo losetup -f --show -P "${OUTPUT_IMG}")"
log "Mounted image as loop device: ${LOOP_DEV}"

cleanup_loop() {
    sudo umount "${SLOT_A_MOUNTPOINT}" 2>/dev/null || true
    sudo losetup -d "${LOOP_DEV}" 2>/dev/null || true
    rmdir "${SLOT_A_MOUNTPOINT}" 2>/dev/null || true
}
trap cleanup_loop EXIT

# Slot A is partition 2 (p2 in the 5-partition layout).
SLOT_A_PART="${LOOP_DEV}p2"
sudo mount -o ro "${SLOT_A_PART}" "${SLOT_A_MOUNTPOINT}"
log "Slot A mounted read-only at ${SLOT_A_MOUNTPOINT}"

log "Running sanitize check.sh --scan-dir on slot-A rootfs..."
# Models partition holds only model binaries; scanning slot A is sufficient per plan.
# check.sh --scan-dir runs both the banned-literal grep gate and the banned-unit gate.
if ! "${SANITIZE_SCRIPT}" --scan-dir "${SLOT_A_MOUNTPOINT}"; then
    fail "Sanitize gate FAILED — aborting. Fix banned literals or unit names in the image."
    cleanup_loop
    trap - EXIT
    exit 1
fi

ok "Sanitize gate passed."

log "Running identity-store gate on slot-A rootfs..."
# install-arlowe-fs.sh creates /var/lib/arlowe/identity at 0700 inside the
# pi-gen chroot, so this scans a real, present, empty directory. The owner_state
# partition is mounted over that path only at runtime.
if ! check_identity_store "${SLOT_A_MOUNTPOINT}" --factory; then
    fail "Identity-store gate FAILED — aborting. Key material must never ship in the image."
    cleanup_loop
    trap - EXIT
    exit 1
fi

cleanup_loop
trap - EXIT
ok "Identity-store gate passed."

# ---------------------------------------------------------------------------
# Step 6 (placeholder): slot-B recovery write + tryboot config are wired in
# via the extension hooks in step 4b, not as a separate numbered step.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Step 7: emit — print final image size + partition table
# ---------------------------------------------------------------------------
log "=== Step 7: final image ==="

log "Output image: ${OUTPUT_IMG}"
log "Image size:   $(du -sh "${OUTPUT_IMG}" | awk '{print $1}')"
log ""
log "Partition table:"
sudo parted -s "${OUTPUT_IMG}" print

# Generate a block map so flash-sd.sh's bmaptool path writes only used blocks.
# The image is sized to the full card but mostly empty (models grow-to-fill on
# first boot), so a plain dd writes the whole card; bmaptool skips the unused
# space and cuts a flash from ~50-77 min to ~10 min on a slow card.
if command -v bmaptool >/dev/null 2>&1; then
    log "Generating block map for fast flashing..."
    bmaptool create -o "${OUTPUT_IMG}.bmap" "${OUTPUT_IMG}"
    ok "Block map written: ${OUTPUT_IMG}.bmap"
else
    warn "bmaptool not installed; skipping .bmap (flash-sd.sh will fall back to a full dd). Install bmap-tools to enable fast flashing."
fi

ok "Build complete: ${OUTPUT_IMG}"
