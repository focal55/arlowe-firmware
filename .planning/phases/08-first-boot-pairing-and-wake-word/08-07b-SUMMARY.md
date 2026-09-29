---
phase: 08-first-boot-pairing-and-wake-word
plan: 07b
subsystem: pairing
tags: [networkmanager, nmcli, wifi, passwd-file, python, stdlib]

requires:
  - phase: 08-07
    provides: "NetMan, NetManError, JoinError/ErrorKind, fake-nmcli"
provides:
  - "NetMan.join(ssid, psk) and NetMan.saved_ssid_profile(ssid)"
  - "netman.passwd_line(key, value): NetworkManager 1.42.4 passwd-file escaper"
  - "fake-nmcli: port of the 1.42.4 passwd-file parser; `join` scenario key"
affects: [08-13, 08-23, 08-26, 08-27b]

key-files:
  created:
    - runtime/pair/tests/test_netman_join.py
  modified:
    - runtime/pair/netman.py
    - runtime/pair/tests/fixtures/fake-nmcli

key-decisions:
  - "Join failure classification reads nmcli's full stderr, carried on NetManError.stderr"
  - "passwd_line also escapes \\v and \\f, which the parser would strip at the edges"

duration: 20min
completed: 2026-09-28
---

# Phase 8 Plan 07b: Home-network join Summary

**`NetMan.join` creates a secretless, system-owned (`psk-flags 0`) profile under a uuid4, brings it up by uuid with the PSK on `passwd-file /dev/stdin`, and on failure deletes by uuid and raises `JoinError` classified from the NetworkManager reason code.**

## Accomplishments

- `passwd_line` escapes `\`, space, tab, `\v`, `\f`; raises `ValueError` on CR, LF, NUL. `ap_up` routes through it.
- `join`: argv never carries the PSK or addresses the profile by name; `--wait 45 connection up uuid <u> [passwd-file /dev/stdin]`; open networks send no `wifi-sec` keys and no stdin.
- Reason codes 7/8/11 -> `wifi_rejected`; 53 or "No network with SSID" -> `wifi_not_found`; else `wifi_failed` (brcmfmac mapping MEDIUM, 08-27b confirms).
- `saved_ssid_profile(ssid)` deletes the joined profile by the uuid recorded at join time; a no-op for an unknown SSID, tolerates not-found.
- fake-nmcli reads passwd-file with a port of `nmc_utils_parse_passwd_file` + `nm_utils_buf_utf8safe_unescape(STRIP_SPACES)`; `join` scenario takes `correct_psk` or `{exit, stderr}`; profiles record `ap` and `psk_flags`.

## Task Commits

1. Task 1 (RED): join scenario, parser port, cases - `55d8f10`
2. Task 2 (GREEN): join, passwd_line, saved_ssid_profile - `6b40279`

## Verification

- `PYTHONPATH=runtime:runtime/lib python3 -m pytest runtime/pair/tests -q`: 23 passed (12 from 08-07, 11 new).
- Mutation check: with `passwd_line` escaping disabled, the adversarial PSK join fails with `wifi_rejected`, so the round-trip case depends on the escaper.
- Not verified here: PSK persistence across reboot and the brcmfmac reason codes need hardware (08-27b).

## Deviations from Plan

1. **[Rule 2] `NetManError` gained a `stderr` attribute.** Its message keeps only the first stderr line; classification reads the whole stderr so a leading nmcli warning line cannot hide the `(N)` code. Message format unchanged.
2. **[Rule 1] `passwd_line` also escapes `\v` and `\f`.** The parser strips any `g_ascii_isspace` at the value's edges, not only space and tab. WPA PSKs cannot contain them, so this is belt-and-braces.
3. **`connection add` failure is handled like an `up` failure:** delete by uuid (not-found tolerated) and raise a classified `JoinError`, so callers see one exception type for a failed join. A failing cleanup delete still surfaces as `NetManError`.
4. Tests: 11 cases (plan said 10); the classification case is parametrized over `(53)`, "No network with SSID" and `(3)`.

## Next Phase Readiness

- 08-13/08-23: catch `JoinError` (`.kind` is an `ErrorKind`) from `join`; `NetManError` only escapes if the cleanup delete itself fails.
- `saved_ssid_profile` only knows SSIDs joined by the same `NetMan` instance.
