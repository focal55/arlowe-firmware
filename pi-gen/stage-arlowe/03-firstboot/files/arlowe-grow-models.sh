#!/usr/bin/env bash
# pi-gen/stage-arlowe/03-firstboot/files/arlowe-grow-models.sh
#
# First-boot, run-once, idempotent grow of the shared MODELS partition (p5)
# to consume all remaining space on the SD card.
#
# This script is wired as an ExecStartPre= stanza in arlowe-firstboot.service.
# It runs after local-fs.target, which means the models partition IS already
# mounted read-only at /opt/arlowe/models by the time this script fires.
# The resize must therefore be done offline: unmount, resize, remount.
#
# Target: the MODELS partition only (p5 — the LAST partition, the grow-to-fill
# partition per ADR-0004). A, B, and owner-state are FIXED and must NOT be grown.
#
# Sentinel: /var/lib/arlowe/.models-grow-done
#   If the sentinel exists this script exits 0 immediately (idempotent).
#   The sentinel lives on owner-state (/var/lib/arlowe), which is a separate
#   fixed partition, so the models resize does not affect the sentinel's storage.
#
# Resize sequence:
#   1. Unmount /opt/arlowe/models so the resize is done against an unmounted device.
#   2. growpart extends the partition entry to the disk end (updates the GPT).
#   3. e2fsck checks the filesystem (required before offline resize2fs).
#   4. resize2fs expands the ext4 filesystem to fill the new partition size.
#   5. Remount /opt/arlowe/models so the runtime sees the grown partition.
# Performing the resize against the unmounted device is both correct and safe;
# resize2fs on a mounted read-only partition is not guaranteed to succeed.
set -euo pipefail

SENTINEL="/var/lib/arlowe/.models-grow-done"
MODELS_PARTITION_NUM=5   # p5 in the 5-partition layout

# ---------------------------------------------------------------------------
# Idempotency guard
# ---------------------------------------------------------------------------
if [[ -f "${SENTINEL}" ]]; then
    echo "[grow-models] sentinel found — models partition already grown; skipping"
    exit 0
fi

echo "[grow-models] first-boot: growing models partition to fill the card"

# ---------------------------------------------------------------------------
# Locate the models partition device
# ---------------------------------------------------------------------------
# Determine the root device from the kernel command line (root= parameter).
# On a Raspberry Pi 5, the root device is typically /dev/mmcblk0pN or /dev/nvme0n1pN.
_root_dev=""
for _part in $(grep -oP 'root=\S+' /proc/cmdline 2>/dev/null | sed 's/root=//'); do
    if [[ "${_part}" == /dev/* ]]; then
        _root_dev="${_part}"
        break
    fi
    # Handle PARTUUID= root= form.
    if [[ "${_part}" == PARTUUID=* ]]; then
        _puuid="${_part#PARTUUID=}"
        _root_dev="$(blkid -t PARTUUID="${_puuid}" -o device 2>/dev/null || true)"
        break
    fi
done

if [[ -z "${_root_dev}" ]]; then
    echo "[grow-models] ERROR: cannot determine root device from /proc/cmdline" >&2
    exit 1
fi

# The disk device is the root device without its partition suffix.
# e.g. /dev/mmcblk0p2 → /dev/mmcblk0, or /dev/sda2 → /dev/sda
_disk_dev="${_root_dev%p[0-9]*}"
if [[ "${_disk_dev}" == "${_root_dev}" ]]; then
    # For devices like /dev/sda2 the suffix is a plain digit.
    _disk_dev="${_root_dev%[0-9]}"
fi

_models_part="${_disk_dev}p${MODELS_PARTITION_NUM}"
# For devices without the 'p' separator (e.g. /dev/sda).
if [[ ! -b "${_models_part}" ]]; then
    _models_part="${_disk_dev}${MODELS_PARTITION_NUM}"
fi

if [[ ! -b "${_models_part}" ]]; then
    echo "[grow-models] ERROR: models partition device not found: ${_models_part}" >&2
    echo "[grow-models]   disk device: ${_disk_dev}" >&2
    exit 1
fi

echo "[grow-models] disk device:    ${_disk_dev}"
echo "[grow-models] models partition: ${_models_part} (p${MODELS_PARTITION_NUM})"

# ---------------------------------------------------------------------------
# Safety check: do NOT grow partitions 1-4 (boot, A, B, owner-state are FIXED)
# ---------------------------------------------------------------------------
# Verify that the partition we are about to grow is the LAST partition on the disk.
_last_part_num="$(sudo parted -s "${_disk_dev}" print | awk '/^ +[0-9]/ {n=$1} END{print n}' || true)"
if [[ "${_last_part_num}" != "${MODELS_PARTITION_NUM}" ]]; then
    echo "[grow-models] ERROR: models partition (${MODELS_PARTITION_NUM}) is not the last partition" >&2
    echo "[grow-models]   last partition number detected: ${_last_part_num}" >&2
    echo "[grow-models]   Aborting to avoid corrupting the partition table." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Grow the partition to the end of the disk
# ---------------------------------------------------------------------------
echo "[grow-models] running growpart to extend partition ${MODELS_PARTITION_NUM} to disk end..."
if ! growpart "${_disk_dev}" "${MODELS_PARTITION_NUM}"; then
    _gc=$?
    if [[ "${_gc}" -eq 1 ]]; then
        # growpart exits 1 when the partition is already at the disk end (no-op).
        echo "[grow-models] growpart: partition already at disk end (no-op)"
    else
        echo "[grow-models] ERROR: growpart failed (exit ${_gc})" >&2
        exit "${_gc}"
    fi
fi

# ---------------------------------------------------------------------------
# Unmount the models partition so the resize runs offline
# ---------------------------------------------------------------------------
# local-fs.target mounts the models partition (ro,noatime) before ExecStartPre=
# fires, so we must unmount before resizing to keep e2fsck and resize2fs offline.
MODELS_MOUNTPOINT="/opt/arlowe/models"
if mountpoint -q "${MODELS_MOUNTPOINT}"; then
    echo "[grow-models] unmounting ${MODELS_MOUNTPOINT} for offline resize..."
    umount "${MODELS_MOUNTPOINT}"
fi

# ---------------------------------------------------------------------------
# Expand the ext4 filesystem to fill the grown partition
# ---------------------------------------------------------------------------
echo "[grow-models] running e2fsck + resize2fs to expand models ext4 filesystem..."
# e2fsck is required before offline resize2fs.
# Exit codes 0 (clean) and 1 (errors corrected) are safe to continue.
# Exit codes >= 4 indicate uncorrectable errors — abort rather than resize a
# corrupt filesystem.
e2fsck -pf "${_models_part}" || {
    _e2fsck_exit=$?
    if [[ "${_e2fsck_exit}" -ge 4 ]]; then
        echo "[grow-models] ERROR: e2fsck reported uncorrectable filesystem errors (exit ${_e2fsck_exit})" >&2
        echo "[grow-models]   Not safe to resize. Manual fsck required." >&2
        exit "${_e2fsck_exit}"
    fi
    # Exit codes 2 and 3 mean corrections were made that require a reboot;
    # treat as fatal so the admin sees the journal entry.
    if [[ "${_e2fsck_exit}" -ge 2 ]]; then
        echo "[grow-models] WARNING: e2fsck made corrections requiring reboot (exit ${_e2fsck_exit})" >&2
        echo "[grow-models]   Reboot and let firstboot re-run (sentinel not written)." >&2
        exit "${_e2fsck_exit}"
    fi
}
resize2fs "${_models_part}"
echo "[grow-models] models partition filesystem expanded"

# ---------------------------------------------------------------------------
# Remount the models partition so the runtime sees the grown filesystem
# ---------------------------------------------------------------------------
echo "[grow-models] remounting ${MODELS_MOUNTPOINT} read-only..."
mount "${MODELS_MOUNTPOINT}"
echo "[grow-models] ${MODELS_MOUNTPOINT} remounted"

# ---------------------------------------------------------------------------
# Write sentinel to prevent re-running on subsequent boots
# ---------------------------------------------------------------------------
# /var/lib/arlowe is the owner-state partition (p4, FIXED). It should be
# mounted by the time this script runs (fstab with noatime). If it is not yet
# mounted, fall back to a tmpfs write that will be replayed; however in normal
# operation arlowe-firstboot.service runs After=local-fs.target which ensures
# all fstab mounts are up before it starts.
mkdir -p "$(dirname "${SENTINEL}")"
touch "${SENTINEL}"
echo "[grow-models] sentinel written: ${SENTINEL}"
echo "[grow-models] models partition grow complete"
