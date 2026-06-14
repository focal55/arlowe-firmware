#!/usr/bin/env bash
# scripts/build-image.sh
#
# Full pipeline: verify deps → pi-gen (model-free rootfs + models tree) →
# measure both → repartition(5) → clone A + seed models → sanitize gate →
# emit .img.
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

if [[ ! -d "${PI_GEN_DIR}" ]]; then
    fail "pi-gen directory not found at ${PI_GEN_DIR}"
    exit 1
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

ROOTFS_BYTES="$(du -sb "${PIGEN_ROOTFS}" | awk '{print $1}')"
MODELS_BYTES="$(du -sb "${ARLOWE_MODELS_STAGE}" | awk '{print $1}')"

log "Measured model-free rootfs: $(( ROOTFS_BYTES / 1024 / 1024 )) MiB (${ROOTFS_BYTES} bytes)"
log "Measured models tree:       $(( MODELS_BYTES / 1024 / 1024 )) MiB (${MODELS_BYTES} bytes)"

# Apply 25% headroom to the rootfs measurement for the slot size.
# Round up to the nearest 64 MiB boundary for partition alignment.
_ALIGN_BYTES=$(( 64 * 1024 * 1024 ))
_SLOT_RAW=$(( ROOTFS_BYTES + ROOTFS_BYTES / 4 ))
SLOT_BYTES=$(( (_SLOT_RAW + _ALIGN_BYTES - 1) / _ALIGN_BYTES * _ALIGN_BYTES ))

log "Slot size (rootfs + 25% headroom, 64 MiB aligned): $(( SLOT_BYTES / 1024 / 1024 )) MiB"

# ADR-0004 reference values (starting points; measured values win).
_ADR_SLOT_REF_MIB=3072
_ADR_MODELS_REF_MIB=6144

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
# Step 5: SANITIZE GATE — scan-dir over the assembled slot-A rootfs (SANIT-08)
# ---------------------------------------------------------------------------
log "=== Step 5: sanitize gate ==="

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

cleanup_loop
trap - EXIT
ok "Sanitize gate passed."

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

ok "Build complete: ${OUTPUT_IMG}"
