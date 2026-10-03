#!/usr/bin/env bash
# scripts/flash-sd.sh
#
# Write an arlowe .img to a confirmed SD card device.
#
# Runs on macOS or Linux. Building the image requires an arm64 Linux host,
# but flashing can be done from the dev's Mac with the .img downloaded from CI.
#
# Usage:
#   scripts/flash-sd.sh <image.img> <device> [--yes] [--dev-access <user> <pubkey-file>]
#
# Examples (Linux):
#   scripts/flash-sd.sh build/arlowe.img /dev/sdb
#   scripts/flash-sd.sh build/arlowe.img /dev/mmcblk0 --yes
#
# Examples (macOS):
#   scripts/flash-sd.sh build/arlowe.img /dev/disk4 --yes
#   scripts/flash-sd.sh build/arlowe.img /dev/disk4 --dev-access <user> ~/.ssh/<key>.pub
#
# Safety:
#   - Refuses to write to the system disk (boot device).
#   - Verifies the target is a removable block device on Linux.
#   - Prompts for confirmation unless --yes is passed.
#   - Uses bmaptool if available (fast sparse write), falls back to dd.
#   - Reads the card back against the image before reporting success
#     (scripts/lib/verify-flash.py); a mismatch fails the script.
#   - With --dev-access, stages a login and SSH key on the boot partition after the
#     read-back passes; the device accepts them only until it is paired.
#   - Prints flash time on completion.
set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") <image.img> <device> [--yes] [--dev-access <user> <pubkey-file>]

Arguments:
  image.img   Path to the .img file to write
  device      Target block device (e.g. /dev/sdb, /dev/mmcblk0, /dev/disk4)
  --yes       Skip the confirmation prompt
  --dev-access <user> <pubkey-file>
              After flashing, stage a login for <user> and the SSH public key on the
              boot partition. The password hash comes from FLASH_DEV_PASSWORD_HASH
              or is prompted for. The device honours it only while unpaired.

Environment:
  FLASH_BS    Block size passed to dd (default: 4M). Ignored when bmaptool is used.
  FLASH_DEV_PASSWORD_HASH
              Crypt hash for --dev-access (openssl passwd -6). Prompted if unset.
EOF
}

die() { printf 'flash-sd: %s\n' "$*" >&2; exit 1; }

# shellcheck source=scripts/lib/stage-dev-access.sh
source "$(dirname "$0")/lib/stage-dev-access.sh"

IMG=""
DEV=""
YES=false
DEV_USER=""
DEV_PUBKEY=""
FLASH_BS="${FLASH_BS:-4M}"

while [[ $# -gt 0 ]]; do
    arg="$1"
    shift
    case "${arg}" in
        --yes) YES=true ;;
        --dev-access)
            [[ $# -ge 2 ]] || die "--dev-access needs <user> <pubkey-file>"
            DEV_USER="$1"
            DEV_PUBKEY="$2"
            shift 2
            validate_dev_pubkey "${DEV_PUBKEY}" || die "--dev-access: invalid pubkey ${DEV_PUBKEY}"
            ;;
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
    dev_base="${dev_name%%p[0-9]*}"   # strip mmcblk/nvme partition suffix (mmcblk0p1 -> mmcblk0)
    # mmcblk/nvme names legitimately end in a digit (controller number); only strip
    # trailing digits for sdX/loop-style names where the digit IS the partition number.
    case "${dev_base}" in
        mmcblk*|nvme*) : ;;
        *) dev_base="${dev_base%%[0-9]*}" ;;
    esac
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
VERIFY_DEV="${DEV}"
[[ "${OS}" == "Darwin" ]] && VERIFY_DEV="${DEV/\/dev\/disk//dev/rdisk}"
VERIFY_ARGS=()

if command -v bmaptool >/dev/null 2>&1; then
    # bmaptool skips the holes, so only the mapped ranges can be compared.
    for bmap in "${IMG}.bmap" "${IMG%.*}.bmap"; do
        if [[ -f "${bmap}" ]]; then VERIFY_ARGS=(--bmap "${bmap}"); break; fi
    done
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

sync
printf '\nReading the card back against the image...\n'
if ! sudo python3 "$(dirname "$0")/lib/verify-flash.py" "${IMG}" "${VERIFY_DEV}" ${VERIFY_ARGS[@]+"${VERIFY_ARGS[@]}"}; then
    die "the card does not match the image. Do not boot it. A reader that drops or misplaces writes causes this; reflash through a different reader."
fi

# ---------------------------------------------------------------------------
# Optional: stage dev access on the boot partition (the first partition)
# ---------------------------------------------------------------------------
if [[ -n "${DEV_USER}" ]]; then
    dev_hash="${FLASH_DEV_PASSWORD_HASH:-}"
    if [[ -z "${dev_hash}" ]]; then
        dev_hash="$(openssl passwd -6)"
    fi
    stage_dir="$(mktemp -d)"
    mnt_dir="$(mktemp -d)"
    trap 'rm -rf "${stage_dir}"; rmdir "${mnt_dir}" 2>/dev/null || true' EXIT
    stage_dev_access "${stage_dir}" "${DEV_USER}" "${dev_hash}" "${DEV_PUBKEY}" \
        || die "could not stage dev access"

    printf '\nStaging dev access for %s on the boot partition...\n' "${DEV_USER}"
    if [[ "${OS}" == "Darwin" ]]; then
        # The mount is root-owned, so the copy needs sudo; hence staged in a temp dir.
        sudo diskutil mount -mountPoint "${mnt_dir}" "${DEV}s1" >/dev/null
        sudo cp "${stage_dir}/userconf.txt" "${stage_dir}/authorized_keys" "${mnt_dir}/"
        sync
        sudo diskutil unmount "${DEV}s1" >/dev/null
    else
        case "${DEV}" in
            *mmcblk*|*nvme*) boot_part="${DEV}p1" ;;
            *) boot_part="${DEV}1" ;;
        esac
        sudo mount "${boot_part}" "${mnt_dir}"
        sudo cp "${stage_dir}/userconf.txt" "${stage_dir}/authorized_keys" "${mnt_dir}/"
        sync
        sudo umount "${mnt_dir}"
    fi
    printf 'Dev access staged: userconf.txt and authorized_keys.\n'
fi

FLASH_END="$(date +%s)"
FLASH_ELAPSED=$(( FLASH_END - FLASH_START ))
FLASH_MIN=$(( FLASH_ELAPSED / 60 ))
FLASH_SEC=$(( FLASH_ELAPSED % 60 ))

printf '\nFlashed and verified in %dm %ds.\n' "${FLASH_MIN}" "${FLASH_SEC}"
printf 'Eject the SD card and insert into the device.\n'
