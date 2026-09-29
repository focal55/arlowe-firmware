---
phase: 08-first-boot-pairing-and-wake-word
plan: 18
subsystem: reset
tags: [factory-reset, revoke, broker, systemd, tdd]
requires:
  - phase: 08-first-boot-pairing-and-wake-word
    provides: "08-06 arlowe-identity revoke --json; 08-10 factory-reset engine and revoke_or_record hook"
provides:
  - "arlowe_broker.resolve_broker(broker_file, config_url, ca_dir) -> (url, ca_path|None) | None"
  - "revoke_or_record: revoke first, orphaned-certs.jsonl on any failure"
  - "arlowe-factory-reset@.service (dashboard|button) and arlowe-factory-reset-resume.service"
affects: [08-17 reset triggers, 08-23 pairing broker lookup, 08-19 broker revoke endpoint]
tech-stack:
  added: []
  patterns: ["revoke subprocess in its own session, process group killed on timeout"]
key-files:
  created: [runtime/lib/arlowe_broker.py, runtime/lib/tests/test_arlowe_broker.py, tests/phase-8/test_factory_reset_revoke.py, tests/phase-8/test-reset-units.sh, units/arlowe-factory-reset@.service, units/arlowe-factory-reset-resume.service]
  modified: [runtime/cli/factory-reset, tests/phase-8/test_factory_reset.py, tests/phase-07.1/test-verify-unit-execstart.sh]
key-decisions:
  - "A present but invalid broker file (malformed or non-https) returns None; it does not fall back to the config URL"
  - "Orphan reason is the revoke payload's error field, else by exit code (3 rejected, 4 unavailable, 5 local_state), timeout, no_broker_url or local_error"
  - "Every non-zero exit, including 5, is an orphan: the pre-check already found a certificate_id, so the certificate exists"
  - "config URL read from /etc/arlowe/config.yml with yaml.safe_load, not arlowe_config.load(), so a schema error cannot block a reset"
duration: 40min
completed: 2026-09-29
---

# Phase 8 Plan 18: Reset Revoke and Units Summary

**Reset now calls `arlowe-identity revoke --json` before the commit point. The broker comes from the shared `resolve_broker` (FAT file with a private CA first, then `identity.provisioning_url`). The revoke has a 20 s timeout. Any failure appends an fsynced orphan line and the wipe still runs. The helper has one template unit per trigger and a boot-time resume unit.**

## Tasks

| Task | Commit | Result |
|------|--------|--------|
| 1 RED | 7cf458b | 5 of 6 revoke cases failed on `skipped`; broker tests failed on import; 20 unit checks failed on missing files |
| 2 GREEN | bbc3e9b | all pass |

## Verification

- `pytest tests/phase-8/test_factory_reset.py tests/phase-8/test_factory_reset_revoke.py --import-mode=importlib`: 27 passed
- `pytest runtime/lib/tests/test_arlowe_broker.py`: 5 passed; the full `runtime/lib/tests` suite passed (219 passed, 1 skipped)
- `pytest tests/phase-8 runtime/pair/tests --import-mode=importlib`: 51 passed; all four `tests/phase-8/test-*.sh` passed
- `test-verify-unit-execstart.sh` (debian:bookworm container): all cases passed
- `run-import-check.sh`: OK. Both new units walk `factory-reset` and `arlowe_broker`, and yaml resolves under `/usr/bin/python3`
- `systemd-analyze verify` on both units (bookworm container): clean. `security --offline` rates the resume unit 4.6
- shellcheck and `scripts/sanitize/check.sh`: clean
- Not verified: a real reset on hardware and a revoke against a live broker. Hardware validation is 08-27b

## Deviations from Plan

1. **[Rule 3 - Blocking] `factory-reset` now imports from `runtime/lib`.** It inserts `ARLOWE_LIB` (default `/opt/arlowe/runtime/lib`), the same form `runtime/cli/identity` uses, so import-graph can resolve it. The 08-10 fixture in `tests/phase-8/test_factory_reset.py` gained `ARLOWE_LIB` (1 line).
2. **[Rule 3 - Blocking] The `[repaired-image]` fixture in `tests/phase-07.1/test-verify-unit-execstart.sh` needed a `factory-reset` stub.** Without it the new units' ExecStart failed the gate.
3. **[Rule 2 - Missing Critical] Revoke hardening.** The revoke runs in its own session and its process group is killed on timeout, so a grandchild holding stdout open cannot outlast the 20 s. An inherited `ARLOWE_BROKER_CA_BUNDLE` is dropped when the resolver returns no CA.
4. **Size.** Net shortstat is 513 including this summary, over the 400 target and under the 600 cap. The plan estimated 332. The difference is the revoke error mapping and hardening, the unit sandbox blocks and the fixture copy.

## Notes for Later Plans

- 08-23 imports `resolve_broker` from `arlowe_broker`. Pass a private `ca_dir` and remove it afterwards. Logs name only the source (`file|config|none`).
- A revoke step that ran but was not recorded before a crash reruns on resume. That can append a second orphan line for the same certificate, so a reaper should dedupe by `certificate_id`.
- The resume unit's `Before=` sets ordering only. If the resume fails before the commit point, the six units still start, against a unit that has not been wiped yet.
