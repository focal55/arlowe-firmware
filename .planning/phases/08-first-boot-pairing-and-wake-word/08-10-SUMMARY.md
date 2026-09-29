---
phase: 08-first-boot-pairing-and-wake-word
plan: 10
subsystem: reset
tags: [factory-reset, networkmanager, journald, crash-safety, tdd]

requires:
  - phase: 07-device-identity-and-pki
    provides: "arlowe-identity reset --force"
  - phase: 03-filesystem-layout
    provides: "install-arlowe-fs.sh owners and modes the skeleton recreation mirrors"
provides:
  - "runtime/cli/factory-reset: ADR-0013 wipe engine, crash-safe via an fsync'd step marker"
  - "revoke_or_record(ctx) hook, stubbed to \"skipped\", call site between stop and commit"
affects: [08-17 reset triggers, 08-18 revoke hook and reset units]

tech-stack:
  added: []
  patterns:
    - "Ordered (name, fn) step list; marker records completed-step count after each step"
    - "PATH shims sharing one call log that also records filesystem state at call time"

key-files:
  created:
    - runtime/cli/factory-reset
    - tests/phase-8/test_factory_reset.py
  modified: []

key-decisions:
  - "Fail injection raises after step N runs but before it is recorded, so the resume test proves every step idempotent, not just skippable"
  - "Marker carries the revoke outcome, so a resume past step 2 reports the original result and never re-attempts the revoke"
  - "Audit line's `at` is the reset's start time; a rerun of the audit step recognises its own line and does not duplicate it"
  - "systemctl stop failure is logged, not fatal: arlowe-pair.service does not exist until a later plan"
  - "--trigger with a marker present resumes the existing reset under its original trigger"

duration: 25min
completed: 2026-09-28
---

# Phase 8 Plan 10: Factory Reset Engine Summary

**Root helper that performs ADR-0013's ten-step wipe in a fixed order. It is fixture-proven to leave the same end state when killed after any of its nine recorded steps and rerun with `--resume`.**

## Performance

- **Duration:** about 25 min
- **Completed:** 2026-09-28
- **Tasks:** 2
- **Files created:** 2

## Accomplishments

- `factory-reset --trigger dashboard|button | --resume [--no-reboot]` does the following in order:
  1. Writes the marker.
  2. Stops the six units and `arlowe-pair`.
  3. Calls the revoke hook.
  4. Removes `config.yml`. This is the commit point.
  5. Deletes every `802-11-wireless` profile and `seen-bssids`, `timestamps` and `*.lease`.
  6. Runs `arlowe-identity reset --force`.
  7. Empties the six state directories and recreates the installer skeleton.
  8. Runs `journalctl --rotate` and then `--vacuum-time=1s`.
  9. Sets the hostname back to `arlowe` and writes the `127.0.1.1` line in `/etc/hosts`.
  10. Appends the audit line, removes the marker, syncs and reboots.
- Survivors: the reset ledger, `opt/arlowe/models`, `.firstboot-done` and `.models-grow-done`. A symlink inside a wiped directory is unlinked, not followed; the test points one at the models marker to prove this.
- 19 test cases: the full wipe, `--no-reboot`, survivors, ordering from the call log, a ledger created on demand, resume after each of the 9 steps, resume state equal to a clean run, a no-op resume, and 3 bad-argument cases.

## Task Commits

1. **Task 1: Cases (RED)** - `0d35c7a` (test)
2. **Task 2: Reset engine (GREEN)** - `6f444c6` (feat)

## Verification

- `python3 -m pytest tests/phase-8/test_factory_reset.py -q --import-mode=importlib`: 19 passed, on macOS (Python 3.11) and in `debian:bookworm` as root (Python 3.11.2, runtime about 104 s under arm64 emulation).
- RED: 16 failed and 3 passed. The 3 bad-argument cases passed only because `python3` also exits 2 when the script is missing.
- Mutation checks:
  - Moving `stop` after `commit` fails `test_stop_then_commit_then_wipe`.
  - Disabling the audit dedupe fails the resume case for step 9.
- `ruff check`: clean. `scripts/sanitize/check.sh`: clean.
- Not verified: on-device behaviour (real nmcli, hostnamectl, journald, chown to `arlowe`). That needs a built image and the units from 08-18.

## Deviations from Plan

1. **Precondition read literally is 1, not 0.** `grep -c FIRST_USER_PASS pi-gen/config` matches a comment that says the variable is deliberately unset. No assignment exists, and PR #201 is merged, so the intent of the precondition holds.
2. **ADR-0013 is not on main yet.** 08-01 writes it in this wave. The step order comes from 08-01's ADR-0013 specification and RESEARCH Pattern 10, which agree.
3. **Marker has an extra `revoke` field** alongside `{trigger, started_at, step}`. It lets 08-18's "a resume never re-attempts the revoke once past it" hold, and lets the audit line report the original outcome.
4. **Nine recorded steps, not ten.** ADR step 1 (marker write) and the tail of step 10 (marker removal, sync, reboot) sit outside the step loop. `ARLOWE_RESET_FAIL_AFTER` accepts 1 to 9.
5. **Size: 445 lines** (helper 232, tests 213) against the plan's estimate of about 310. This is under the 600 cap. The resume-equivalence case and the ordering assertions based on filesystem state account for most of the extra lines.

## Notes for 08-18

- Replace only the body of `revoke_or_record(ctx)`. `ctx` has `trigger`, `started_at`, `step` and `revoke`. The module-level `path()` helper applies `ARLOWE_ROOT`.
- The fixture builder is the `env` fixture in `tests/phase-8/test_factory_reset.py`. Per 08-18's own note, copy it; do not import it.
- The helper reads `ARLOWE_RESET_FAIL_AFTER`, and chowns only when `ARLOWE_ROOT` is unset.
