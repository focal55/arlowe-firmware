#!/bin/bash
# Phase 3 SC4 assertion: udev + polkit rule file shape.
#
# Validates that the three rule files are installed at expected system paths
# with expected permissions. Checks polkit JS syntax if node is available.
#
# Limitation: udev rule application to device nodes requires a running udev
# daemon, which does not fire in Docker containers. This script validates file
# installation only. Plan 03-05 owns real-hardware verification on the device.
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- File presence ---

test -f /etc/udev/rules.d/90-arlowe-axera.rules \
    || fail "axera udev rule not installed at /etc/udev/rules.d/90-arlowe-axera.rules"

test -f /etc/udev/rules.d/91-arlowe-gpio-spi.rules \
    || fail "gpio/spi udev rule not installed at /etc/udev/rules.d/91-arlowe-gpio-spi.rules"

test -f /etc/polkit-1/rules.d/50-arlowe-systemctl.rules \
    || fail "polkit rule not installed at /etc/polkit-1/rules.d/50-arlowe-systemctl.rules"

# --- File modes (udev and polkit rules must be 0644) ---

test "$(stat -c '%a' /etc/udev/rules.d/90-arlowe-axera.rules)" = "644" \
    || fail "90-arlowe-axera.rules mode is not 644"

test "$(stat -c '%a' /etc/udev/rules.d/91-arlowe-gpio-spi.rules)" = "644" \
    || fail "91-arlowe-gpio-spi.rules mode is not 644"

test "$(stat -c '%a' /etc/polkit-1/rules.d/50-arlowe-systemctl.rules)" = "644" \
    || fail "50-arlowe-systemctl.rules mode is not 644"

# --- Polkit rule: JS syntax check ---
# node's parser is not identical to polkit's SpiderMonkey but catches real
# JS parse errors. Skip gracefully if node is absent.
# Node v12+ ESM rejects unknown extensions; copy to a .js temp file to work
# around the ERR_UNKNOWN_FILE_EXTENSION error on the .rules extension.
if command -v node >/dev/null 2>&1; then
    _polkit_tmp=$(mktemp /tmp/polkit-check-XXXXXX.js)
    cp /etc/polkit-1/rules.d/50-arlowe-systemctl.rules "${_polkit_tmp}"
    node --check "${_polkit_tmp}" || { rm -f "${_polkit_tmp}"; fail "polkit rule JS syntax error (node --check)"; }
    rm -f "${_polkit_tmp}"
fi

# --- Polkit rule content: required strings ---

grep -q "org.freedesktop.systemd1.manage-units" /etc/polkit-1/rules.d/50-arlowe-systemctl.rules \
    || fail "polkit rule does not reference org.freedesktop.systemd1.manage-units"

grep -q '"arlowe"' /etc/polkit-1/rules.d/50-arlowe-systemctl.rules \
    || fail "polkit rule does not reference arlowe user"

# --- Polkit rule content: banned literals ---
# The rule must not embed any personal identity or host-specific references.
if grep -qE 'focal55|/home/focal55|casa_ybarra|iol-monorepo' /etc/polkit-1/rules.d/50-arlowe-systemctl.rules; then
    fail "polkit rule contains a banned identity literal"
fi

# --- GPIO/SPI udev rule coverage ---

grep -q 'gpiochip0' /etc/udev/rules.d/91-arlowe-gpio-spi.rules \
    || fail "91-arlowe-gpio-spi.rules does not cover gpiochip0"

grep -q 'gpiochip4' /etc/udev/rules.d/91-arlowe-gpio-spi.rules \
    || fail "91-arlowe-gpio-spi.rules does not cover gpiochip4"

# --- Axera udev rule coverage ---

grep -q 'axcl_host' /etc/udev/rules.d/90-arlowe-axera.rules \
    || fail "90-arlowe-axera.rules does not cover axcl_host"

grep -q 'ax_mmb_dev' /etc/udev/rules.d/90-arlowe-axera.rules \
    || fail "90-arlowe-axera.rules does not cover ax_mmb_dev"

# plan 03-05 found the axcl deb also exposes msg_userdev + p2p; cover all four.
grep -q 'msg_userdev' /etc/udev/rules.d/90-arlowe-axera.rules \
    || fail "90-arlowe-axera.rules does not cover msg_userdev"

grep -q 'p2p' /etc/udev/rules.d/90-arlowe-axera.rules \
    || fail "90-arlowe-axera.rules does not cover p2p"

# all four nodes must be root:arlowe 0660 (not the deb's world-writable 0666)
grep -qE 'GROUP="arlowe", *MODE="0660"' /etc/udev/rules.d/90-arlowe-axera.rules \
    || fail "90-arlowe-axera.rules does not set GROUP=arlowe MODE=0660"

echo "[04-udev-polkit-shape] PASS (file shape only; runtime application verified in plan 05)"
