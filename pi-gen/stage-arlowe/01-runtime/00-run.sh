#!/bin/bash
# Host-side step: stage the arlowe repo subdirs that chroot provisioning needs
# into the rootfs at /root/arlowe-build/repo so 00-run-chroot.sh can resolve
# REPO_ROOT and invoke the existing install scripts.
#
# NOTE: must NOT be under /tmp — pi-gen's on_chroot mounts a fresh tmpfs over
# the rootfs /tmp before every *-run-chroot.sh, which would mask anything the
# host stages there. /root is never mounted over.
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
#   - third_party/node/       (manifest.yml; the tarball too when it has been
#                              fetched into the repo dir — see ADR-0008. The
#                              dashboard runs this Node, not /usr/bin/node,
#                              because bookworm's 18.20.4 cannot run next@16.)
#   - pi-gen/stage-arlowe/01-runtime/files/  (this stage's own chroot build
#                              scripts and, under venv-requirements/, the pinned
#                              pip requirement files build-venvs.sh installs.
#                              Staging a pi-gen path back into the chroot looks
#                              odd; it is deliberate. The requirement files are
#                              build inputs that must be resolvable from INSIDE
#                              the chroot, and the chroot can see nothing but
#                              this staged tree. Without this entry they reach
#                              the chroot not at all and build-venvs.sh fails on
#                              its input gate — which is the correct failure, but
#                              it is still a failure.)
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

CHROOT_REPO="/root/arlowe-build/repo"
STAGING="${ROOTFS_DIR}${CHROOT_REPO}"

echo "[01-runtime] staging repo tree into chroot at ${CHROOT_REPO}"
install -d -m 0755 "${STAGING}"

# Stage each required subdir. rsync preserves permissions and is idempotent.
# third_party/ax-llm is staged because step 10 compiles it in the chroot. This
# list is an allowlist, so a subdir that is not named here is simply absent and
# the failure surfaces only at the step that needs it -- build-ax-llm.sh died
# with "submodule not found" while the submodule was present on the build host.
# The whole staged tree is removed by the cleanup block before the rootfs is
# measured, and build-ax-llm.sh deletes its own build directory, so neither the
# 28 MB of source nor the object files reach the image.
for subdir in scripts/provision units config runtime provision third_party/axcl third_party/whisplay-driver third_party/node third_party/ax-llm pi-gen/stage-arlowe/01-runtime/files; do
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
