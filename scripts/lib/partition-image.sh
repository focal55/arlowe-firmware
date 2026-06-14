#!/usr/bin/env bash
# scripts/lib/partition-image.sh
#
# 5-partition build-blank-then-rsync image layout library for the shared-model
# A/B layout (ADR-0004).
#
# Partition order and numbers (models partition LAST for grow-to-fill):
#   p1  /boot             FAT32   512 MiB  firmware + both slots' kernels + tryboot
#   p2  system A          ext4    =slot    model-free rootfs (active)
#   p3  system B          ext4    =slot    equal to A (recovery stub in v1)
#   p4  /var/lib/arlowe   ext4    fixed    owner state, noatime mount option in fstab
#   p5  models            ext4    seed     grows-to-fill on first boot; ro at runtime
#
# Models is p5 (LAST) so growpart/resize2fs can extend it to the disk end without
# relocating any subsequent partition. The FIXED owner-state (p4) sits before it.
# This ordering means the grow-to-fill target is the final partition on the disk,
# which is the cleanest layout for growpart.
#
# Requires: root privileges, losetup, parted, mkfs.vfat, mkfs.ext4, rsync.
# This library is sourced by scripts/build-image.sh; it is NOT executable standalone.
# The Mac is NOT a supported build host (loop devices unavailable via Docker Desktop).
#
# Exports (after build_partition_image returns):
#   A file at --partuuid-map containing:
#     PARTUUID_BOOT=<uuid>
#     PARTUUID_A=<uuid>
#     PARTUUID_B=<uuid>
#     PARTUUID_OWNER=<uuid>
#     PARTUUID_MODELS=<uuid>
#   These are consumed by the boot-config + recovery-stub extension hooks and by
#   build-image.sh's sanitize loop-mount step.

# Guard against direct execution.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "partition-image.sh is a library; source it from build-image.sh." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
_PIMG_BOOT_MIB=512
_PIMG_OWNER_STATE_GIB=3     # FIXED owner-state size in GiB (ADR-0004: ~2-4 GB)

# ---------------------------------------------------------------------------
# build_partition_image
#
# Usage: build_partition_image \
#   --card-size-gb  <N>    \
#   --slot-bytes    <N>    \
#   --models-bytes  <N>    \
#   --rootfs        <path> \
#   --models-stage  <path> \
#   --output-img    <path> \
#   --partuuid-map  <path>
# ---------------------------------------------------------------------------
build_partition_image() {
    local card_size_gb slot_bytes models_bytes rootfs models_stage output_img partuuid_map

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --card-size-gb)  card_size_gb="$2";  shift 2 ;;
            --slot-bytes)    slot_bytes="$2";    shift 2 ;;
            --models-bytes)  models_bytes="$2";  shift 2 ;;
            --rootfs)        rootfs="$2";        shift 2 ;;
            --models-stage)  models_stage="$2";  shift 2 ;;
            --output-img)    output_img="$2";    shift 2 ;;
            --partuuid-map)  partuuid_map="$2";  shift 2 ;;
            *) echo "partition-image.sh: unknown argument: $1" >&2; return 1 ;;
        esac
    done

    _pimg_validate_args "${card_size_gb}" "${slot_bytes}" "${models_bytes}" \
                        "${rootfs}" "${models_stage}" "${output_img}" "${partuuid_map}"

    _pimg_compute_layout "${card_size_gb}" "${slot_bytes}" "${models_bytes}"

    _pimg_create_image   "${output_img}"
    _pimg_partition       "${output_img}"

    local loop_dev
    loop_dev="$(sudo losetup -f --show -P "${output_img}")"

    local cleanup_done=false
    _pimg_cleanup() {
        if [[ "${cleanup_done}" == "false" ]]; then
            cleanup_done=true
            _pimg_unmount_all "${loop_dev}" 2>/dev/null || true
            sudo losetup -d "${loop_dev}" 2>/dev/null || true
        fi
    }
    trap _pimg_cleanup RETURN ERR

    _pimg_mkfs           "${loop_dev}"
    _pimg_rsync_rootfs   "${loop_dev}" "${rootfs}"
    _pimg_seed_models    "${loop_dev}" "${models_stage}"
    _pimg_write_fstab    "${loop_dev}" "${partuuid_map}"
    _pimg_export_partuuids "${loop_dev}" "${partuuid_map}"

    _pimg_cleanup
    trap - RETURN ERR
}

# ---------------------------------------------------------------------------
# Internal: _pimg_validate_args
# ---------------------------------------------------------------------------
_pimg_validate_args() {
    local card_size_gb="$1" slot_bytes="$2" models_bytes="$3"
    local rootfs="$4" models_stage="$5" output_img="$6" partuuid_map="$7"

    [[ -n "${card_size_gb}" ]]  || { echo "partition-image.sh: --card-size-gb is required" >&2; return 1; }
    [[ -n "${slot_bytes}" ]]    || { echo "partition-image.sh: --slot-bytes is required" >&2; return 1; }
    [[ -n "${models_bytes}" ]]  || { echo "partition-image.sh: --models-bytes is required" >&2; return 1; }
    [[ -d "${rootfs}" ]]        || { echo "partition-image.sh: rootfs not found: ${rootfs}" >&2; return 1; }
    [[ -d "${models_stage}" ]]  || { echo "partition-image.sh: models-stage not found: ${models_stage}" >&2; return 1; }
    [[ -n "${output_img}" ]]    || { echo "partition-image.sh: --output-img is required" >&2; return 1; }
    [[ -n "${partuuid_map}" ]]  || { echo "partition-image.sh: --partuuid-map is required" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Internal: _pimg_compute_layout
# Sets module-level variables used by the downstream steps.
# ---------------------------------------------------------------------------
# Declare layout variables at module scope.
_PIMG_CARD_BYTES=0
_PIMG_BOOT_BYTES=0
_PIMG_SLOT_BYTES=0
_PIMG_OWNER_BYTES=0
_PIMG_MODELS_INITIAL_BYTES=0

_pimg_compute_layout() {
    local card_size_gb="$1"
    local slot_bytes="$2"
    local models_bytes="$3"

    _PIMG_CARD_BYTES=$(( card_size_gb * 1024 * 1024 * 1024 ))
    _PIMG_BOOT_BYTES=$(( _PIMG_BOOT_MIB * 1024 * 1024 ))
    _PIMG_SLOT_BYTES="${slot_bytes}"
    _PIMG_OWNER_BYTES=$(( _PIMG_OWNER_STATE_GIB * 1024 * 1024 * 1024 ))

    # Initial models partition size = seed bytes + 25% headroom, aligned to 64 MiB.
    local _align=$(( 64 * 1024 * 1024 ))
    local _models_raw
    _models_raw=$(( models_bytes + models_bytes / 4 ))
    _PIMG_MODELS_INITIAL_BYTES=$(( (_models_raw + _align - 1) / _align * _align ))

    local _total_fixed
    _total_fixed=$(( _PIMG_BOOT_BYTES + 2 * _PIMG_SLOT_BYTES + _PIMG_OWNER_BYTES + _PIMG_MODELS_INITIAL_BYTES ))

    if (( _total_fixed > _PIMG_CARD_BYTES )); then
        echo "partition-image.sh: layout does not fit ${card_size_gb} GB card" >&2
        echo "  boot:   $(( _PIMG_BOOT_BYTES  / 1024 / 1024 )) MiB" >&2
        echo "  slot A: $(( _PIMG_SLOT_BYTES  / 1024 / 1024 )) MiB" >&2
        echo "  slot B: $(( _PIMG_SLOT_BYTES  / 1024 / 1024 )) MiB" >&2
        echo "  owner:  $(( _PIMG_OWNER_BYTES / 1024 / 1024 )) MiB" >&2
        echo "  models: $(( _PIMG_MODELS_INITIAL_BYTES / 1024 / 1024 )) MiB" >&2
        echo "  total:  $(( _total_fixed / 1024 / 1024 )) MiB vs $(( _PIMG_CARD_BYTES / 1024 / 1024 )) MiB" >&2
        return 1
    fi

    echo "[partition-image] Layout (${card_size_gb} GB card):"
    echo "  p1 /boot:           $(( _PIMG_BOOT_BYTES  / 1024 / 1024 )) MiB"
    echo "  p2 system A:        $(( _PIMG_SLOT_BYTES  / 1024 / 1024 )) MiB"
    echo "  p3 system B:        $(( _PIMG_SLOT_BYTES  / 1024 / 1024 )) MiB  (equal to A)"
    echo "  p4 /var/lib/arlowe: $(( _PIMG_OWNER_BYTES / 1024 / 1024 )) MiB  (FIXED)"
    echo "  p5 models:          $(( _PIMG_MODELS_INITIAL_BYTES / 1024 / 1024 )) MiB  (grows-to-fill on first boot)"
}

# ---------------------------------------------------------------------------
# Internal: _pimg_create_image — blank sparse .img
# ---------------------------------------------------------------------------
_pimg_create_image() {
    local output_img="$1"
    mkdir -p "$(dirname "${output_img}")"
    # Sparse file — only the written sectors consume disk space during build.
    truncate -s "${_PIMG_CARD_BYTES}" "${output_img}"
    echo "[partition-image] blank image created: ${output_img} ($(( _PIMG_CARD_BYTES / 1024 / 1024 / 1024 )) GB sparse)"
}

# ---------------------------------------------------------------------------
# Internal: _pimg_partition — write GPT + 5 partitions
# ---------------------------------------------------------------------------
_pimg_partition() {
    local output_img="$1"

    # Convert bytes to MiB for parted.
    local boot_end_mib
    boot_end_mib=$(( _PIMG_BOOT_BYTES / 1024 / 1024 ))
    local slot_mib
    slot_mib=$(( _PIMG_SLOT_BYTES / 1024 / 1024 ))
    local owner_mib
    owner_mib=$(( _PIMG_OWNER_BYTES / 1024 / 1024 ))

    local p1_start=1
    local p1_end=$(( p1_start + boot_end_mib ))
    local p2_start="${p1_end}"
    local p2_end=$(( p2_start + slot_mib ))
    local p3_start="${p2_end}"
    local p3_end=$(( p3_start + slot_mib ))
    local p4_start="${p3_end}"
    local p4_end=$(( p4_start + owner_mib ))
    local p5_start="${p4_end}"
    # Models partition (p5) extends to the card end (grows-to-fill).
    local p5_end="100%"

    sudo parted -s "${output_img}" \
        mklabel gpt \
        mkpart boot    fat32  "${p1_start}MiB" "${p1_end}MiB" \
        set 1 boot on \
        mkpart system_a ext4  "${p2_start}MiB" "${p2_end}MiB" \
        mkpart system_b ext4  "${p3_start}MiB" "${p3_end}MiB" \
        mkpart owner_state ext4 "${p4_start}MiB" "${p4_end}MiB" \
        mkpart models   ext4  "${p5_start}MiB" "${p5_end}"

    echo "[partition-image] GPT partition table written (5 partitions)"
}

# ---------------------------------------------------------------------------
# Internal: _pimg_mkfs — format all five partitions
# ---------------------------------------------------------------------------
_pimg_mkfs() {
    local loop_dev="$1"

    echo "[partition-image] formatting partitions..."
    sudo mkfs.vfat -F 32 -n "boot" "${loop_dev}p1"
    sudo mkfs.ext4 -L "system_a" -F "${loop_dev}p2"
    sudo mkfs.ext4 -L "system_b" -F "${loop_dev}p3"
    # noatime is a mount option in fstab, not an mkfs flag.
    sudo mkfs.ext4 -L "owner_state" -F "${loop_dev}p4"
    sudo mkfs.ext4 -L "models" -F "${loop_dev}p5"
    echo "[partition-image] all five partitions formatted"
}

# ---------------------------------------------------------------------------
# Internal: _pimg_rsync_rootfs — rsync model-free rootfs into slot A (p2)
# ---------------------------------------------------------------------------
_pimg_rsync_rootfs() {
    local loop_dev="$1"
    local rootfs="$2"

    local mnt_a
    mnt_a="$(mktemp -d)"
    sudo mount "${loop_dev}p2" "${mnt_a}"

    echo "[partition-image] rsyncing model-free rootfs into slot A..."
    sudo rsync -aHAX --delete "${rootfs}/" "${mnt_a}/"

    local mnt_boot
    mnt_boot="$(mktemp -d)"
    sudo mount "${loop_dev}p1" "${mnt_boot}"

    # Copy boot files from the rootfs's /boot/firmware tree into the FAT boot partition.
    if [[ -d "${mnt_a}/boot/firmware" ]]; then
        echo "[partition-image] copying boot files into FAT partition..."
        sudo rsync -a "${mnt_a}/boot/firmware/" "${mnt_boot}/"
    elif [[ -d "${mnt_a}/boot" ]]; then
        # pi-gen Bookworm puts firmware files directly in /boot.
        echo "[partition-image] copying /boot contents into FAT partition..."
        sudo rsync -a "${mnt_a}/boot/" "${mnt_boot}/"
    fi

    sudo umount "${mnt_boot}"
    rmdir "${mnt_boot}"
    sudo umount "${mnt_a}"
    rmdir "${mnt_a}"
    echo "[partition-image] slot A populated"
}

# ---------------------------------------------------------------------------
# Internal: _pimg_seed_models — rsync models staging tree into models partition (p5)
# ---------------------------------------------------------------------------
_pimg_seed_models() {
    local loop_dev="$1"
    local models_stage="$2"

    local mnt_models
    mnt_models="$(mktemp -d)"
    sudo mount "${loop_dev}p5" "${mnt_models}"

    echo "[partition-image] seeding models partition from staging tree..."
    sudo rsync -aHAX "${models_stage}/" "${mnt_models}/"
    # The models partition is root-owned + read-only at runtime (ADR-0004).
    sudo chown -R root:root "${mnt_models}"
    sudo chmod 0755 "${mnt_models}"

    sudo umount "${mnt_models}"
    rmdir "${mnt_models}"
    echo "[partition-image] models partition seeded (root-owned)"
}

# ---------------------------------------------------------------------------
# Internal: _pimg_export_partuuids — read all five PARTUUIDs and write the map
# ---------------------------------------------------------------------------
_pimg_export_partuuids() {
    local loop_dev="$1"
    local partuuid_map="$2"

    local puuid_boot puuid_a puuid_b puuid_owner puuid_models
    puuid_boot="$(sudo blkid -s PARTUUID -o value "${loop_dev}p1")"
    puuid_a="$(sudo blkid -s PARTUUID -o value "${loop_dev}p2")"
    puuid_b="$(sudo blkid -s PARTUUID -o value "${loop_dev}p3")"
    puuid_owner="$(sudo blkid -s PARTUUID -o value "${loop_dev}p4")"
    puuid_models="$(sudo blkid -s PARTUUID -o value "${loop_dev}p5")"

    cat > "${partuuid_map}" <<EOF
PARTUUID_BOOT=${puuid_boot}
PARTUUID_A=${puuid_a}
PARTUUID_B=${puuid_b}
PARTUUID_OWNER=${puuid_owner}
PARTUUID_MODELS=${puuid_models}
EOF

    echo "[partition-image] PARTUUIDs exported to ${partuuid_map}:"
    cat "${partuuid_map}"
}

# ---------------------------------------------------------------------------
# Internal: _pimg_write_fstab — substitute real PARTUUID into slot-A fstab
# ---------------------------------------------------------------------------
_pimg_write_fstab() {
    local loop_dev="$1"
    local partuuid_map="$2"

    # Read the PARTUUIDs from blkid directly (map file may not exist yet when
    # this is called; we re-read fresh to keep ordering independent).
    local puuid_boot puuid_owner puuid_models
    puuid_boot="$(sudo blkid -s PARTUUID -o value "${loop_dev}p1")"
    puuid_owner="$(sudo blkid -s PARTUUID -o value "${loop_dev}p4")"
    puuid_models="$(sudo blkid -s PARTUUID -o value "${loop_dev}p5")"

    local mnt_a
    mnt_a="$(mktemp -d)"
    sudo mount "${loop_dev}p2" "${mnt_a}"

    # Replace the PARTUUID placeholder baked into the rootfs during chroot provisioning.
    local placeholder="ARLOWE-MODELS-PARTUUID-REPLACE-BY-06-04"
    if grep -q "${placeholder}" "${mnt_a}/etc/fstab" 2>/dev/null; then
        sudo sed -i "s|PARTUUID=${placeholder}|PARTUUID=${puuid_models}|g" "${mnt_a}/etc/fstab"
        echo "[partition-image] substituted real models PARTUUID in slot-A fstab"
    fi

    # Ensure the FAT boot partition and owner-state partition are in slot-A fstab.
    # Use PARTUUID references, noatime on owner-state.
    local fstab="${mnt_a}/etc/fstab"

    if ! sudo grep -q "PARTUUID=${puuid_boot}" "${fstab}" 2>/dev/null; then
        printf '\nPARTUUID=%s  /boot/firmware  vfat  defaults  0  2\n' "${puuid_boot}" \
            | sudo tee -a "${fstab}" >/dev/null
        echo "[partition-image] added /boot/firmware to slot-A fstab"
    fi

    if ! sudo grep -q "PARTUUID=${puuid_owner}" "${fstab}" 2>/dev/null; then
        printf 'PARTUUID=%s  /var/lib/arlowe  ext4  defaults,noatime  0  2\n' "${puuid_owner}" \
            | sudo tee -a "${fstab}" >/dev/null
        echo "[partition-image] added /var/lib/arlowe (owner-state, noatime) to slot-A fstab"
    fi

    # Models partition ro,noatime (may already be present from the PARTUUID substitution above).
    if ! sudo grep -q "PARTUUID=${puuid_models}" "${fstab}" 2>/dev/null; then
        printf 'PARTUUID=%s  /opt/arlowe/models  ext4  ro,noatime  0  2\n' "${puuid_models}" \
            | sudo tee -a "${fstab}" >/dev/null
        echo "[partition-image] added /opt/arlowe/models (models, ro,noatime) to slot-A fstab"
    fi

    sudo umount "${mnt_a}"
    rmdir "${mnt_a}"
    echo "[partition-image] slot-A fstab written (boot + owner-state noatime + models ro,noatime by PARTUUID)"
}

# ---------------------------------------------------------------------------
# Internal: _pimg_unmount_all — best-effort unmount of any mounts under loop_dev
# ---------------------------------------------------------------------------
_pimg_unmount_all() {
    local loop_dev="$1"
    # Find any mounts from this loop device and unmount them.
    while IFS= read -r mnt; do
        sudo umount "${mnt}" 2>/dev/null || true
    done < <(findmnt -rno TARGET --source "${loop_dev}p1" "${loop_dev}p2" "${loop_dev}p3" "${loop_dev}p4" "${loop_dev}p5" 2>/dev/null || true)
}
