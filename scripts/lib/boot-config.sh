#!/usr/bin/env bash
# scripts/lib/boot-config.sh
#
# Build-time library: lays the tryboot A/B boot configuration into the shared
# /boot FAT partition (p1) of the assembled image.
#
# Called from build-image.sh's extension hook (Step 4b):
#   source scripts/lib/boot-config.sh
#   write_boot_config <partuuid-map-file> <output-img>
#
# The partuuid-map file must contain (produced by partition-image.sh):
#   PARTUUID_BOOT=<uuid>
#   PARTUUID_A=<uuid>
#   PARTUUID_B=<uuid>
#   PARTUUID_MODELS=<uuid>
#
# Per ADR-0005, the persistent A/B default is the root= in config.txt:
#   - config.txt sets tryboot_a_b=1; cmdline.txt points root= at slot A PARTUUID
#   - tryboot.txt is RESERVED for Phase 9 one-shot OTA trial-boot
#   - arlowe-ab rewrites config.txt's cmdline= to flip the persistent default
#   - The selector swaps only root= (rootfs slot); the models mount lives in
#     each slot's fstab, not in cmdline, and is not touched by this script
#
# This library is sourced by build-image.sh; it is NOT executable standalone.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "boot-config.sh is a library; source it from build-image.sh." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# write_boot_config <partuuid-map-file> <output-img>
#
# Mounts the FAT boot partition (p1) from the image and writes:
#   config.txt   — tryboot_a_b=1; persistent default cmdline= pointing root=
#                  at slot A's PARTUUID (factory default)
#   cmdline.txt  — the active root= line that arlowe-ab edits on the device
#   tryboot.txt  — RESERVED for Phase 9; in v1 mirrors the B/recovery path so
#                  "reboot 0 tryboot" lands somewhere sane, but arlowe-ab does
#                  NOT use this one-shot path for persistent flips
# ---------------------------------------------------------------------------
write_boot_config() {
    local partuuid_map="$1"
    local output_img="$2"

    [[ -f "${partuuid_map}" ]] || { echo "boot-config.sh: partuuid-map not found: ${partuuid_map}" >&2; return 1; }
    [[ -f "${output_img}" ]]   || { echo "boot-config.sh: output-img not found: ${output_img}" >&2; return 1; }

    local puuid_a puuid_b
    puuid_a="$(grep '^PARTUUID_A=' "${partuuid_map}" | cut -d= -f2)"
    puuid_b="$(grep '^PARTUUID_B=' "${partuuid_map}" | cut -d= -f2)"

    [[ -n "${puuid_a}" ]] || { echo "boot-config.sh: PARTUUID_A missing from map" >&2; return 1; }
    [[ -n "${puuid_b}" ]] || { echo "boot-config.sh: PARTUUID_B missing from map" >&2; return 1; }

    echo "[boot-config] slot A PARTUUID: ${puuid_a}"
    echo "[boot-config] slot B PARTUUID: ${puuid_b}"

    local loop_dev mnt_boot mnt_a
    loop_dev="$(sudo losetup -f --show -P "${output_img}")"

    # shellcheck disable=SC2329
    _bconf_cleanup() {
        sudo umount "${mnt_boot}" 2>/dev/null || true
        sudo umount "${mnt_a}" 2>/dev/null || true
        sudo losetup -d "${loop_dev}" 2>/dev/null || true
        rmdir "${mnt_boot}" 2>/dev/null || true
        rmdir "${mnt_a}" 2>/dev/null || true
    }
    trap _bconf_cleanup RETURN ERR

    mnt_boot="$(mktemp -d)"
    sudo mount "${loop_dev}p1" "${mnt_boot}"

    _bconf_write_config "${mnt_boot}" "${puuid_a}" "${puuid_b}"

    sudo umount "${mnt_boot}"
    rmdir "${mnt_boot}"
    mnt_boot=""

    # Install the PARTUUID map into slot A's /etc/arlowe/ so arlowe-ab can
    # resolve A/B slot names to PARTUUIDs at runtime without needing the build host.
    mnt_a="$(mktemp -d)"
    sudo mount "${loop_dev}p2" "${mnt_a}"
    sudo install -d -m 0755 "${mnt_a}/etc/arlowe"
    sudo install -m 0644 "${partuuid_map}" "${mnt_a}/etc/arlowe/ab-partuuid-map"
    echo "[boot-config] PARTUUID map installed at /etc/arlowe/ab-partuuid-map in slot A"
    sudo umount "${mnt_a}"
    rmdir "${mnt_a}"
    mnt_a=""

    sudo sync
    sudo losetup -d "${loop_dev}" 2>/dev/null || true
    trap - RETURN ERR

    echo "[boot-config] tryboot boot configuration written to /boot (p1)"
}

# ---------------------------------------------------------------------------
# Internal: write the three boot config files into the mounted FAT partition
# ---------------------------------------------------------------------------
_bconf_write_config() {
    local mnt="$1"
    local puuid_a="$2"
    local puuid_b="$3"

    # Shared kernel command-line options for both slots.
    # root= is the only slot-discriminating field; everything else is identical.
    # The models partition (/opt/arlowe/models) is mounted via each slot's fstab
    # (by PARTUUID, ro,noatime) — it is NOT in the kernel cmdline.
    local cmdline_common="console=serial0,115200 console=tty1 fsck.repair=yes rootwait"

    # config.txt — persistent default; cmdline= points root= at slot A PARTUUID.
    # tryboot_a_b=1 enables file-level A/B within the single shared /boot FAT.
    # When the Pi firmware sees this flag + "reboot 0 tryboot", it reads
    # tryboot.txt instead of config.txt for that one boot (Phase 9 OTA path).
    sudo tee "${mnt}/config.txt" >/dev/null <<EOF
# Arlowe A/B boot configuration (ADR-0005)
# Managed by arlowe-ab — do not edit manually.
#
# tryboot_a_b=1: enables file-level A/B within one shared /boot FAT partition.
# The persistent A/B default is the root= below (in cmdline.txt, referenced
# here). arlowe-ab flips the persistent default by rewriting cmdline.txt.
#
# tryboot.txt is RESERVED for Phase 9 OTA one-shot trial-boot.
# arlowe-ab does NOT use "reboot 0 tryboot" for persistent flips.
tryboot_a_b=1

[pi5]
# Pi 5 — AARCH64 kernel
kernel=kernel_2712.img
arm_64bit=1
[all]
# Shared cmdline for both slots (root= overridden by arlowe-ab in cmdline.txt)
include cmdline.txt
EOF

    # cmdline.txt — the active root= line. arlowe-ab rewrites only root= here
    # to flip between slot A and slot B. All other flags stay constant.
    sudo tee "${mnt}/cmdline.txt" >/dev/null <<EOF
${cmdline_common} root=PARTUUID=${puuid_a}
EOF

    # tryboot.txt — RESERVED for Phase 9 OTA one-shot trial-boot.
    # In v1 this mirrors the slot-B (recovery) boot parameters so that
    # "reboot 0 tryboot" lands on slot B rather than hanging. arlowe-ab
    # does NOT use this file for persistent flips.
    sudo tee "${mnt}/tryboot.txt" >/dev/null <<EOF
# tryboot.txt — RESERVED for Phase 9 OTA one-shot trial-boot.
#
# This file is loaded instead of config.txt when the Pi firmware sees the
# "tryboot" flag set (via "reboot 0 tryboot"). In v1 it mirrors slot B so
# that a manual "reboot 0 tryboot" lands on the recovery rootfs safely.
#
# Phase 9 OTA will overwrite this file with the trial OS slot's parameters
# before issuing "reboot 0 tryboot". arlowe-ab DOES NOT write or read this
# file for persistent slot flips — it uses cmdline.txt exclusively.
tryboot_a_b=1

[pi5]
kernel=kernel_2712.img
arm_64bit=1
[all]
include tryboot_cmdline.txt
EOF

    # tryboot_cmdline.txt — cmdline for the one-shot tryboot path (slot B).
    sudo tee "${mnt}/tryboot_cmdline.txt" >/dev/null <<EOF
${cmdline_common} root=PARTUUID=${puuid_b}
EOF

    echo "[boot-config] wrote config.txt (tryboot_a_b=1, default root=slot-A)"
    echo "[boot-config] wrote cmdline.txt (root=PARTUUID=${puuid_a})"
    echo "[boot-config] wrote tryboot.txt (Phase 9 reserved; mirrors slot-B)"
    echo "[boot-config] wrote tryboot_cmdline.txt (slot-B PARTUUID)"
}
