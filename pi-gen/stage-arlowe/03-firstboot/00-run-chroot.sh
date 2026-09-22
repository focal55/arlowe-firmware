#!/bin/bash
# Chroot step. Installs and enables the units a factory device needs on its
# very first boot:
#   1. arlowe-firstboot.service   — runs ONCE, then disables itself via a
#                                   sentinel file
#   2. arlowe-grow-models         — the grow script firstboot's ExecStartPre calls
#   3. arlowe-identity-init.service — device-id + keypair + CSR (Phase 7, SC2)
#
# The pairing daemon itself is Phase 8. This hook only brings the device to
# "armed / ready to pair" state:
#   (a) confirms /etc/arlowe/config.yml is ABSENT (CONFIG-03 pairing trigger)
#   (b) logs "ready to pair" to the journal
#   (c) is the seam for plan 06-04's models partition grow-to-fill resize hook
#       (the resize happens BEFORE the models partition is mounted ro, per 06-04's wiring)
#   (d) enables arlowe-identity-init.service so the device has an identity
#       before anyone pairs it
#
# The models partition is read-only at runtime in v1. The first-boot grow
# (resize2fs of the models partition device) happens once here via the resize
# hook (plan 06-04 wires this), before the ro mount, against the partition
# device directly.
set -euo pipefail

# The service file was placed by pi-gen's files/ copy convention.
# pi-gen copies files/ into the rootfs at the same relative path as the stage
# sub-directory. For 03-firstboot/files/arlowe-firstboot.service, pi-gen puts
# it at /files/arlowe-firstboot.service in the chroot — we copy to the right
# destination manually.
#
# Fallback: look in several candidate locations in case pi-gen layout differs.
SERVICE_NAME="arlowe-firstboot.service"
CANDIDATES=(
    "/files/${SERVICE_NAME}"
    "/tmp/arlowe-build/repo/pi-gen/stage-arlowe/03-firstboot/files/${SERVICE_NAME}"
)

SERVICE_SRC=""
for cand in "${CANDIDATES[@]}"; do
    if [[ -f "${cand}" ]]; then
        SERVICE_SRC="${cand}"
        break
    fi
done

if [[ -z "${SERVICE_SRC}" ]]; then
    # pi-gen may place stage files under /stage-files or inject them differently
    # depending on version. Embed the unit inline as the authoritative fallback.
    echo "[03-firstboot] service file not found via files/ convention — writing inline"
    SERVICE_SRC="/tmp/${SERVICE_NAME}"
    cat > "${SERVICE_SRC}" <<'UNIT'
[Unit]
Description=Arlowe first-boot initialization
After=local-fs.target systemd-remount-fs.service
Before=multi-user.target
ConditionPathExists=!/var/lib/arlowe/.firstboot-done

[Service]
Type=oneshot
RemainAfterExit=no
ExecStart=/opt/arlowe/runtime/cli/boot-check --first-boot
ExecStartPost=/bin/touch /var/lib/arlowe/.firstboot-done
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
fi

install -m 0644 -o root -g root "${SERVICE_SRC}" \
    "/etc/systemd/system/${SERVICE_NAME}"

# Enable via a wants symlink — systemctl enable does not work in chroot without
# a running systemd (systemd is not PID 1 here). The symlink is equivalent.
install -d -m 0755 /etc/systemd/system/multi-user.target.wants
ln -sf "/etc/systemd/system/${SERVICE_NAME}" \
    "/etc/systemd/system/multi-user.target.wants/${SERVICE_NAME}"

echo "[03-firstboot] ${SERVICE_NAME} installed and enabled"

# ---------------------------------------------------------------------------
# arlowe-userconf: headless account provisioning from /boot/firmware/userconf.txt
#
# The factory image ships no login account, which is correct -- the device is
# paired, not logged into. But it also meant every hardware test cycle required
# hand-editing cmdline.txt on the card to get a shell, and that userconf.txt did
# nothing on a flashed image, because pi-gen's userconfig.service is not enabled
# here. Enabling pi-gen's is the wrong fix: with no userconf.txt present it runs
# an interactive wizard on tty1 and masks getty, so a device with no keyboard
# attached waits at a prompt forever. This unit is a no-op when the file is
# absent, so the factory default is unchanged.
# ---------------------------------------------------------------------------
# Same files/ convention as the service above: pi-gen copies the stage's files/
# into the chroot at /files/. The repo path is a fallback for a manual run.
USERCONF_UNIT="arlowe-userconf.service"
USERCONF_SRC=""
USERCONF_UNIT_SRC=""
for base in /files /tmp/arlowe-build/repo/pi-gen/stage-arlowe/03-firstboot/files; do
    if [[ -f "${base}/arlowe-userconf" && -f "${base}/${USERCONF_UNIT}" ]]; then
        USERCONF_SRC="${base}/arlowe-userconf"
        USERCONF_UNIT_SRC="${base}/${USERCONF_UNIT}"
        break
    fi
done

if [[ -n "${USERCONF_SRC}" && -n "${USERCONF_UNIT_SRC}" ]]; then
    install -d -m 0755 /opt/arlowe/runtime/cli
    install -m 0755 -o root -g root "${USERCONF_SRC}" /opt/arlowe/runtime/cli/arlowe-userconf
    install -m 0644 -o root -g root "${USERCONF_UNIT_SRC}" "/etc/systemd/system/${USERCONF_UNIT}"
    install -d -m 0755 /etc/systemd/system/multi-user.target.wants
    ln -sf "/etc/systemd/system/${USERCONF_UNIT}" \
        "/etc/systemd/system/multi-user.target.wants/${USERCONF_UNIT}"
    echo "[03-firstboot] ${USERCONF_UNIT} installed and enabled"
else
    echo "[03-firstboot] ERROR: arlowe-userconf sources not found under /files or the repo fallback" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Install arlowe-grow-models.sh to the CLI path the service references.
# The service calls /opt/arlowe/runtime/cli/arlowe-grow-models, which is
# created here as a copy of the grow script (not a symlink — the grow script
# must be self-contained and not depend on the repo tree at runtime).
# ---------------------------------------------------------------------------
GROW_SCRIPT_NAME="arlowe-grow-models"
GROW_CANDIDATES=(
    "/files/arlowe-grow-models.sh"
    "/tmp/arlowe-build/repo/pi-gen/stage-arlowe/03-firstboot/files/arlowe-grow-models.sh"
)

GROW_SRC=""
for cand in "${GROW_CANDIDATES[@]}"; do
    if [[ -f "${cand}" ]]; then
        GROW_SRC="${cand}"
        break
    fi
done

if [[ -n "${GROW_SRC}" ]]; then
    install -m 0755 -o root -g root "${GROW_SRC}" \
        "/opt/arlowe/runtime/cli/${GROW_SCRIPT_NAME}"
    echo "[03-firstboot] ${GROW_SCRIPT_NAME} installed to /opt/arlowe/runtime/cli/"
else
    echo "[03-firstboot] WARNING: arlowe-grow-models.sh not found — grow script not installed" >&2
    echo "[03-firstboot]   The firstboot service ExecStartPre= will fail without it." >&2
fi

# ---------------------------------------------------------------------------
# Enable arlowe-identity-init.service.
#
# DELIBERATELY ENABLED, unlike the six runtime units (face, voice, dashboard,
# qwen-api, qwen-tokenizer, whisper-stt), which ship installed-but-disabled
# because Phase 8's pairing daemon starts them after pairing. This one must run
# on a factory device BEFORE any pairing: SC2 requires that a device boots and
# derives its device-id, keypair and CSR with no human, no network and no
# account. Do not "fix" it to match its siblings.
#
# units/install-units.sh put the file in /etc/systemd/system earlier in the
# chain (01-runtime step 4). Verify that before linking: systemd silently
# IGNORES a wants symlink whose target unit is missing — no error, no failure
# state, the unit simply never runs. That is the same silent-no-op class as
# F7 #18 (stage-root package list) and #21 (dangling CLI symlink), and it would
# leave a shipped device with no identity and nothing to say so.
# ---------------------------------------------------------------------------
IDENTITY_UNIT="arlowe-identity-init.service"
IDENTITY_UNIT_PATH="/etc/systemd/system/${IDENTITY_UNIT}"

if [[ ! -f "${IDENTITY_UNIT_PATH}" ]]; then
    echo "[03-firstboot] ERROR: ${IDENTITY_UNIT_PATH} is missing." >&2
    echo "[03-firstboot]   units/install-units.sh (01-runtime step 4) should have" >&2
    echo "[03-firstboot]   installed it from units/${IDENTITY_UNIT}." >&2
    echo "[03-firstboot]   Refusing to create a wants symlink to a missing unit:" >&2
    echo "[03-firstboot]   systemd ignores those silently and the device would" >&2
    echo "[03-firstboot]   ship with no device identity (SC2)." >&2
    exit 1
fi

install -d -m 0755 /etc/systemd/system/multi-user.target.wants
ln -sf "${IDENTITY_UNIT_PATH}" \
    "/etc/systemd/system/multi-user.target.wants/${IDENTITY_UNIT}"

echo "[03-firstboot] ${IDENTITY_UNIT} enabled"
