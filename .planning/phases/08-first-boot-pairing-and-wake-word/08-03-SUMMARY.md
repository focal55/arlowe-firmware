---
phase: 08-first-boot-pairing-and-wake-word
plan: 03
subsystem: pairing
tags: [hostname, rfc1123, sanitize, banlist, sha256, stdlib]
requires: []
provides:
  - "arlowe_hostname.slugify / validate_display_name / HostnameRejected (reason codes)"
  - "runtime/lib/arlowe_hostname_banlist.json: (length, sha256) of hostname-shaped banlist entries"
  - "scripts/sanitize/gen-hostname-banlist.py [--check]"
affects: [08-12 pairing portal, 08-14 root commit helper, 08-factory-reset]
tech-stack:
  added: []
  patterns: ["Ship hashes of banned literals, derive test inputs from banlist.txt at run time"]
key-files:
  created:
    - runtime/lib/arlowe_hostname.py
    - runtime/lib/arlowe_hostname_banlist.json
    - scripts/sanitize/gen-hostname-banlist.py
    - runtime/lib/tests/test_arlowe_hostname.py
  modified: []
key-decisions:
  - "Display name is whitespace-stripped before the 32-character limit and returned stripped"
  - "Check order: empty, too_long, no_usable_characters, reserved, not_allowed"
  - "reserved means slug == localhost or slug.isdigit(); a hyphenated digit slug such as 1-2-3 is allowed"
duration: 15min
completed: 2026-09-28
---

# Phase 8 Plan 03: Display Name to Hostname Summary

**One stdlib validator turns an owner display name into an RFC 1123 label and refuses names containing a hashed banlist entry without naming it.**

## Accomplishments
- `validate_display_name(name) -> (display_name, slug)` or `HostnameRejected(reason)`, `reason` in {empty, too_long, no_usable_characters, reserved, not_allowed}; `str(exc)` is an owner-readable sentence that never contains a banlist entry.
- The banlist check hashes every slug substring of each shipped length; the JSON holds 3 `(length, sha256)` pairs and no literal.
- The generator's `--check` runs inside the pytest suite, so a banlist.txt edit without regeneration fails the `python-test` job.
- `ARLOWE_HOSTNAME_BANLIST` overrides the hash file path.

## Task Commits
1. Task 1 (RED): `82364a8` test(08-03): add failing cases for display name to hostname
2. Task 2 (GREEN): `e2e13ff` feat(08-03): slugify display names into hostnames against a hashed banlist

## Verification
- `PYTHONPATH=runtime/lib python3 -m pytest runtime/lib/tests/test_arlowe_hostname.py -q`: 33 passed (RED run: collection error, ModuleNotFoundError).
- `gen-hostname-banlist.py --check`: in sync (3 entries).
- `scripts/sanitize/check.sh`: clean; a direct `rg -iF -f banlist.txt` over the four new files: no hits.
- Full `runtime/lib/tests` + `runtime/voice/tests`: 158 passed, 1 skipped. Three suites needing `cryptography` were excluded locally because it is not installed on this Mac; CI installs it.

## Deviations from Plan
1. **Precondition check prints 1, not 0.** `git show main:pi-gen/config | grep -c FIRST_USER_PASS` matches a comment that says the variable is deliberately unset. PR #201 is merged and no assignment exists, so the precondition's intent holds.
2. **Reserved test input.** A draft case used `"1 2 3"`, whose slug `1-2-3` is not all digits under the spec. Replaced with fullwidth `"１２３"`, which NFKD folds to `123`.
3. **Emoji avoided in tests.** The no-usable-characters case uses `"★☆"` instead of an emoji, per the no-emoji rule.
4. **Test count.** The plan estimated 13 cases; the file has 18 test functions (33 with parametrization). Net PR size is still under 400.

## Residual
ADR-0012 accepts it: the sha256 of a short literal lets someone who already has a guess confirm it.

## Next Phase Readiness
08-12 and 08-14 import `arlowe_hostname` from `runtime/lib`. They should show `str(exc)` to the owner and switch on `exc.reason`. Avahi collisions (`name-2.local`) are not handled here; the paired screen still needs to show the IP as a fallback.
