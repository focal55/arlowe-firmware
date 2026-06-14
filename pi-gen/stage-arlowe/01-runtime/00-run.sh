#!/bin/bash
# Host-side step: stage the arlowe repo subdirs that chroot provisioning needs
# into the rootfs at /tmp/arlowe-build/repo so 00-run-chroot.sh can resolve
# REPO_ROOT and invoke the existing install scripts.
#
# This script runs on the BUILD HOST (not inside the chroot). pi-gen's
# run_stage calls host-side 00-run.sh scripts with ROOTFS_DIR pointing at the
# in-progress rootfs tree.
#
# What we stage here:
#   - scripts/provision/   (install-arlowe-*.sh, extract-axcl-udev-from-deb.sh)
#   - units/               (*.service + install-units.sh)
#   - config/              (schema.yml, defaults.yml)
#   - runtime/             (python modules, cli, dashboard, tts, stt, llm, voice,
#                           face, wake-word, lib)
#   - provision/           (udev/ + polkit/ rule sources)
#   - third_party/axcl/    (manifest.yml + the axcl deb, if present)
#   - third_party/whisplay-driver/ (WhisPlay.py, LICENSE, README, PROVENANCE)
#   - scripts/verify-third-party.sh
#
# We do NOT stage model artifacts here — models go to the separate models tree
# assembled in 02-models/00-run.sh (host-side) for plan 06-04.
#
# The axcl deb is user-supplied (Strategy C per third_party/axcl/manifest.yml).
# If AXCL_DEB is set in the environment it overrides the default resolved path.
# If the deb is absent we warn and continue — the chroot script gates on its
# presence and will fail clearly if install_to_image is true and the deb is
# missing when it tries to dpkg-install it.
set -euo pipefail

# pi-gen provides ROOTFS_DIR; guard in case this is run manually.
if [[ -z "${ROOTFS_DIR:-}" ]]; then
    echo "[01-runtime/00-run.sh] ERROR: ROOTFS_DIR is not set. Run via pi-gen or set ROOTFS_DIR manually." >&2
    exit 1
fi

# Resolve repo root: this script lives at pi-gen/stage-arlowe/01-runtime/00-run.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

CHROOT_REPO="/tmp/arlowe-build/repo"
STAGING="${ROOTFS_DIR}${CHROOT_REPO}"

echo "[01-runtime] staging repo tree into chroot at ${CHROOT_REPO}"
install -d -m 0755 "${STAGING}"

# Stage each required subdir. rsync preserves permissions and is idempotent.
for subdir in scripts/provision units config runtime provision third_party/axcl third_party/whisplay-driver; do
    src="${REPO_ROOT}/${subdir}"
    dst="${STAGING}/${subdir}"
    if [[ -d "${src}" ]]; then
        install -d -m 0755 "$(dirname "${dst}")"
        rsync -a --delete "${src}/" "${dst}/"
        echo "[01-runtime]   staged ${subdir}/"
    else
        echo "[01-runtime]   WARNING: ${subdir}/ not found in repo — skipping" >&2
    fi
done

# Stage the top-level verify-third-party.sh helper.
if [[ -f "${REPO_ROOT}/scripts/verify-third-party.sh" ]]; then
    install -m 0755 "${REPO_ROOT}/scripts/verify-third-party.sh" \
        "${STAGING}/scripts/verify-third-party.sh"
    echo "[01-runtime]   staged scripts/verify-third-party.sh"
fi

# Resolve and stage the axcl deb (user-supplied, Strategy C).
# AXCL_DEB env var overrides the manifest-resolved path for CI flexibility.
MANIFEST="${REPO_ROOT}/third_party/axcl/manifest.yml"
if [[ -z "${AXCL_DEB:-}" ]] && [[ -f "${MANIFEST}" ]]; then
    DEB_NAME="$(grep -E '^\s+filename:' "${MANIFEST}" | head -1 | awk '{print $2}' | tr -d '"')"
    AXCL_DEB="${REPO_ROOT}/third_party/axcl/${DEB_NAME}"
fi

if [[ -n "${AXCL_DEB:-}" ]] && [[ -f "${AXCL_DEB}" ]]; then
    DEB_DEST="${STAGING}/third_party/axcl/$(basename "${AXCL_DEB}")"
    install -m 0644 "${AXCL_DEB}" "${DEB_DEST}"
    echo "[01-runtime]   staged axcl deb: $(basename "${AXCL_DEB}")"
    # Export the chroot-relative path for the chroot script via a marker file.
    echo "${CHROOT_REPO}/third_party/axcl/$(basename "${AXCL_DEB}")" \
        > "${STAGING}/.axcl-deb-path"
else
    echo "[01-runtime]   WARNING: axcl deb not found at ${AXCL_DEB:-<unresolved>}" >&2
    echo "[01-runtime]   The chroot script will fail if install_to_image=true." >&2
fi

echo "[01-runtime] repo staging complete → ${CHROOT_REPO}"
