#!/usr/bin/env bash
# scripts/lib/recovery-stub.sh
#
# Build-time library: writes the minimal slot-B recovery rootfs into p3 of
# the assembled image, then enables the recovery service inside it.
#
# Called from build-image.sh's extension hook (Step 4b), AFTER write_boot_config:
#   source scripts/lib/recovery-stub.sh
#   write_recovery_stub <partuuid-map-file> <output-img>
#
# Approach: copy slot A (already in p2) into slot B (p3), then aggressively
# prune everything that is not needed for the recovery action — keeps B minimal
# (~300 MB target) and avoids a second debootstrap or rootfs build.
# The recovery action itself (arlowe-recovery.sh + .service) is installed from
# the repo's runtime/recovery/ directory. The WhisPlay driver minimal subset is
# copied from third_party/whisplay-driver/.
#
# Slot-B fstab carries:
#   - /boot/firmware (shared FAT, PARTUUID_BOOT)
#   - /var/lib/arlowe (owner-state, PARTUUID_OWNER, noatime)
#   - /opt/arlowe/models (shared models, PARTUUID_MODELS, ro,noatime,nofail)
#     nofail is required: recovery must boot even if the models partition is
#     absent or unmounted — the recovery action is model-free by design.
#
# This library is sourced by build-image.sh; it is NOT executable standalone.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "recovery-stub.sh is a library; source it from build-image.sh." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# write_recovery_stub <partuuid-map-file> <output-img>
# ---------------------------------------------------------------------------
write_recovery_stub() {
    local partuuid_map="$1"
    local output_img="$2"

    [[ -f "${partuuid_map}" ]] || { echo "recovery-stub.sh: partuuid-map not found: ${partuuid_map}" >&2; return 1; }
    [[ -f "${output_img}" ]]   || { echo "recovery-stub.sh: output-img not found: ${output_img}" >&2; return 1; }

    local puuid_boot puuid_b puuid_owner puuid_models
    puuid_boot="$(grep '^PARTUUID_BOOT=' "${partuuid_map}"   | cut -d= -f2)"
    puuid_b="$(grep '^PARTUUID_B=' "${partuuid_map}"         | cut -d= -f2)"
    puuid_owner="$(grep '^PARTUUID_OWNER=' "${partuuid_map}" | cut -d= -f2)"
    puuid_models="$(grep '^PARTUUID_MODELS=' "${partuuid_map}" | cut -d= -f2)"

    [[ -n "${puuid_boot}" ]]   || { echo "recovery-stub.sh: PARTUUID_BOOT missing"   >&2; return 1; }
    [[ -n "${puuid_b}" ]]      || { echo "recovery-stub.sh: PARTUUID_B missing"      >&2; return 1; }
    [[ -n "${puuid_owner}" ]]  || { echo "recovery-stub.sh: PARTUUID_OWNER missing"  >&2; return 1; }
    [[ -n "${puuid_models}" ]] || { echo "recovery-stub.sh: PARTUUID_MODELS missing" >&2; return 1; }

    echo "[recovery-stub] slot B PARTUUID:   ${puuid_b}"
    echo "[recovery-stub] boot PARTUUID:     ${puuid_boot}"
    echo "[recovery-stub] owner PARTUUID:    ${puuid_owner}"
    echo "[recovery-stub] models PARTUUID:   ${puuid_models}"

    # Determine repo root from this script's location (scripts/lib/recovery-stub.sh)
    local repo_root
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

    local loop_dev mnt_a mnt_b
    loop_dev="$(sudo losetup -f --show -P "${output_img}")"

    _rstub_cleanup() {
        sudo umount "${mnt_b}" 2>/dev/null || true
        sudo umount "${mnt_a}" 2>/dev/null || true
        sudo losetup -d "${loop_dev}" 2>/dev/null || true
        rmdir "${mnt_b}" 2>/dev/null || true
        rmdir "${mnt_a}" 2>/dev/null || true
    }
    trap _rstub_cleanup RETURN ERR

    mnt_a="$(mktemp -d)"
    mnt_b="$(mktemp -d)"

    sudo mount -o ro "${loop_dev}p2" "${mnt_a}"
    sudo mount "${loop_dev}p3" "${mnt_b}"

    _rstub_clone_and_prune "${mnt_a}" "${mnt_b}"
    _rstub_write_fstab     "${mnt_b}" "${puuid_boot}" "${puuid_owner}" "${puuid_models}"
    _rstub_install_recovery "${mnt_b}" "${repo_root}"
    _rstub_write_partuuid_map "${mnt_b}" "${partuuid_map}"
    _rstub_enable_service  "${mnt_b}"

    sudo sync
    _rstub_cleanup
    trap - RETURN ERR

    echo "[recovery-stub] slot-B recovery rootfs written to p3"
}

# ---------------------------------------------------------------------------
# Internal: clone slot A into slot B, then prune non-recovery content
# ---------------------------------------------------------------------------
_rstub_clone_and_prune() {
    local mnt_a="$1"
    local mnt_b="$2"

    echo "[recovery-stub] cloning slot A into slot B..."
    sudo rsync -aHAX --delete "${mnt_a}/" "${mnt_b}/"

    echo "[recovery-stub] pruning non-recovery content from slot B..."

    # Remove the full Arlowe runtime (voice, LLM, STT, TTS, dashboard, wake-word).
    # The recovery stub only needs the recovery script + WhisPlay driver.
    # Keep the venv and system Python packages — the face draw uses system python3 + PIL.
    local prune_dirs=(
        opt/arlowe/runtime/voice
        opt/arlowe/runtime/llm
        opt/arlowe/runtime/stt
        opt/arlowe/runtime/tts
        opt/arlowe/runtime/dashboard
        opt/arlowe/runtime/wake-word
        opt/arlowe/runtime/face
        opt/arlowe/runtime/lib
    )

    for dir in "${prune_dirs[@]}"; do
        if [[ -d "${mnt_b}/${dir}" ]]; then
            sudo rm -rf "${mnt_b:?}/${dir}"
        fi
    done

    # Remove model cache directories that might have been copied from rootfs.
    sudo rm -rf "${mnt_b:?}/opt/arlowe/models" 2>/dev/null || true

    echo "[recovery-stub] pruning complete"
}

# ---------------------------------------------------------------------------
# Internal: write slot-B fstab
# ---------------------------------------------------------------------------
_rstub_write_fstab() {
    local mnt_b="$1"
    local puuid_boot="$2"
    local puuid_owner="$3"
    local puuid_models="$4"

    # root (/) comes from kernel root= in cmdline — not in fstab.
    sudo tee "${mnt_b}/etc/fstab" >/dev/null <<EOF
# /etc/fstab — slot B (recovery)
# root (/) is supplied by the kernel root= parameter (tryboot A/B, ADR-0005).
# Models partition is nofail: recovery is model-free and must boot without it.

# Shared boot firmware (FAT)
PARTUUID=${puuid_boot}  /boot/firmware      vfat  defaults            0  2

# Owner state (noatime, fixed size — ADR-0004)
PARTUUID=${puuid_owner}  /var/lib/arlowe    ext4  defaults,noatime    0  2

# Shared models partition — ro,nofail: recovery does not require models
PARTUUID=${puuid_models}  /opt/arlowe/models  ext4  ro,noatime,nofail  0  2
EOF

    echo "[recovery-stub] slot-B fstab written (models nofail)"
}

# ---------------------------------------------------------------------------
# Internal: install recovery script, service, and WhisPlay driver into slot B
# ---------------------------------------------------------------------------
_rstub_install_recovery() {
    local mnt_b="$1"
    local repo_root="$2"

    local recovery_src="${repo_root}/runtime/recovery"
    local whisplay_src="${repo_root}/third_party/whisplay-driver"

    # Install recovery script.
    sudo install -d -m 0755 "${mnt_b}/opt/arlowe/runtime/recovery"
    sudo install -m 0755 "${recovery_src}/arlowe-recovery.sh" \
        "${mnt_b}/opt/arlowe/runtime/recovery/arlowe-recovery.sh"

    # Install systemd service.
    sudo install -d -m 0755 "${mnt_b}/etc/systemd/system"
    sudo install -m 0644 "${recovery_src}/arlowe-recovery.service" \
        "${mnt_b}/etc/systemd/system/arlowe-recovery.service"

    # Install WhisPlay driver (minimal subset: the Python driver file only).
    # The audio kernel modules are not needed for face rendering alone.
    sudo install -d -m 0755 "${mnt_b}/opt/arlowe/third_party/whisplay-driver"
    if [[ -f "${whisplay_src}/WhisPlay.py" ]]; then
        sudo install -m 0644 "${whisplay_src}/WhisPlay.py" \
            "${mnt_b}/opt/arlowe/third_party/whisplay-driver/WhisPlay.py"
    else
        echo "[recovery-stub] WARN: WhisPlay.py not found at ${whisplay_src}/WhisPlay.py — Whisplay face will be skipped at runtime"
    fi

    # Create the /opt/arlowe/models mountpoint so the nofail fstab entry works.
    sudo install -d -m 0755 "${mnt_b}/opt/arlowe/models"

    echo "[recovery-stub] recovery script, service, and WhisPlay driver installed"
}

# ---------------------------------------------------------------------------
# Internal: write the PARTUUID map into slot B's /etc/arlowe/ so arlowe-ab
# and arlowe-recovery.sh can resolve A/B slot names at runtime.
# ---------------------------------------------------------------------------
_rstub_write_partuuid_map() {
    local mnt_b="$1"
    local partuuid_map="$2"

    sudo install -d -m 0755 "${mnt_b}/etc/arlowe"
    sudo install -m 0644 "${partuuid_map}" "${mnt_b}/etc/arlowe/ab-partuuid-map"
    echo "[recovery-stub] PARTUUID map installed at /etc/arlowe/ab-partuuid-map"
}

# ---------------------------------------------------------------------------
# Internal: enable the recovery service via systemd wants symlink
# ---------------------------------------------------------------------------
_rstub_enable_service() {
    local mnt_b="$1"

    local wants_dir="${mnt_b}/etc/systemd/system/multi-user.target.wants"
    sudo install -d -m 0755 "${wants_dir}"
    sudo ln -sf /etc/systemd/system/arlowe-recovery.service \
        "${wants_dir}/arlowe-recovery.service"

    echo "[recovery-stub] arlowe-recovery.service enabled (multi-user.target.wants)"
}
