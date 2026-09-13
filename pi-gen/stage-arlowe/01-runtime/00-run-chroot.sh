#!/bin/bash
# Chroot provisioning for the arlowe rootfs.
# pi-gen runs this INSIDE the rootfs chroot as root.
#
# Mirrors the ORDER in scripts/provision/install-arlowe-on-arlowe1-staging.sh
# but uses the LITERAL `arlowe` (no sed transforms) — this is the production
# image, not the staging environment.
#
# Composition order. This block describes the script BELOW it — if you insert a
# step, renumber here in the same edit. It previously listed 5=cli and 6=udev
# while the body did the reverse, which is the same stale-comment defect class as
# install-arlowe-fs.sh's "Phase 6 populates the venvs": a reader who trusts the
# header reasons about a script that does not exist.
#
#   1. install-arlowe-user.sh    — create arlowe system user + group
#   2. install-arlowe-fs.sh      — /opt/arlowe, /var/lib/arlowe, /etc/arlowe layout
#   3. install-arlowe-config.sh  — schema.yml + defaults.yml + loader library
#   4. units/install-units.sh    — copy *.service to /etc/systemd/system
#   5. install-arlowe-udev-polkit.sh
#   -- rsync the staged runtime/ tree into /opt/arlowe/runtime --
#   6. install-arlowe-cli.sh     — /usr/local/sbin/arlowe-* symlinks
#   7. 01-runtime/files/build-venvs.sh — populate /opt/arlowe/venvs/{voice,llm,stt}
#   8. 01-runtime/files/build-dashboard.sh — next build → /opt/arlowe/runtime/dashboard/server.js
#   9. (post-axcl) extract-axcl-udev-from-deb.sh diagnostic (axcl deb installs its rule; ours overrides)
#
# Steps 6, 7 and 8 all consume the rsync above them, which is why the rsync is
# called out in the list rather than left implicit. Steps 7 and 8 additionally
# consume the STAGED repo tree, so both must precede the cleanup at the end of
# this script — it deletes that tree.
#
# After the provision chain:
#   - Populate /opt/arlowe/runtime + /opt/arlowe/config + /opt/arlowe/third_party
#     from the staged repo tree.
#   - Build the three venvs and the dashboard standalone bundle (steps 7 and 8),
#     so that every interpreter and entry point the units name actually exists.
#     Both SC1 gates in scripts/lib/verify-unit-execstart.sh assert this over the
#     finished rootfs at the end of scripts/build-image.sh.
#   - dpkg-install the axcl deb; remove the deb's broken udev rule (GROUP placeholder).
#   - Vendor WhisPlay.py to /opt/arlowe/third_party/whisplay-driver/.
#   - Optionally install the WM8960 audio HAT driver (skipped if bundle absent — rights
#     unresolved per third_party/whisplay-driver/PROVENANCE.md).
#   - Add fstab entry mounting the shared models partition read-only at /opt/arlowe/models.
#     PARTUUID is a placeholder — plan 06-04's partition-image.sh substitutes the real
#     PARTUUID when it writes the per-slot fstab.
#   - Clean in-chroot nondeterminism for reproducible builds.
set -euo pipefail

# Staged by host-side 00-run.sh. NOT under /tmp — pi-gen tmpfs-mounts the
# chroot /tmp, which would mask the staged tree.
REPO_ROOT="/root/arlowe-build/repo"
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
# 5. udev rules + polkit rule
# ---------------------------------------------------------------------------
echo "[00-run-chroot] step 5: install-arlowe-udev-polkit.sh"
bash "${PROVISION}/install-arlowe-udev-polkit.sh"

# ---------------------------------------------------------------------------
# Populate /opt/arlowe/runtime + /opt/arlowe/config from the staged repo.
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
# CLI symlinks: /usr/local/sbin/arlowe-* → /opt/arlowe/runtime/cli/<name>
# Runs AFTER the runtime tree is populated so install-arlowe-cli.sh can verify
# each target exists. It used to run before, which meant ln -sf had nothing to
# check against and a wrong name produced a dangling link that only surfaced on
# hardware as "command not found" (F7 #21, arlowe-ab).
# ---------------------------------------------------------------------------
echo "[00-run-chroot] step 6: install-arlowe-cli.sh"
bash "${PROVISION}/install-arlowe-cli.sh"

# ---------------------------------------------------------------------------
# Populate /opt/arlowe/venvs/{voice,llm,stt}.
#
# Four shipping units name a venv interpreter in their Exec* stanzas
# (arlowe-voice, arlowe-face, whisper-stt, qwen-tokenizer) and until this call
# existed nothing in the image pipeline created one. install-arlowe-fs.sh makes
# the directory; this fills it.
#
# POSITION IS LOAD-BEARING, in both directions:
#   - AFTER the runtime rsync and the CLI symlinks above, so the step order reads
#     in the direction the dependencies point.
#   - BEFORE the reproducibility-cleanup block at the end of this script, which
#     does `rm -rf /root/arlowe-build`, `apt-get clean` and `rm -rf
#     /var/lib/apt/lists/*`. The pinned requirement files live under the staged
#     tree, so a call placed after the cleanup fails on its input gate.
#
# The cleanup's `find /opt/arlowe -name __pycache__ -exec rm -rf` will strip the
# venvs' bytecode caches. That is INTENDED — .pyc files embed timestamps and
# would break the SC5 input-reproducibility property — and it costs only
# first-start latency, once, while CPython regenerates them. Do not "fix" it.
# ---------------------------------------------------------------------------
echo "[00-run-chroot] step 7: build-venvs.sh"
bash "${REPO_ROOT}/pi-gen/stage-arlowe/01-runtime/files/build-venvs.sh"

# ---------------------------------------------------------------------------
# Build the dashboard into a standalone bundle at
# /opt/arlowe/runtime/dashboard/server.js — the path
# units/arlowe-dashboard.service names. Consumes the runtime rsync above (the
# source tree) and the staged third_party/node/manifest.yml (the interpreter),
# and like step 7 it must precede the cleanup that deletes the staged tree.
#
# It also replaces that directory with the built bundle, so it must run after
# anything that reads the dashboard SOURCE. Nothing currently does.
# ---------------------------------------------------------------------------
echo "[00-run-chroot] step 8: build-dashboard.sh"
bash "${REPO_ROOT}/pi-gen/stage-arlowe/01-runtime/files/build-dashboard.sh"

# ---------------------------------------------------------------------------
# Install the axcl deb.
# The deb path inside the chroot was written by the host-side 00-run.sh into
# /root/arlowe-build/repo/.axcl-deb-path. Fall back to scanning third_party/axcl/.
# ---------------------------------------------------------------------------
AXCL_DEB_PATH_FILE="${REPO_ROOT}/.axcl-deb-path"
if [[ -f "${AXCL_DEB_PATH_FILE}" ]]; then
    AXCL_DEB="$(cat "${AXCL_DEB_PATH_FILE}")"
else
    AXCL_DEB="$(find "${REPO_ROOT}/third_party/axcl" -name "*.deb" | head -1 || true)"
fi

if [[ -n "${AXCL_DEB}" ]] && [[ -f "${AXCL_DEB}" ]]; then
    echo "[00-run-chroot] installing axcl deb: ${AXCL_DEB}"
    # The axcl deb's maintainer scripts (a) modprobe/-r the Axera PCIe modules and
    # (b) COMPILE the driver against /lib/modules/$(uname -r)/build. In the build
    # chroot both misbehave: modprobe can't load modules, and $(uname -r) returns
    # the BUILD HOST kernel (not the image's), so the driver build targets a kernel
    # whose headers aren't present. We fix both for the duration of the install:
    #   - neuter modprobe → /bin/true (modules load at runtime on the real Pi via
    #     the deb-shipped /etc/modules-load.d/axcl_pcie.conf)
    #   - override `uname -r` to the image's Pi-5 (2712) kernel so the driver builds
    #     against the headers the image actually ships (present, with gcc/make).
    # NOTE: this builds+installs the driver correctly for the shipped kernel, but AX
    # NPU RUNTIME (module load + inference) is still validated later on real hardware
    # — deferred from the image build. A kernel update on-device would need a driver
    # rebuild (DKMS is the robust long-term answer; out of scope here).
    IMG_KVER="$(find /lib/modules -maxdepth 1 -name '*-rpi-2712' -printf '%f\n' 2>/dev/null | sort -V | tail -1)"
    dpkg-divert --local --rename --add /usr/sbin/modprobe >/dev/null 2>&1 || true
    ln -sf /bin/true /usr/sbin/modprobe
    _uname_overridden=0
    if [[ -n "${IMG_KVER}" ]]; then
        dpkg-divert --local --divert /usr/bin/uname.real --rename --add /usr/bin/uname >/dev/null 2>&1 || true
        cat > /usr/bin/uname <<EOF
#!/bin/sh
[ "\$1" = "-r" ] && { echo "${IMG_KVER}"; exit 0; }
exec /usr/bin/uname.real "\$@"
EOF
        chmod +x /usr/bin/uname
        # depmod calls the uname() SYSCALL (not the command), so the PATH shim
        # above doesn't reach it — wrap depmod to always target the image kernel.
        dpkg-divert --local --divert /usr/sbin/depmod.real --rename --add /usr/sbin/depmod >/dev/null 2>&1 || true
        cat > /usr/sbin/depmod <<EOF
#!/bin/sh
exec /usr/sbin/depmod.real -a "${IMG_KVER}"
EOF
        chmod +x /usr/sbin/depmod
        _uname_overridden=1
        echo "[00-run-chroot] axcl driver build targeting image kernel ${IMG_KVER}"
    else
        echo "[00-run-chroot] WARNING: could not determine image (2712) kernel; axcl driver build may fail" >&2
    fi
    _axcl_rc=0
    dpkg -i "${AXCL_DEB}" || _axcl_rc=$?
    if [[ "${_uname_overridden}" -eq 1 ]]; then
        rm -f /usr/bin/uname
        dpkg-divert --local --divert /usr/bin/uname.real --rename --remove /usr/bin/uname >/dev/null 2>&1 || true
        rm -f /usr/sbin/depmod
        dpkg-divert --local --divert /usr/sbin/depmod.real --rename --remove /usr/sbin/depmod >/dev/null 2>&1 || true
    fi
    rm -f /usr/sbin/modprobe
    dpkg-divert --local --rename --remove /usr/sbin/modprobe >/dev/null 2>&1 || true
    if [[ "${_axcl_rc}" -ne 0 ]]; then
        # The axcl postinst runs under `set -e`; after the driver builds it tries
        # runtime steps (cp .ko, depmod, then modprobe the modules) that can't fully
        # complete in a chroot, so it exits non-zero. That's expected. As long as the
        # driver .ko actually built, guarantee the image is correct ourselves:
        # install the built modules for the image kernel + depmod. They load at boot
        # via /etc/modules-load.d/axcl_pcie.conf. NPU runtime is validated on hardware
        # (deferred). NOTE: this leaves axclhost in a half-configured dpkg state — a
        # documented checkpoint caveat; proper install (DKMS/first-boot) is deferred.
        _ko_src=/usr/src/axcl/out/axcl_linux_arm64/ko
        if [[ -n "${IMG_KVER}" ]] && ls "${_ko_src}"/ax*.ko >/dev/null 2>&1; then
            install -d "/lib/modules/${IMG_KVER}/extra"
            cp -f "${_ko_src}"/ax*.ko "/lib/modules/${IMG_KVER}/extra/"
            depmod -a "${IMG_KVER}" || true
            echo "[00-run-chroot] WARNING: axcl postinst exited ${_axcl_rc} on in-chroot runtime-load steps; driver .ko built + installed for ${IMG_KVER}. NPU runtime deferred to hardware." >&2
        else
            echo "[00-run-chroot] ERROR: axcl driver .ko not found — real failure (rc=${_axcl_rc})" >&2
            exit "${_axcl_rc}"
        fi
    fi
    # 9. Run the axcl udev extraction diagnostic to confirm no rule conflict.
    echo "[00-run-chroot] step 9: extract-axcl-udev-from-deb.sh (diagnostic)"
    bash "${PROVISION}/extract-axcl-udev-from-deb.sh" "${AXCL_DEB}" || true
    # install-arlowe-udev-polkit.sh (step 5) already removes the broken deb rule;
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

# Staged build tree — must not ship in the image.
rm -rf /root/arlowe-build

echo "[00-run-chroot] provisioning complete"
