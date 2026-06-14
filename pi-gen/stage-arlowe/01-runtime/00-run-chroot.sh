#!/bin/bash
# Chroot provisioning for the arlowe rootfs.
# pi-gen runs this INSIDE the rootfs chroot as root.
#
# Mirrors the ORDER in scripts/provision/install-arlowe-on-arlowe1-staging.sh
# but uses the LITERAL `arlowe` (no sed transforms) — this is the production
# image, not the staging environment.
#
# Composition order (matches the staging reference):
#   1. install-arlowe-user.sh    — create arlowe system user + group
#   2. install-arlowe-fs.sh      — /opt/arlowe, /var/lib/arlowe, /etc/arlowe layout
#   3. install-arlowe-config.sh  — schema.yml + defaults.yml + loader library
#   4. units/install-units.sh    — copy *.service to /etc/systemd/system
#   5. install-arlowe-cli.sh     — /usr/local/sbin/arlowe-* symlinks
#   6. install-arlowe-udev-polkit.sh
#   7. (post-axcl) extract-axcl-udev-from-deb.sh diagnostic (axcl deb installs its rule; ours overrides)
#
# After the provision chain:
#   - Populate /opt/arlowe/runtime + /opt/arlowe/config + /opt/arlowe/third_party
#     from the staged repo tree.
#   - dpkg-install the axcl deb; remove the deb's broken udev rule (GROUP placeholder).
#   - Vendor WhisPlay.py to /opt/arlowe/third_party/whisplay-driver/.
#   - Optionally install the WM8960 audio HAT driver (skipped if bundle absent — rights
#     unresolved per third_party/whisplay-driver/PROVENANCE.md).
#   - Add fstab entry mounting the shared models partition read-only at /opt/arlowe/models.
#     PARTUUID is a placeholder — plan 06-04's partition-image.sh substitutes the real
#     PARTUUID when it writes the per-slot fstab.
#   - Clean in-chroot nondeterminism for reproducible builds.
set -euo pipefail

REPO_ROOT="/tmp/arlowe-build/repo"
PROVISION="${REPO_ROOT}/scripts/provision"

# Guard: staged repo tree must be present.
if [[ ! -d "${REPO_ROOT}" ]]; then
    echo "[00-run-chroot] ERROR: staged repo not found at ${REPO_ROOT}" >&2
    echo "[00-run-chroot] Host-side 00-run.sh must run before the chroot step." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. arlowe system user + group
# ---------------------------------------------------------------------------
echo "[00-run-chroot] step 1: install-arlowe-user.sh"
bash "${PROVISION}/install-arlowe-user.sh"

# ---------------------------------------------------------------------------
# 2. filesystem layout: /opt/arlowe, /var/lib/arlowe, /etc/arlowe
#    install-arlowe-fs.sh creates /opt/arlowe/models as an empty directory —
#    that directory becomes the MOUNT POINT for the shared read-only models
#    partition (ADR-0004). Leaving it empty here is correct.
#    /var/lib/arlowe is a plain dir in the chroot; it becomes a separate
#    partition mounted at first boot (plan 06-04). install -d is idempotent
#    regardless of whether the path is a dir or a mount point.
# ---------------------------------------------------------------------------
echo "[00-run-chroot] step 2: install-arlowe-fs.sh"
bash "${PROVISION}/install-arlowe-fs.sh"

# ---------------------------------------------------------------------------
# 3. config content: schema.yml + defaults.yml + loader library
#    Does NOT create /etc/arlowe/config.yml — its absence is the CONFIG-03
#    pairing trigger (Phase 8 writes it on first successful pairing).
# ---------------------------------------------------------------------------
echo "[00-run-chroot] step 3: install-arlowe-config.sh"
# install-arlowe-config.sh resolves REPO_ROOT relative to its own location
# (scripts/provision/); since the staged tree preserves that layout, no
# override is needed.
bash "${PROVISION}/install-arlowe-config.sh"

# ---------------------------------------------------------------------------
# 4. systemd units → /etc/systemd/system/
#    install-units.sh skips daemon-reload when systemd is not PID 1 (chroot).
#    Units reference /opt/arlowe/models/ via QWEN_MODEL_DIR, ARLOWE_PIPER_MODEL,
#    etc. — those paths resolve once the shared models partition is mounted at
#    /opt/arlowe/models at runtime. No change to unit files needed.
# ---------------------------------------------------------------------------
echo "[00-run-chroot] step 4: units/install-units.sh"
bash "${REPO_ROOT}/units/install-units.sh"

# ---------------------------------------------------------------------------
# 5. CLI symlinks: /usr/local/sbin/arlowe-* → /opt/arlowe/runtime/cli/<name>
#    The targets are populated below (step: populate runtime tree).
# ---------------------------------------------------------------------------
echo "[00-run-chroot] step 5: install-arlowe-cli.sh"
bash "${PROVISION}/install-arlowe-cli.sh"

# ---------------------------------------------------------------------------
# 6. udev rules + polkit rule
# ---------------------------------------------------------------------------
echo "[00-run-chroot] step 6: install-arlowe-udev-polkit.sh"
bash "${PROVISION}/install-arlowe-udev-polkit.sh"

# ---------------------------------------------------------------------------
# Populate /opt/arlowe/runtime + /opt/arlowe/config from the staged repo.
# install-arlowe-cli.sh created the symlinks; the targets must exist.
# install-arlowe-config.sh already installed config/ content; rsync below
# is additive and will not overwrite the already-correctly-owned config files
# because we sync only runtime/ here.
# ---------------------------------------------------------------------------
echo "[00-run-chroot] populating /opt/arlowe/runtime from staged repo"
rsync -a --chown=root:arlowe "${REPO_ROOT}/runtime/" /opt/arlowe/runtime/

# Enforce execute bits on CLI entrypoints so the symlinks are useful.
if [[ -d /opt/arlowe/runtime/cli ]]; then
    chmod 0755 /opt/arlowe/runtime/cli/*  2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Install the axcl deb.
# The deb path inside the chroot was written by the host-side 00-run.sh into
# /tmp/arlowe-build/repo/.axcl-deb-path. Fall back to scanning third_party/axcl/.
# ---------------------------------------------------------------------------
AXCL_DEB_PATH_FILE="${REPO_ROOT}/.axcl-deb-path"
if [[ -f "${AXCL_DEB_PATH_FILE}" ]]; then
    AXCL_DEB="$(cat "${AXCL_DEB_PATH_FILE}")"
else
    AXCL_DEB="$(find "${REPO_ROOT}/third_party/axcl" -name "*.deb" | head -1 || true)"
fi

if [[ -n "${AXCL_DEB}" ]] && [[ -f "${AXCL_DEB}" ]]; then
    echo "[00-run-chroot] installing axcl deb: ${AXCL_DEB}"
    dpkg -i "${AXCL_DEB}"
    # 7. Run the axcl udev extraction diagnostic to confirm no rule conflict.
    echo "[00-run-chroot] step 7: extract-axcl-udev-from-deb.sh (diagnostic)"
    bash "${PROVISION}/extract-axcl-udev-from-deb.sh" "${AXCL_DEB}" || true
    # install-arlowe-udev-polkit.sh (step 6) already removes the broken deb rule;
    # re-run the removal guard in case dpkg postinst re-created it.
    _axcl_deb_rule=/etc/udev/rules.d/axcl_host.rules
    if [[ -f "${_axcl_deb_rule}" ]] && grep -q 'GROUP="<users>"' "${_axcl_deb_rule}"; then
        rm -f "${_axcl_deb_rule}"
        echo "[00-run-chroot] removed axcl deb's broken udev rule (GROUP placeholder)"
    fi
else
    echo "[00-run-chroot] WARNING: axcl deb not staged — skipping dpkg install." >&2
    echo "[00-run-chroot] Ensure third_party/axcl/axcl_host_aarch64_V3.10.2.deb is present" >&2
    echo "[00-run-chroot] per third_party/axcl/INSTALL.md (Strategy C: user-supplied)." >&2
fi

# ---------------------------------------------------------------------------
# Vendor WhisPlay driver to /opt/arlowe/third_party/whisplay-driver/.
# Apache 2.0 license permits redistribution with attribution (PROVENANCE.md §License).
# face.py's default ARLOWE_WHISPLAY_DRIVER_PATH already points here — no env
# override needed on a production image.
# ---------------------------------------------------------------------------
echo "[00-run-chroot] vendoring WhisPlay driver"
WHISPLAY_SRC="${REPO_ROOT}/third_party/whisplay-driver"
WHISPLAY_DST=/opt/arlowe/third_party/whisplay-driver

install -d -o root -g arlowe -m 0755 "${WHISPLAY_DST}"

for f in WhisPlay.py LICENSE README.md PROVENANCE.md; do
    if [[ -f "${WHISPLAY_SRC}/${f}" ]]; then
        install -o root -g arlowe -m 0644 "${WHISPLAY_SRC}/${f}" "${WHISPLAY_DST}/${f}"
    else
        echo "[00-run-chroot] WARNING: ${WHISPLAY_SRC}/${f} not found — skipping" >&2
    fi
done

# ---------------------------------------------------------------------------
# WM8960 audio HAT install — conditional on driver bundle presence.
# Rights for the Waveshare-sourced WM8960 bundle are unresolved per
# third_party/whisplay-driver/PROVENANCE.md §License (WM8960 section).
# If the bundle is present in the staged tree, run the installer; otherwise
# skip with a logged note. A v2 image build can add it once rights are confirmed.
# ---------------------------------------------------------------------------
WM8960_INSTALLER="${WHISPLAY_SRC}/install_wm8960_drive.sh"
if [[ -f "${WM8960_INSTALLER}" ]]; then
    echo "[00-run-chroot] WM8960 audio HAT installer found — running"
    bash "${WM8960_INSTALLER}" || {
        echo "[00-run-chroot] WARNING: WM8960 installer exited non-zero; continuing." >&2
    }
else
    echo "[00-run-chroot] WM8960 audio HAT installer not staged — skipping." >&2
    echo "[00-run-chroot] Waveshare WM8960 redistribution rights unresolved (PROVENANCE.md)." >&2
fi

# ---------------------------------------------------------------------------
# Models mount point: /opt/arlowe/models is an EMPTY dir created by
# install-arlowe-fs.sh above. It is the mount point for the shared read-only
# models partition (ADR-0004). Do NOT populate it here.
#
# Wire the fstab entry so the runtime units find their models at the paths
# the service unit files reference (QWEN_MODEL_DIR, ARLOWE_PIPER_MODEL, etc.)
# once the partition is mounted.
#
# PARTUUID is a placeholder token — plan 06-04's partition-image.sh substitutes
# the real models-partition PARTUUID when it writes the per-slot fstab. The same
# entry applies to both slot A and slot B (identical shared read-only mount).
# ---------------------------------------------------------------------------
echo "[00-run-chroot] adding shared models partition to /etc/fstab"
MODELS_PARTUUID_PLACEHOLDER="ARLOWE-MODELS-PARTUUID-REPLACE-BY-06-04"
cat >> /etc/fstab <<EOF

# Shared read-only models partition — mounted at /opt/arlowe/models.
# PARTUUID is a placeholder; plan 06-04's partition-image.sh substitutes the
# real models-partition PARTUUID for both slot A and slot B rootfs fstabs.
# The partition is read-only in v1; a future model-OTA agent can remount rw.
PARTUUID=${MODELS_PARTUUID_PLACEHOLDER}  /opt/arlowe/models  ext4  ro,noatime  0  2
EOF

# ---------------------------------------------------------------------------
# In-chroot cleanup for reproducibility.
# Clears obvious nondeterminism so repeated builds produce bit-similar rootfs.
# Snapshot/SOURCE_DATE_EPOCH wiring belongs to plan 06-06's build orchestration;
# here we handle only the in-chroot artifacts.
# ---------------------------------------------------------------------------
echo "[00-run-chroot] cleaning nondeterminism artifacts"

# apt cache
apt-get clean
rm -rf /var/lib/apt/lists/*

# Python bytecode caches
find /opt/arlowe /usr -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find /opt/arlowe /usr -name "*.pyc" -delete 2>/dev/null || true

# machine-id — regenerated on first boot by systemd
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id

# SSH host keys — regenerated on first boot by ssh-keygen (openssh-server FirstBoot)
rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub

echo "[00-run-chroot] provisioning complete"
