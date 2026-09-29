#!/bin/bash
# Installs the Phase 8 network substrate files. Idempotent; honours DESTDIR.
#
#   dnsmasq-shared.d/arlowe-captive.conf  captive DNS for the setup AP.
#       NetworkManager passes --conf-dir to its shared-mode dnsmasq only if the
#       directory exists, so the directory itself is load-bearing.
#   modprobe.d/arlowe-wifi-regdom.conf    cfg80211 regulatory domain.
#   arlowe/nftables/arlowe-setup-ap.nft   setup-AP forward drop, loaded by
#       radio-init every boot (ADR-0011).
#
# The polkit rule for NetworkManager is installed by install-arlowe-udev-polkit.sh
# with the other provision/polkit/*.rules.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${REPO_ROOT}/provision"
DEST="${DESTDIR:-}"

# Ownership flags only as root, so the DESTDIR self-test runs unprivileged.
OWN=()
[[ "${EUID}" -eq 0 ]] && OWN=(-o root -g root)

install -d -m 0755 "${DEST}/etc/NetworkManager/dnsmasq-shared.d" \
                   "${DEST}/etc/modprobe.d" \
                   "${DEST}/etc/arlowe/nftables"

install -m 0644 ${OWN[@]+"${OWN[@]}"} "${SRC}/networkmanager/dnsmasq-shared.d/arlowe-captive.conf" \
    "${DEST}/etc/NetworkManager/dnsmasq-shared.d/arlowe-captive.conf"
install -m 0644 ${OWN[@]+"${OWN[@]}"} "${SRC}/modprobe/arlowe-wifi-regdom.conf" \
    "${DEST}/etc/modprobe.d/arlowe-wifi-regdom.conf"
install -m 0644 ${OWN[@]+"${OWN[@]}"} "${SRC}/nftables/arlowe-setup-ap.nft" \
    "${DEST}/etc/arlowe/nftables/arlowe-setup-ap.nft"

echo "[install-network] installed captive DNS, regdomain and setup-AP firewall files"
