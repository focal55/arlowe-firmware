---
phase: 08-first-boot-pairing-and-wake-word
plan: 07
subsystem: pairing
tags: [networkmanager, nmcli, wifi, setup-ap, python, stdlib]

requires:
  - phase: 08-01
    provides: "ADR-0011 values (SSID, PSK alphabet, AP settings, error strings); PR #201 no default login"
provides:
  - "runtime/pair package with NetMan (radio_on, scan, ap_up, ap_down, wifi_profiles, delete_profile) and session_credentials"
  - "runtime/pair/errors.py: ErrorKind, MESSAGES, JoinError"
  - "runtime/pair/tests/fixtures/fake-nmcli: scripted nmcli reused by 08-07b and the E2E (08-26)"
affects: [08-07b, 08-11, 08-13, 08-23, 08-26, 08-27b]

tech-stack:
  added: []
  patterns:
    - "nmcli via injectable runner(argv, input=None); secrets only on stdin through passwd-file"
    - "setup AP addressed by a uuid4 chosen at add time, never by name"

key-files:
  created:
    - runtime/pair/__init__.py
    - runtime/pair/errors.py
    - runtime/pair/netman.py
    - runtime/pair/tests/fixtures/fake-nmcli
    - runtime/pair/tests/test_netman.py
  modified: []

key-decisions:
  - "nmcli failures raise netman.NetManError (action + rc + first stderr line, never argv); not-found (rc 10) is tolerated by ap_down and delete_profile"
  - "A failed ap_up deletes the half-made in-memory profile before re-raising"
  - "fake-nmcli logs argv without the program name"

duration: 25min
completed: 2026-09-28
---

# Phase 8 Plan 07: NetworkManager setup-AP wrapper Summary

**Stdlib nmcli wrapper that raises an in-memory WPA2 setup AP by uuid with its PSK fed on stdin via `passwd-file /dev/stdin`, plus the shared pairing error kinds and a scripted fake nmcli.**

## Performance

- **Tasks:** 2 of 2
- **Files created:** 5

## Accomplishments
- `NetMan` covers radio, scan (terse `\:`/`\\` unescaping, empty-SSID drop, dedupe by strongest signal, sorted), setup AP up/down and wifi profile list/delete. No call puts a secret in argv, and no call uses a shell.
- `errors.py` holds the eight `ErrorKind`s and one owner string for each. The display, portal, flow and join all import this copy.
- `fake-nmcli` provides scenario JSON (inline or a file path), an argv log, and uuid-keyed profile state. It records a passwd-file secret only as `secret_supplied`. Its header cites NetworkManager 1.42.4 `nmc_utils_parse_passwd_file` and `nm_utils_buf_utf8safe_unescape`.

## Task Commits

1. **Task 1: Fake nmcli and cases (RED)** - `c7e391c` (test)
2. **Task 2: netman and errors (GREEN)** - `8b81f4b` (feat)

## Verification

- `PYTHONPATH=runtime:runtime/lib python3 -m pytest runtime/pair/tests/test_netman.py -q` passes 12 tests locally on Python 3.11.13.
- Mutation check: putting `wifi-sec.psk <psk>` into the add argv and logging argv made 3 cases fail (`test_ap_up_and_down`, `test_no_secret_in_argv`, `test_secrets_not_logged`).
- Combined run of runtime/lib, voice and pair tests: 137 passed, 1 skipped. The three cryptography-dependent lib test files were ignored because the local interpreter lacks `cryptography`, which is not caused by this change. The combined run confirms that test collection does not collide.
- `ruff check` is clean. `scripts/sanitize/check.sh` is clean.
- No CI job collects `runtime/pair/tests` yet. The `pair-bookworm` job comes with 08-02.
- Not verified here: whether NetworkManager 1.42 brings up a wpa-psk AP when the PSK comes only from passwd-file. That needs hardware (08-27b SC1).

## Deviations from Plan

1. **Precondition grep.** `git show main:pi-gen/config | grep -c FIRST_USER_PASS` prints 1, not 0. The one match is the comment explaining that the variable is deliberately unset. There is no assignment, and PR #201 is merged. The precondition's intent is met, so work proceeded.
2. **ADR-0011 is not on main yet** (08-01 writes it). The values came from the plan's execution notes and 08-01-PLAN, which the plan says are the contract anyway.
3. **[Rule 2] ap_up cleans up on failure.** If `connection up` fails, the in-memory profile is deleted by uuid before `NetManError` is re-raised, so a failed bring-up leaves nothing behind. The case `test_ap_up_failure_raises_and_cleans_up` was added for this.
4. **Case count.** The plan lists 11 cases; the suite has 12. The extra one is the ap_up failure case. The stdin payload check (`802-11-wireless-security.psk:<psk>\n`) and the `secret_supplied` state check are folded into `test_no_secret_in_argv`.
5. **Size.** The PR is 441 net lines against the plan's estimate of 376: tests 169 (estimate 122), fake 99 (estimate 71), netman 132. That is over the 400 target and under the 600 cap.
6. **Test offsets fixed in the GREEN commit.** The RED tests assumed that the fake's log includes argv[0]. The fake logs argv without the program name, which is easier for the E2E to read, so the offsets were corrected in `8b81f4b`.

## Notes for downstream plans

- 08-07b: `ap_up` builds its stdin line inline as `PSK_KEY + ":" + psk + "\n"`, which is where `passwd_line` should be routed in. The fake's passwd-file reader is the plain split to replace. `NOT_FOUND = 10` and `NetManError` already exist.
- 08-23: when nothing is recorded, `ap_down()` does nothing. `ap_up` records a new uuid on every call, so the stale-profile sweep (`wifi_profiles` plus `delete_profile`) is still the recovery path after a crash.
