---
phase: 08-first-boot-pairing-and-wake-word
plan: 01
subsystem: docs
tags: [adr, pairing, networkmanager, argon2id, factory-reset, claim-codes]

requires:
  - phase: 07-device-identity-and-pki
    provides: token-agnostic device contract (ADR-0007), arlowe-identity exit codes
provides:
  - ADR-0011 setup channel, handoff and the pairing value contract
  - ADR-0012 owner credential, session cookie and claim-code semantics
  - ADR-0013 factory reset order, ledger and triggers
affects: [08-02 through 08-29, 08.1]

key-files:
  created:
    - docs/architecture/0011-pairing-setup-channel.md
    - docs/architecture/0012-owner-credential-and-claim-codes.md
    - docs/architecture/0013-factory-reset.md

key-decisions:
  - "WPA2 setup AP with a per-session 12-character PSK; open hotspot rejected (N8)"
  - "No Conflicts= between arlowe-pair and arlowe-face; the daemon exits to hand over the Whisplay"
  - "config.yml is the single commit point for both pairing (written last) and reset (removed at step 4)"
  - "Claim codes bind on first use, idempotent per device_id, released by reset's revoke"

duration: 2min
completed: 2026-09-28
---

# Phase 8 Plan 01: Phase 8 ADRs Summary

**Three Accepted ADRs fix the Phase 8 contract: per-session WPA2 setup AP with secrets off argv and config.yml as the commit point, Argon2id owner credential with first-use-bound claim codes, and a ten-step factory reset with a durable orphaned-cert ledger.**

## Task Commits

1. **Task 1: ADR-0011 pairing setup channel and handoff** - `43190ea` (docs)
2. **Task 2: ADR-0012 owner credential and claim codes; ADR-0013 factory reset** - `96c2e0c` (docs)

## Verification

- ADR-0011: `wifi.share.protected` 2, `not_configured` 2, `passwd-file` 3,
  `settings.modify.system` 2, `/run/NetworkManager/system-connections` 1; the argv section exists
  and no residual risk accepts a secret in argv.
- ADR-0012: `argon2id` 3, references ADR-0007. ADR-0013: `orphaned-certs.jsonl` 2,
  `arlowe-factory-reset@` 2.
- `scripts/sanitize/check.sh --grep-only`: clean.

## Deviations from Plan

1. **Phase precondition grep prints 1, not 0.** `git show main:pi-gen/config | grep -c FIRST_USER_PASS`
   matches the comment "FIRST_USER_PASS is deliberately unset ... Never set it". PR #201 is merged
   and no assignment exists, so the precondition's intent holds. Later wave-1 plans will see the
   same count; the check should be `grep -c '^FIRST_USER_PASS='`.
2. **Size over the estimate.** The ADRs total 423 lines against the plan's 365, mostly ADR-0011
   (196 lines), whose contract content is prescribed. Under the 600 cap.
3. **Wording additions not in the plan text** (no value changed): ADR-0011 records that it
   supersedes research Pattern 1's `Conflicts=` and adds "anyone who can see the Whisplay can read the session password" as a residual risk; ADR-0012 adds the unpaired-unit stolen-card case and the
   cleartext-LAN session cookie as a residual risk; ADR-0013 states that the resume path requires
   every reset step to be safe to repeat.

## Next Phase Readiness

Later plans quote these ADRs verbatim. The orphaned-cert reaper (research open question 9)
remains unassigned.
