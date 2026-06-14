#!/usr/bin/env bash
# scripts/flash-sd.sh
#
# Write an arlowe .img to a confirmed SD card device.
#
# Runs on macOS or Linux. Building the image requires an arm64 Linux host,
# but flashing can be done from the dev's Mac with the .img downloaded from CI.
#
# Usage:
#   scripts/flash-sd.sh <image.img> <device> [--yes]
#
# Examples (Linux):
#   scripts/flash-sd.sh build/arlowe.img /dev/sdb
#   scripts/flash-sd.sh build/arlowe.img /dev/mmcblk0 --yes
#
# Examples (macOS):
#   scripts/flash-sd.sh build/arlowe.img /dev/disk4 --yes
#
# Safety:
#   - Refuses to write to the system disk (boot device).
#   - Verifies the target is a removable block device on Linux.
#   - Prompts for confirmation unless --yes is passed.
#   - Uses bmaptool if available (fast sparse write), falls back to dd.
#   - Prints flash time on completion.
set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") <image.img> <device> [--yes]

Arguments:
  image.img   Path to the .img file to write
  device      Target block device (e.g. /dev/sdb, /dev/mmcblk0, /dev/disk4)
  --yes       Skip the confirmation prompt

Environment:
  FLASH_BS    Block size passed to dd (default: 4M). Ignored when bmaptool is used.
EOF
}

die() { printf 'flash-sd: %s\n' "$*" >&2; exit 1; }

IMG=""
DEV=""
YES=false
FLASH_BS="${FLASH_BS:-4M}"

for arg in "$@"; do
    case "${arg}" in
        --yes) YES=true ;;
        --help|-h) usage; exit 0 ;;
        -*)  die "unknown flag: ${arg}" ;;
        *)
            if [[ -z "${IMG}" ]]; then
                IMG="${arg}"
            elif [[ -z "${DEV}" ]]; then
                DEV="${arg}"
            else
                die "unexpected argument: ${arg}"
            fi
            ;;
    esac
done

[[ -n "${IMG}" ]] || { usage; exit 1; }
[[ -n "${DEV}" ]] || { usage; exit 1; }
[[ -f "${IMG}" ]] || die "image file not found: ${IMG}"
[[ -b "${DEV}" ]] || die "not a block device: ${DEV}"

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------
OS="$(uname -s)"

# ---------------------------------------------------------------------------
# Safety: refuse the system/boot disk
# ---------------------------------------------------------------------------
get_root_disk_linux() {
    # Find the disk that holds /, using lsblk or /proc/mounts.
    local root_dev
    root_dev="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    if [[ -z "${root_dev}" ]]; then
        root_dev="$(awk '$2 == "/" {print $1; exit}' /proc/mounts)"
    fi
    # Strip partition suffix to get the disk device.
    printf '%s' "${root_dev}" | sed -E 's/(p[0-9]+|[0-9]+)$//'
}

get_root_disk_macos() {
    diskutil info / 2>/dev/null | awk '/Part of Whole:/ {print "/dev/" $NF; exit}'
}

root_disk=""
if [[ "${OS}" == "Darwin" ]]; then
    root_disk="$(get_root_disk_macos)"
elif [[ "${OS}" == "Linux" ]]; then
    root_disk="$(get_root_disk_linux)"
fi

# Normalise to the raw device path for comparison.
dev_resolved="$(realpath "${DEV}" 2>/dev/null || printf '%s' "${DEV}")"
root_resolved="$(realpath "${root_disk}" 2>/dev/null || printf '%s' "${root_disk}")"

if [[ -n "${root_resolved}" && "${dev_resolved}" == "${root_resolved}"* ]]; then
    die "SAFETY: ${DEV} appears to be (or be part of) the system disk ${root_disk}. Refusing."
fi

# ---------------------------------------------------------------------------
# Safety: on Linux, require the device to be removable
# ---------------------------------------------------------------------------
if [[ "${OS}" == "Linux" ]]; then
    # Extract the base device name (strip /dev/ prefix).
    dev_name="${DEV##*/}"
    # For mmcblk0p1, the sysfs removable entry lives under mmcblk0.
    dev_base="${dev_name%%p[0-9]*}"
    dev_base="${dev_base%%[0-9]}"
    sysfs_removable="/sys/block/${dev_base}/removable"
    if [[ -f "${sysfs_removable}" ]]; then
        removable="$(cat "${sysfs_removable}")"
        if [[ "${removable}" != "1" ]]; then
            die "SAFETY: ${DEV} (${dev_base}) is not flagged as removable in sysfs. Use --yes only after confirming this is your SD card."
        fi
    else
        printf 'flash-sd: [WARN] cannot verify removable flag for %s — sysfs path %s not found\n' "${DEV}" "${sysfs_removable}" >&2
    fi
fi

# ---------------------------------------------------------------------------
# Print device info
# ---------------------------------------------------------------------------
IMG_SIZE="$(du -sh "${IMG}" | awk '{print $1}')"

if [[ "${OS}" == "Darwin" ]]; then
    DEV_INFO="$(diskutil info "${DEV}" 2>/dev/null | awk -F: '/Disk Size:/ {print $2}' | xargs || echo "unknown")"
    printf '\nDevice:  %s (%s)\n' "${DEV}" "${DEV_INFO}"
elif [[ "${OS}" == "Linux" ]]; then
    DEV_SIZE_BYTES="$(blockdev --getsize64 "${DEV}" 2>/dev/null || echo 0)"
    if [[ "${DEV_SIZE_BYTES}" -gt 0 ]]; then
        DEV_SIZE_GB=$(( DEV_SIZE_BYTES / 1024 / 1024 / 1024 ))
        printf '\nDevice:  %s (~%d GB)\n' "${DEV}" "${DEV_SIZE_GB}"
    else
        printf '\nDevice:  %s\n' "${DEV}"
    fi
fi

printf 'Image:   %s (%s)\n' "${IMG}" "${IMG_SIZE}"
printf '\n'

# ---------------------------------------------------------------------------
# Confirm
# ---------------------------------------------------------------------------
if ! "${YES}"; then
    printf 'WARNING: This will ERASE all data on %s.\n' "${DEV}"
    printf 'Type "yes" to continue: '
    read -r confirm
    [[ "${confirm}" == "yes" ]] || die "aborted."
fi

# ---------------------------------------------------------------------------
# On macOS, unmount the disk before writing
# ---------------------------------------------------------------------------
if [[ "${OS}" == "Darwin" ]]; then
    printf '\nUnmounting %s...\n' "${DEV}"
    diskutil unmountDisk "${DEV}" || true
fi

# ---------------------------------------------------------------------------
# On Linux, unmount any mounted partitions on the target device
# ---------------------------------------------------------------------------
if [[ "${OS}" == "Linux" ]]; then
    sync
    for mp in $(lsblk -ln -o MOUNTPOINT "${DEV}" 2>/dev/null | grep -v '^$' || true); do
        printf 'Unmounting %s...\n' "${mp}"
        sudo umount "${mp}" 2>/dev/null || true
    done
fi

# ---------------------------------------------------------------------------
# Flash: prefer bmaptool (fast sparse write), fall back to dd
# ---------------------------------------------------------------------------
FLASH_START="$(date +%s)"

if command -v bmaptool >/dev/null 2>&1; then
    printf '\nFlashing with bmaptool (sparse, fast)...\n'
    if [[ "${OS}" == "Darwin" ]]; then
        bmaptool copy "${IMG}" "${DEV}"
    else
        sudo bmaptool copy "${IMG}" "${DEV}"
    fi
else
    printf '\nFlashing with dd (bs=%s)...\n' "${FLASH_BS}"
    if [[ "${OS}" == "Darwin" ]]; then
        # macOS: use /dev/rdisk for faster raw access.
        RAW_DEV="${DEV/\/dev\/disk//dev/rdisk}"
        sudo dd if="${IMG}" of="${RAW_DEV}" bs="${FLASH_BS}" status=progress
    else
        sudo dd if="${IMG}" of="${DEV}" bs="${FLASH_BS}" status=progress
    fi
    sync
fi

FLASH_END="$(date +%s)"
FLASH_ELAPSED=$(( FLASH_END - FLASH_START ))
FLASH_MIN=$(( FLASH_ELAPSED / 60 ))
FLASH_SEC=$(( FLASH_ELAPSED % 60 ))

printf '\nFlash complete in %dm %ds.\n' "${FLASH_MIN}" "${FLASH_SEC}"
printf 'Eject the SD card and insert into the device.\n'
