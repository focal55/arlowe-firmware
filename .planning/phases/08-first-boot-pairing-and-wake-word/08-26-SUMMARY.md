---
phase: 08-first-boot-pairing-and-wake-word
plan: 26
subsystem: pairing
tags: [pairing, e2e, broker, tls, factory-reset]
requires:
  - phase: 08-14
    provides: pair-commit
  - phase: 08-15
    provides: broker.py --stub-iot, --stub-fail issuance
  - phase: 08-18
    provides: resolve_broker, factory-reset revoke step
  - phase: 08-19
    provides: POST /v1/certificates/revoke
  - phase: 08-23
    provides: build_app, pair.__main__.broker_source
provides:
  - tests/phase-8/e2e_harness.py World (temp root, shims, TLS broker, app runner, reset runner)
  - SC2 and SC3 proven in software in pair-bookworm
affects: [08-27b hardware checkpoint]
key-files:
  created: [tests/phase-8/e2e_harness.py, tests/phase-8/test_pairing_e2e.py]
  modified: [runtime/pair/tests/fixtures/fake-nmcli]
key-decisions:
  - "The real Display runs on a fake board, so every screen is actually rendered; only its text is recorded"
  - "One events file shared by the systemctl/hostnamectl/journalctl shims and the display gives the handoff order"
duration: 35min
completed: 2026-09-29
---

# Phase 8 Plan 26: Pairing E2E Summary

**A form POSTed to the real portal drives the real PairingFlow, the real `arlowe-identity` CLI and a real TLS `broker.py --stub-iot` to a stub-CA-signed certificate. The test then checks the hostname commit through the real `pair-commit`, a config.yml that passes validation, an Argon2 owner credential, and the paired screen, `display.close()` and one `start --no-block` of the six, in that order. All four SC3 failures, the resubmit, and a factory reset that revokes against the same TLS broker through the FAT broker file also pass. 8 tests take 24 s in a bookworm container with the image's packages.**

## Tasks
1. Harness and SC2 happy path (c086cc2)
2. SC3 failure matrix, resubmit, reset revoke, secret scan (04f6f47)
- Fixture fix: fake nmcli bare-uuid selectors (1cdc515)

## Verification
- `pytest tests/phase-8/test_pairing_e2e.py -q --import-mode=importlib` in debian:bookworm with the 00-packages-nr Python set, python3-pytest and python3-botocore: 8 passed in 23.5 s
- `runtime/pair/tests` + `tests/phase-8`, same container: 182 passed, 2 skipped
- pyflakes3 clean; `scripts/sanitize/check.sh` clean

## Deviations from Plan

**1. [Rule 3 - Blocking] fake nmcli could not delete by bare uuid.** factory-reset runs `nmcli connection delete <uuid> <uuid>...`. Real nmcli accepts that. The fake matched a bare selector only against names and removed only the first one, so the reset aborted. It now matches a bare selector against uuid or name and deletes each argument. runtime/pair tests still pass.

**2. The pairing half uses `pair.__main__.broker_source` with `BROKER_FILE` and `RUN_DIR` monkeypatched into the temp root.** The resolver's file path is therefore exercised for pairing as well as reset. `device_id_reader` reads the temp identity store directly, because `arlowe_identity.DEVICE_ID_PATH` is fixed when the module is imported.

**3. The flow gets `sleep=lambda s: None`**, which skips the 2 s HANDOFF_DELAY_S on each submission. The portal still answers before the thread starts.

**4. No `sync` shim.** factory-reset calls `os.sync()`, not a `sync` binary.

**5. "Same session PSK" on AP restore** is checked through the argv and the daemon's session, not against the PSK value itself. The fake nmcli never stores a passwd-file secret. The test checks that the last action on the AP uuid is `up ... passwd-file /dev/stdin`, that the add's `ssid` is the session SSID, that `secret_supplied` is true, and that `app.session` is unchanged.

**6. The waiting screen's text is shortened to its title in the events log.** The panel shows the session PSK by design (ADR-0011), and the secret scan caught the harness writing it to the log.

## Next Phase Readiness
08-27b only has to prove the radio (the brcmfmac reason codes for a wrong PSK), the panel, the phone and systemd. The portal socket surviving AP down/up on real wlan0 is still unproven here: this test binds 127.0.0.1.
