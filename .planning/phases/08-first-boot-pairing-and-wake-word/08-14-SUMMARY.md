---
phase: 08-first-boot-pairing-and-wake-word
plan: 14
subsystem: pairing
tags: [hostname, mdns, systemd, privilege-split, tdd]
requires: ["08-03"]
provides: ["arlowe-pair-commit.service", "runtime/cli/pair-commit"]
affects: ["08-20", "08-25"]
tech-stack:
  added: []
  patterns: ["root oneshot re-validates an unprivileged request file at the boundary"]
key-files:
  created: [runtime/cli/pair-commit, units/arlowe-pair-commit.service, tests/phase-8/test_pair_commit.py]
  modified: [tests/phase-07.1/test-verify-unit-execstart.sh]
decisions:
  - "Every 127.0.1.1 line in /etc/hosts is replaced, not only the first, so a stale duplicate cannot keep the old name resolving."
  - "ProtectHostname=no, per plan; hostnamed performs the write over D-Bus so =yes may work, unproven on the image."
metrics:
  duration: ~25min
  completed: 2026-09-29
---

# Phase 8 Plan 14: Pair Commit Oneshot Summary

Root oneshot `arlowe-pair-commit.service` that turns the daemon's `{"display_name": ...}` request into the unit's hostname, `/etc/hosts` 127.0.1.1 entry and an avahi restart, after re-validating it with `arlowe_hostname.validate_display_name`.

## Interface for 08-20 / 08-25

- Daemon writes `/run/arlowe-pair/commit-request.json` = `{"display_name": "<as typed>"}` (<= 4096 bytes, regular file), then `systemctl start arlowe-pair-commit.service` (allowed by the `arlowe-` polkit prefix). Any failure surfaces as a failed start; treat non-zero as `setup_failed`.
- Exit codes: 0 applied, 2 bad request (missing, symlink, non-regular, too big, not JSON, no `display_name` string), 3 name rejected, 4 system command failed.
- The helper does not delete the request file (it can write only `/etc/hosts`); 08-20 owns its cleanup.
- Unit has no `RemainAfterExit`, so each `systemctl start` re-runs it. No `[Install]`.
- Test hooks: `ARLOWE_ROOT` prefixes the request and hosts paths; `ARLOWE_LIB` locates the library.

## Tasks

| Task | Commit | Notes |
| ---- | ------ | ----- |
| 1 RED cases | 89c59bb | 12 cases (the malformed case is parametrized x4). 5 failed; 7 passed spuriously because `python3 <missing file>` also exits 2. |
| 2 GREEN helper + unit | 8a6d199 | 12/12 pass |

## Verification

- `PYTHONPATH=runtime/lib python3 -m pytest tests/phase-8/test_pair_commit.py -q`: 12 passed.
- `tests/phase-07.1/test-verify-unit-execstart.sh` in debian:bookworm: all cases passed (fails on macOS bash; CI runs Linux).
- `tests/phase-07.1/run-import-check.sh`: OK; arlowe-pair-commit under /usr/bin/python3 reaches only stdlib and arlowe_hostname.
- pair-bookworm emulation (bookworm, 00-packages-nr set): 57 passed. phase8-shell: all three scripts PASS.
- `systemd-analyze verify` clean; `systemd-analyze security --offline=yes`: 4.2 OK.
- `scripts/sanitize/check.sh`: clean.
- Not verified: hostnamectl, avahi and mDNS resolution of `<name>.local` on hardware. Needs a bench run.

## Deviations from Plan

**1. [Rule 3 - Blocking] execstart gate fixture needed the new entry point.** `[repaired-image]` in `tests/phase-07.1/test-verify-unit-execstart.sh` copies every `units/*.service` and failed on the missing `/opt/arlowe/runtime/cli/pair-commit`. Added one `mkexec` line beside radio-init's. Commit 8a6d199.

**2. Size.** ~323 net lines of code and tests plus this summary, against the plan's 270: the test file is table-driven but longer than estimated, and the unit carries the full hardening block.

## Next Phase Readiness

08-20 must write the request file into `/run/arlowe-pair/` (the daemon's RuntimeDirectory) and remove it after the start returns.
