#!/usr/bin/env bash
# runtime/recovery/arlowe-recovery.sh
#
# Slot-B recovery action — runs as a systemd oneshot at boot when slot B
# is the active root (arlowe-recovery.service).
#
# Actions (in order):
#   1. Show a static recovery face on the Whisplay display
#   2. Print recovery state to serial console + journal
#   3. Reset the persistent default to slot A (rewrite root= in cmdline.txt)
#   4. After a brief delay, reboot so the device self-heals into slot A
#
# This script does NOT depend on the shared models partition (/opt/arlowe/models).
# The recovery face is a static framebuffer draw using only the WhisPlay driver.
# The models partition fstab entry in slot B is marked nofail — it is absent
# here by design and recovery must function without it.
#
# If the Pi 5 bootloader freezes on a corrupted kernel (a Pi 5 hardware
# characteristic — it does not auto-fall-back on bad kernels, it hangs):
#   power-cycle the device to recover.
set -euo pipefail

BOOT_MOUNT="${BOOT_MOUNT:-/boot/firmware}"
CMDLINE_FILE="${BOOT_MOUNT}/cmdline.txt"
PARTUUID_MAP="${PARTUUID_MAP:-/etc/arlowe/ab-partuuid-map}"
WHISPLAY_DRIVER_PATH="${ARLOWE_WHISPLAY_DRIVER_PATH:-/opt/arlowe/third_party/whisplay-driver}"

# Delay before self-reboot (seconds) — long enough for logs to flush.
RECOVERY_REBOOT_DELAY="${RECOVERY_REBOOT_DELAY:-15}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log_recovery() {
    # Write to both the journal (systemd captures stdout) and the serial console.
    local msg="[arlowe-recovery] $*"
    printf '%s\n' "${msg}"
    # /dev/ttyAMA0 is the Pi 5 primary UART (serial0 alias). Write best-effort;
    # if the console is not available, continue without failing.
    printf '%s\n' "${msg}" > /dev/ttyAMA0 2>/dev/null || true
}

mount_boot_rw() {
    mount -o remount,rw "${BOOT_MOUNT}"
}

mount_boot_ro() {
    mount -o remount,ro "${BOOT_MOUNT}" 2>/dev/null || true
}

lookup_partuuid_a() {
    [[ -f "${PARTUUID_MAP}" ]] || { log_recovery "PARTUUID map not found — cannot reset to slot A"; return 1; }
    local val
    val="$(grep '^PARTUUID_A=' "${PARTUUID_MAP}" | cut -d= -f2)"
    [[ -n "${val}" ]] || { log_recovery "PARTUUID_A not found in map"; return 1; }
    printf '%s' "${val}"
}

# Rewrite root=PARTUUID=<current> to root=PARTUUID=<slot-A> in cmdline.txt.
# Same logic as arlowe-ab set A — this shares the rewrite primitive.
reset_persistent_default_to_a() {
    local puuid_a
    puuid_a="$(lookup_partuuid_a)"

    local tmp="${CMDLINE_FILE}.tmp"
    [[ -f "${CMDLINE_FILE}" ]] || { log_recovery "cmdline.txt not found at ${CMDLINE_FILE}"; return 1; }

    sed "s|root=PARTUUID=[^ ]*|root=PARTUUID=${puuid_a}|" \
        "${CMDLINE_FILE}" > "${tmp}"
    mv "${tmp}" "${CMDLINE_FILE}"
    sync
    log_recovery "persistent default reset to slot A (root=PARTUUID=${puuid_a})"
}

# ---------------------------------------------------------------------------
# Step 1: Show recovery face on Whisplay
#
# Uses the vendored WhisPlay driver via a minimal inline Python call.
# Draws a static recovery indicator (red background + text) on the 240x280 LCD.
# Does NOT import runtime/face/face.py — keeps slot B's dependency surface tiny.
# ---------------------------------------------------------------------------
show_recovery_face() {
    if ! command -v python3 >/dev/null 2>&1; then
        log_recovery "python3 not found — skipping Whisplay recovery face"
        return 0
    fi

    python3 - "${WHISPLAY_DRIVER_PATH}" <<'PYEOF' 2>/dev/null || log_recovery "Whisplay face draw failed (non-fatal)"
import sys, os
driver_path = sys.argv[1]
if driver_path not in sys.path:
    sys.path.insert(0, driver_path)
try:
    from WhisPlay import WhisPlayBoard
    from PIL import Image, ImageDraw, ImageFont
    board = WhisPlayBoard()
    img = Image.new("RGB", (240, 280), (180, 30, 30))
    draw = ImageDraw.Draw(img)
    # Recovery indicator: bold warning text centered on the display
    draw.rectangle([10, 90, 230, 190], fill=(220, 60, 60))
    draw.text((120, 115), "RECOVERY", fill=(255, 255, 255), anchor="mm")
    draw.text((120, 145), "Resetting to slot A", fill=(230, 230, 230), anchor="mm")
    draw.text((120, 165), "Rebooting...", fill=(200, 200, 200), anchor="mm")
    board.ShowImage(img)
except Exception as e:
    print(f"face draw error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
    log_recovery "recovery face shown on Whisplay"
}

# ---------------------------------------------------------------------------
# Step 2: Print recovery state to serial + journal
# ---------------------------------------------------------------------------
print_recovery_state() {
    log_recovery "=== SLOT B RECOVERY MODE ==="
    log_recovery "hostname: $(hostname 2>/dev/null || echo unknown)"
    log_recovery "kernel:   $(uname -r 2>/dev/null || echo unknown)"
    log_recovery "uptime:   $(uptime 2>/dev/null || echo unknown)"

    if [[ -f "${CMDLINE_FILE}" ]]; then
        log_recovery "current cmdline.txt: $(cat "${CMDLINE_FILE}")"
    else
        log_recovery "cmdline.txt not readable at ${CMDLINE_FILE}"
    fi

    if [[ -f "${PARTUUID_MAP}" ]]; then
        log_recovery "PARTUUID map:"
        while IFS= read -r line; do
            log_recovery "  ${line}"
        done < "${PARTUUID_MAP}"
    else
        log_recovery "PARTUUID map not found at ${PARTUUID_MAP}"
    fi

    log_recovery "==========================="
}

# ---------------------------------------------------------------------------
# Main recovery sequence
# ---------------------------------------------------------------------------
log_recovery "recovery boot detected — starting recovery sequence"

show_recovery_face

print_recovery_state

log_recovery "resetting persistent default to slot A..."
mount_boot_rw
reset_persistent_default_to_a
mount_boot_ro

log_recovery "recovery complete; rebooting into slot A in ${RECOVERY_REBOOT_DELAY}s"
log_recovery "(if the device freezes after reboot, power-cycle to recover — Pi 5 does not auto-fall-back on a bad kernel)"
sleep "${RECOVERY_REBOOT_DELAY}"
systemctl reboot
