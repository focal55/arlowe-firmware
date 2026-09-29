#!/usr/bin/env bash
# Static checks on the Phase 8 network substrate: the NetworkManager polkit
# grant, captive DNS, the setup-AP forward drop, its installer, the radio-init
# unit and the package declarations.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "${REPO_ROOT}" || exit 1

RULE=provision/polkit/51-arlowe-networkmanager.rules
DNSMASQ=provision/networkmanager/dnsmasq-shared.d/arlowe-captive.conf
NFT=provision/nftables/arlowe-setup-ap.nft
INSTALLER=scripts/provision/install-arlowe-network.sh
UNIT=units/arlowe-radio-init.service
PKGS=pi-gen/stage-arlowe/00-packages/00-packages-nr

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILURES=0

check() {
  local tag="$1" name="$2"; shift 2
  if "$@" >/dev/null 2>&1; then
    echo "PASS [${tag}] ${name}"
  else
    echo "FAIL [${tag}] ${name}" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

# --- polkit ------------------------------------------------------------------
actions_in_rule() {
  grep -o '"org\.freedesktop\.NetworkManager\.[a-z.-]*"' "${RULE}" | tr -d '"' | sort
}
expected_actions() {
  printf 'org.freedesktop.NetworkManager.%s\n' network-control \
    settings.modify.system wifi.share.protected wifi.scan enable-disable-wifi | sort
}
check polkit-actions "rule names exactly the five pairing actions" \
  diff <(actions_in_rule) <(expected_actions)
check polkit-actions "rule returns early for any user but arlowe" \
  grep -qE 'subject\.user !== "arlowe"\) return' "${RULE}"
check polkit-actions "rule does not grant an open AP" \
  bash -c "test -f '${RULE}' && ! grep -q 'share.open' '${RULE}'"

# --- captive DNS -------------------------------------------------------------
check dnsmasq-conf "conf is exactly address=/#/10.42.0.1" \
  diff <(printf 'address=/#/10.42.0.1\n') "${DNSMASQ}"

# --- setup-AP forward drop ---------------------------------------------------
check nft "ruleset hooks forward" grep -q 'hook forward' "${NFT}"
check nft "ruleset drops traffic entering from wlan0" grep -q 'iifname "wlan0" drop' "${NFT}"
check nft "ruleset drops traffic leaving to wlan0" grep -q 'oifname "wlan0" drop' "${NFT}"
if ! command -v nft >/dev/null 2>&1; then
  echo "SKIP [nft] nft not installed; syntax check not run"
elif ! unshare -rn true >/dev/null 2>&1; then
  echo "SKIP [nft] unshare -rn not permitted; syntax check not run"
else
  check nft "nft -c accepts the ruleset" unshare -rn nft -c -f "${NFT}"
fi

# --- installer ---------------------------------------------------------------
DEST="${WORK}/dest"
check install "installer runs with DESTDIR" env DESTDIR="${DEST}" bash "${INSTALLER}"
check install "installer is idempotent" env DESTDIR="${DEST}" bash "${INSTALLER}"
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
for f in etc/NetworkManager/dnsmasq-shared.d/arlowe-captive.conf \
         etc/modprobe.d/arlowe-wifi-regdom.conf \
         etc/arlowe/nftables/arlowe-setup-ap.nft; do
  check install "${f} installed 0644" test "$(mode_of "${DEST}/${f}")" = 644
done

# --- unit --------------------------------------------------------------------
has() { grep -qx "$1" "${UNIT}"; }
check unit "Type=oneshot" has 'Type=oneshot'
check unit "runs as root" bash -c "test -f '${UNIT}' && ! grep -E '^User=' '${UNIT}' | grep -vqx 'User=root'"
check unit "After=NetworkManager.service" has 'After=NetworkManager.service'
check unit "Before=arlowe-pair.service" has 'Before=arlowe-pair.service'
check unit "WantedBy=multi-user.target" has 'WantedBy=multi-user.target'
check unit "no ConditionPathExists (paired units need the radio too)" \
  bash -c "test -f '${UNIT}' && ! grep -q '^ConditionPathExists' '${UNIT}'"
check unit "ExecStart uses the declared python3" \
  has 'ExecStart=/usr/bin/python3 /opt/arlowe/runtime/cli/radio-init'

# --- packages ----------------------------------------------------------------
for p in iw wireless-regdb nftables; do
  check packages "00-packages-nr declares ${p}" grep -qx "${p}" "${PKGS}"
done

if [[ "${FAILURES}" -gt 0 ]]; then
  echo "${FAILURES} check(s) failed" >&2
  exit 1
fi
echo "all network substrate checks passed"
