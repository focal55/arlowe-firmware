---
phase: 08-first-boot-pairing-and-wake-word
plan: 05
subsystem: pki
tags: [claim-codes, broker, flock, crockford-base32, stdlib]
requires: []
provides:
  - scripts/pki/claim_codes.py (store library and mint/revoke/release/list CLI)
affects: [08-15 broker claim gate, 08-19 revoke endpoint, 08-26 local broker]
tech-stack:
  added: []
  patterns: ["flock on <store>.lock + re-read + .tmp + fsync + os.replace for every write"]
key-files:
  created: [scripts/pki/claim_codes.py, scripts/pki/tests/test_claim_codes.py]
  modified: []
key-decisions:
  - "mint creates the store if absent; every other operation raises FileNotFoundError on a missing store"
  - "release on an unused or revoked code is a no-op; revoked is terminal"
duration: 35min
completed: 2026-09-28
---

# Phase 8 Plan 05: Claim-Code Store Summary

**sha256-keyed claim-code store that binds a code to the first device_id, rebinds it idempotently, and serializes the broker and the CLI with flock and atomic replace.**

## Interface for 08-15 and 08-19

- `normalize(code) -> str` (raises `ValueError`), `code_hash(code) -> str`.
- `redeem(entry, device_id, now=None) -> dict | None`: pure. Returns the post-redemption entry, or `None` for unknown, revoked or bound elsewhere.
- `release_device(entries, device_id) -> int`: mutates the map in place.
- `ClaimStore(path)`: `.load()`, `.transaction(create=False)` (a context manager that yields the entry map under `LOCK_EX` and persists on clean exit only if it changed), `.mint(note)`, `.redeem(code, device_id) -> bool`, `.release(code)`, `.release_device(device_id) -> int`, `.revoke(code)`.
- Check, issue and bind in the broker: `with store.transaction() as e: after = claim_codes.redeem(e.get(code_hash(c)), dev)`, then issue, then `e[key] = after` only on success. If the block raises, nothing is written.

## Verification

- `pytest scripts/pki/tests -q` (venv with requirements.txt + pytest): 38 passed (19 new, 19 existing broker cases unchanged).
- System `python3 -m pytest scripts/pki/tests/test_claim_codes.py`: 19 passed. The module is stdlib-only.
- Concurrency case run 10 times in a row: 10/10 passed. Mutation check: with the `flock` line removed, it failed 5/5 (`FileNotFoundError` on the shared `.tmp` plus a lost update).
- CLI smoke: `list` on a missing store exits 1 with a message; `mint` prints `XXXXX-XXXXX-XXXXX-XXXXX` and creates the store and lock at mode 0600; revoking an unknown code exits 1; `list` shows the hash prefix, state, device prefix, dates and note.
- `scripts/sanitize/check.sh`: clean. No shell was touched, so shellcheck did not apply.
- The `pki-broker` CI job (08-02) is not on main yet, so these suites ran locally only.

## Deviations from Plan

1. **[Rule 3] Precondition grep.** `git show main:pi-gen/config | grep -c FIRST_USER_PASS` prints 1, not 0. The match is a comment saying the variable is deliberately unset. PR #201 is merged and no assignment exists, so the precondition's intent holds and I continued.
2. **[Rule 1] Test hardening.** The first version of the race test hung for 30 s on the result queue when a worker crashed. Workers now report their exception as the result, so a lost lock fails fast and names the error.
3. **Interface split.** The plan exports both `redeem` and `ClaimStore`. Module-level `redeem` is the pure per-entry decision the implementation note asks for, and `ClaimStore.redeem(code, device_id) -> bool` is the locked convenience wrapper. `release_device` has the same split. I added `transaction()` so the broker can hold one lock across check, issue and bind.
4. **Size.** The code is 378 lines against the ~260 estimated. The module is 193 lines (140 planned), including the docstring and the `transaction()` context manager. The tests are 185 lines (120 planned) and hold 19 cases, including parametrized ones.
