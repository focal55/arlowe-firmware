---
phase: 08-first-boot-pairing-and-wake-word
plan: 08
subsystem: infra
tags: [networkmanager, polkit, rfkill, nftables, dnsmasq, systemd]
requires:
  - phase: 07.1-runtime-substrate
    provides: install-units.sh WantedBy linking, verify-unit-execstart python3 floor
provides:
  - arlowe-radio-init.service (root oneshot, every boot)
  - 51-arlowe-networkmanager.rules (five NM actions for arlowe)
  - captive dnsmasq conf, cfg80211 regdomain conf, inet arlowe_setup forward drop
affects: [08-14 pairing units, 08-27b hardware verification, dashboard Wi-Fi routes]
key-files:
  created: [runtime/cli/radio-init, units/arlowe-radio-init.service, provision/polkit/51-arlowe-networkmanager.rules, provision/nftables/arlowe-setup-ap.nft, scripts/provision/install-arlowe-network.sh]
  modified: [pi-gen/stage-arlowe/01-runtime/00-run-chroot.sh, pi-gen/stage-arlowe/00-packages/00-packages-nr, tests/phase-07.1/test-verify-unit-execstart.sh]
key-decisions:
  - "Every radio-init step is fatal, not only the firewall load"
  - "wlan0 absent from nmcli counts as not ready, same as unavailable"
duration: 45min
completed: 2026-09-29
---

# Phase 8 Plan 08: Network Substrate Summary

**Root radio-init oneshot (sysfs rfkill unblock, `iw reg set US`, `nmcli radio wifi on`, `nft -f` of a wlan0 forward drop), a five-action NetworkManager polkit grant for `arlowe`, and captive DNS, all installed by chroot step 5b.**

## Task Commits

1. **Task 1: Substrate cases (RED)** - `6d85761` (test)
2. **Task 2: radio-init, unit, polkit rule, conf files, installer (GREEN)** - `d6cdc47` (feat)

## Verification

- `pytest tests/phase-8/test_radio_init.py`: 6 passed (macOS and debian:bookworm).
- `tests/phase-8/test-network-substrate.sh`: all pass; its `nft -c` case skips on macOS (no nft).
- Ruleset in debian:bookworm amd64, nftables 1.0.6: `nft -c -f` accepts it; `nft -f` twice succeeds (the reload is idempotent); `nft list table inet arlowe_setup` shows both drops.
- `systemd-analyze verify` on the unit (bookworm systemd 252): rc 0.
- `tests/phase-07.1/test-verify-unit-execstart.sh` (bookworm container, needs bash 4): all cases pass after the fixture change below.
- Polkit rule evaluated under node with a mocked `polkit`: YES for the five actions for `arlowe`; no decision for `wifi.share.open`, other NM actions, and other users.
- shellcheck clean on the installer, the substrate test and the chroot script. `scripts/sanitize/check.sh` clean.
- Hardware only, not run: `systemd-run --uid=arlowe --pipe nmcli general permissions`, `lsmod | grep cfg80211`, `iw reg get`, `sudo nft list table inet arlowe_setup` (08-27b).

## Deviations from Plan

**1. [Rule 3 - Blocking] execstart self-test fixture updated**
- **Found during:** Task 2.
- **Issue:** `test-verify-unit-execstart.sh` copies the real `units/*.service` into its fixture rootfs. The new unit names `/usr/bin/python3` and `runtime/cli/radio-init`, neither present in the fixture, so `repaired-image`, `node20-ok` and `python-ok` failed.
- **Fix:** the `prefix-image` fixture now creates `/usr/bin/python3` and `/opt/arlowe/runtime/cli/radio-init`. The failing-direction cases still fail for the reasons they assert.
- **Commit:** `d6cdc47`.

**2. The polkit header does not contain the string `share.open`.** The plan's own check forbids it anywhere in the file, so the header says "the open-AP action is deliberately not granted".

**3. `install-arlowe-network.sh` passes `-o root -g root` only when EUID is 0**, so the DESTDIR self-test runs unprivileged.

**4. Chroot step is numbered 5b** (header list updated too), so steps 6-10 keep their numbers.

## Next Phase Readiness

- `Before=arlowe-pair.service` is ordering only. If 08-14 wants pairing to refuse to start when the radio or firewall failed, it needs `Requires=arlowe-radio-init.service` on `arlowe-pair.service`.
- `ProtectKernelModules=yes` stays; if `nft` reports a missing `nf_tables` family on hardware, set it to `no` (08-27b).
- The staging installer sed-transforms every unit and polkit rule, so a staging install also gets `arlowe-staging-radio-init`, which loads the wlan0 forward drop on that host.

---
*Phase: 08-first-boot-pairing-and-wake-word*
*Completed: 2026-09-29*
