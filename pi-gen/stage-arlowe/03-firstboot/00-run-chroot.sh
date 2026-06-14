#!/bin/bash
# Chroot step: install the arlowe-firstboot.service unit and enable it so it
# runs ONCE on first boot, then disables itself via a sentinel file.
#
# The pairing daemon itself is Phase 8. This hook only brings the device to
# "armed / ready to pair" state:
#   (a) confirms /etc/arlowe/config.yml is ABSENT (CONFIG-03 pairing trigger)
#   (b) logs "ready to pair" to the journal
#   (c) is the seam for plan 06-04's models partition grow-to-fill resize hook
#       (the resize happens BEFORE the models partition is mounted ro, per 06-04's wiring)
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
