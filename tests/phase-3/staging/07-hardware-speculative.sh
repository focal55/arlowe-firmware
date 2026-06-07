#!/bin/bash
# Phase 3 speculative-hardware resolution (research §12). Answers, on real hardware:
#   - Does arlowe-staging actually need the dialout / video groups?
#   - Can arlowe-staging open each hardware device per its udev rule + groups?
#   - Which gpiochip does the WhisPlay face driver open (0, 4, or both)?
#
# -e is intentionally omitted: this script probes optional hardware and individual
# checks are expected to fail on a board lacking a given device. We want the full
# report regardless, not an abort on the first miss.
#
# PREREQUISITE (see README): stop the daily-driver face service first — it holds
# the SPI/GPIO hardware exclusively, so the staging face service can't acquire it
# while it runs.
#
# Run on the dev Pi as root, after the staging install has run.
set -uo pipefail

SVC_USER=arlowe-staging

echo "=== group membership for $SVC_USER ==="
for grp in audio gpio spi dialout video; do
    if id -nG "$SVC_USER" 2>/dev/null | grep -qw "$grp"; then
        echo "  $grp: granted"
    else
        echo "  $grp: NOT granted"
    fi
done

echo ""
echo "=== device-node enumeration ==="
for dev in /dev/snd /dev/gpiochip0 /dev/gpiochip4 /dev/gpiomem \
           /dev/spidev0.0 /dev/spidev0.1 /dev/axcl_host /dev/ax_mmb_dev /dev/fb0; do
    if [[ -e "$dev" ]]; then ls -ld "$dev"; else echo "  $dev: absent"; fi
done

echo ""
echo "=== can $SVC_USER read+write each present device? ==="
for dev in /dev/gpiochip0 /dev/gpiochip4 /dev/gpiomem /dev/spidev0.0 \
           /dev/axcl_host /dev/ax_mmb_dev /dev/fb0; do
    [[ -e "$dev" ]] || continue
    if sudo -u "$SVC_USER" -- bash -c "test -r '$dev' && test -w '$dev'"; then
        echo "  $dev: read+write OK"
    else
        echo "  $dev: NOT accessible (group/udev gap?)"
    fi
done

echo ""
echo "=== WhisPlay: which gpiochip does the face driver open? ==="
if sudo systemctl start arlowe-staging-face.service 2>/dev/null; then
    sleep 5
    pid=$(pgrep -u "$SVC_USER" -f 'face' | head -1 || true)
    if [[ -n "$pid" ]]; then
        echo "  arlowe-staging-face running (pid $pid); open hardware fds:"
        sudo lsof -p "$pid" 2>/dev/null | grep -E '/dev/(gpiochip|spidev|snd|fb)' \
            || echo "    (no hardware fds — driver may not have initialized)"
    else
        echo "  started but no process found (likely missing venv/deps on a non-image Pi)"
    fi
    sudo systemctl stop arlowe-staging-face.service 2>/dev/null || true
else
    echo "  arlowe-staging-face did not start — expected on a non-image Pi (no venv)."
    echo "  Inspect: journalctl -u arlowe-staging-face.service -n 30 --no-pager"
fi

echo ""
echo "[07-hardware-speculative] report complete — fold findings into docs/operations/phase-3-staging.md"
