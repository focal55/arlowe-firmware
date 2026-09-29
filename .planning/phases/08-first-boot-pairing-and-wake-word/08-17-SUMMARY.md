---
phase: 08-first-boot-pairing-and-wake-word
plan: 17
subsystem: docs
tags: [runbook, pairing, factory-reset, hardware-checkpoint]
requires:
  - phase: 08-first-boot-pairing-and-wake-word
    provides: ADR-0011..0013 (08-01), claim_codes.py (08-05), stub_iot.py tls (08-15b), factory-reset (08-10), radio-init (08-08)
provides:
  - docs/operations/phase-8-pairing.md (operator runbook and 08-27b evidence template)
affects: [08-15 README section, 08-18 reset units, 08-27b hardware checkpoint]
key-files:
  created: [docs/operations/phase-8-pairing.md]
  modified: []
key-decisions:
  - "SSH key goes into the image on the build host (rw loop-mount + mandatory bmap regeneration); the Mac cannot write ext4"
  - "No-saved-profile check uses 08-27b's definition, not a bare 802-11-wireless count"
duration: 25min
completed: 2026-09-29
---

# Phase 8 Plan 17: Pairing Runbook Summary

**Operator runbook for the Phase 8 hardware checkpoint: build and key staging, Mac-slot flash with read-back, local stub broker and `arlowe-broker.json`, SC1-SC4 steps with the ADR-0011 error strings, all three reset triggers including the recovery-SD reflash and its operator release, diagnostics, and an SC-by-SC evidence template.**

## Task Commits

1. **Task 1: Write the runbook** - `b3c45da` (docs)

## Verification

- `grep -c arlowe-broker.json` 5, `grep -c claim_rejected` 2, `grep -ci 'recovery SD'` 2, `grep -c 0013` 2
- `scripts/sanitize/check.sh` clean (grep and units gates, file staged so it was scanned)
- Size: 323 lines for the runbook (estimate 240)
- No step has run on hardware; that is 08-27b.

## Deviations from Plan

1. **[Rule 1 - Bug] SC3 "no saved profile" check.** The plan's check (`nmcli -t -f TYPE connection show` lists no `802-11-wireless`) fails on a correct unit, because the in-memory `arlowe-setup` AP profile is listed whenever the waiting screen is up. Used 08-27b's definition: no `type=wifi` keyfile under `/etc/NetworkManager/system-connections`, and only `arlowe-setup` in `nmcli`.
2. **FAT `ssh` file dropped as a requirement.** `pi-gen/config` sets `ENABLE_SSH=1`, so `ssh.service` is already enabled; the runbook says the file is unnecessary but harmless. 08-27b Task 1 still lists it; no harm either way.
3. **Key staging location.** The plan did not say where the `/etc/skel` key is written. The Mac cannot write ext4 and the USB reader corrupts writes, so the runbook stages it into the image on the build host and regenerates the `.bmap` (a rw mount desyncs it).
4. **Stub broker state warning added.** `StubIoT` keeps certificates in memory, so any broker restart between a pairing and its reset makes the revoke fail and orphan. The runbook confines restarts to SC3's issuance failure.
5. **Journal secret check** also covers the setup-AP session PSK, not only the home PSK, dashboard password and claim code.
6. Size 323 vs 240 estimated; mostly the broker, flash and reset command blocks.

## Notes for later plans

- 08-15 README must gain the "Local broker for pairing tests" section the runbook links to, with the flags used here: `--stub-iot --stub-ca-dir DIR --host 0.0.0.0 --certfile --keyfile`, env `ARLOWE_BROKER_CLAIM_CODES`, and `--stub-fail issuance`.
- The dashboard reset control's label (08-11) is unknown; the runbook says "the dashboard's factory-reset control". 08-27b corrects if needed.
