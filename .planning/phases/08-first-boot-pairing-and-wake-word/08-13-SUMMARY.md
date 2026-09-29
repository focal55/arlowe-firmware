---
phase: 08-first-boot-pairing-and-wake-word
plan: 13
subsystem: pairing
tags: [state-machine, networkmanager, identity, tdd]
requires: ["08-06", "08-07"]
provides: ["PairingFlow", "State", "classify_identity_failure", "run_identity"]
affects: ["08-12", "08-20", "08-23", "08-26"]
key-files:
  created: [runtime/pair/flow.py, runtime/pair/tests/test_flow.py]
  modified: []
completed: 2026-09-29
---

# Phase 8 Plan 13: Pairing State Machine Summary

The optimistic-handoff flow: WAITING -> CONNECTING -> PROVISIONING -> COMMITTING -> PAIRED. Every SC3 failure ends in ERROR with its own ErrorKind, all saved Wi-Fi profiles deleted and the setup AP back up with the session password. The claim code is passed only in `ARLOWE_OWNER_TOKEN`, never in argv.

## Interface for later plans (differs from or fills gaps in the plan text)

- `PairingFlow(net, display, commit, broker, ntp_synced, session, identity=run_identity, on_paired=noop, clock=time.monotonic, sleep=time.sleep)`. `broker()` is called at each submission and returns `(url, ca_path | None)` or None, which is `resolve_broker`'s shape (08-18). None means `not_configured`: the AP stays up and identity is never called.
- `submit(form)` runs **synchronously on the caller's thread** (the portal already calls `on_submit` on a new thread) and returns False when refused (single flight).
- Form keys: `ssid`, `psk`, `display_name`, `password`, `claim_code`. Secrets are `psk`, `password`, `claim_code`. A blank `password`/`claim_code` reuses the held value. A blank `psk` reuses the held one **only for the same SSID**; for a different SSID it means an open network.
- `status()` -> `{status, error_kind, message, last_form (no secrets), has_previous: {psk, password, claim_code}}` for 08-12's portal.
- `display.show(screen)`: `screen` is `"connecting" | "provisioning" | "committing" | "paired"` or an `ErrorKind` member. 08-11 has no committing screen, so 08-23's adapter must map it (e.g. to provisioning). The flow shows `"paired"` without URL/IP; 08-23 draws the full paired screen from `on_paired`.
- `commit(form, provisioned)`: `provisioned` is identity's JSON plus `broker_url`, which 08-20 needs for `identity.provisioning_url`.
- `net`: uses `ap_down`, `join` (08-07b: raises `JoinError`), `wifi_profiles`, `delete_profile`, `ap_up`. It does **not** call `saved_ssid_profile`.

## Deviations from Plan

1. **[Rule 2] Failure recovery sweeps every Wi-Fi profile** (`wifi_profiles()` + `delete_profile`) instead of calling 08-07b's `saved_ssid_profile(ssid)`. The AP is down at that point, so every wireless profile is stale. This enforces ADR-0011's invariant without depending on 08-07b's per-SSID bookkeeping. It uses the same sweep as 08-23's startup.
2. **[Rule 2] `NetManError` during `ap_down`/`join` maps to `wifi_failed`.** Any unexpected exception maps to `setup_failed` and still runs recovery, so the AP always comes back. Logs carry only the exception type.
3. **[Rule 2] Identity exit codes outside the N6 table** (2, 6, an exit-0 run with unparsable JSON) map to `cert_failed`. When the CLI cannot be launched (OSError), the result is `(5, {})`, which also maps to `cert_failed`.
4. `sleep` is injected alongside `clock`, which lets the tests drive the 2 s handoff delay and the 30 s NTP cap with a fake clock.
5. Size: 516 net lines of code plus this summary, against ~355 planned. The tests (21 cases, a PATH shim) are larger than the estimate. The PR is under the 600 cap.

## Verification

- `PYTHONPATH=runtime:runtime/lib python3 -m pytest runtime/pair/tests -q --import-mode=importlib`: 33 passed.
- CI-equivalent `runtime/pair/tests tests/phase-8`: 66 passed (local Python 3.11.13, not the bookworm container).
- `scripts/sanitize/check.sh`: clean.
- Not verified here: the real `arlowe-identity` against a broker and the real `join` (08-07b). Both belong to 08-26 and 08-27b.
