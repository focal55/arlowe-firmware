---
phase: 07-device-identity-and-pki
plan: 01
subsystem: infra
tags: [pki, x509, aws-iot-core, adr, config-schema, jsonschema]

requires:
  - phase: 04-config-overlay
    provides: defaults.yml + schema.yml + deep-merge loader that the identity block plugs into
  - phase: 06-image-build-with-a-b-partitions
    provides: /var/lib/arlowe owner-state partition where the key and cert will live
provides:
  - ADR-0007 (Proposed) naming AWS IoT Core native issuance via iot:CreateCertificateFromCsr
  - identity config block (provisioning_url, credentials_endpoint, role_alias, poll_interval_seconds)
  - regression proof that the identity block is inert for the dashboard config save path
affects: [07-03, 07-05a, 07-05b, 07-06, 07-07, 07-08a, 07-09, phase-8-pairing, phase-9-ota, phase-10-support-mode]

tech-stack:
  added: []
  patterns:
    - "Optional-but-always-defaulted config block: absent from schema `required`, unconditional in defaults.yml"
    - "Broker-mediated, token-agnostic cert issuance; zero secrets in the shipped image"

key-files:
  created:
    - docs/architecture/0007-managed-pki-service-selection.md
  modified:
    - config/schema.yml
    - config/defaults.yml
    - runtime/lib/tests/test_arlowe_config.py
    - runtime/dashboard/tests/unit/audio-save-body.test.ts

key-decisions:
  - "Managed PKI = AWS IoT Core native Amazon-root issuance via iot:CreateCertificateFromCsr; AWS Private CA ruled out at $400/mo"
  - "No certificate renewal: AWS-issued IoT certs run to 2049-12-31; rotation is deliberate, not scheduled"
  - "No claim certificates: one image per fleet makes any baked credential a fleet-wide secret"
  - "Revocation bound is one polling interval, enforced by credentialDurationSeconds=900 <= identity.poll_interval_seconds (min 900, default 3600)"
  - "`identity` is OPTIONAL at the top level, never added to schema `required`, because save-body.ts hard-codes an 8-key REQUIRED_KEYS"
  - "ADR-0007 ships as Proposed, not Accepted; 07-09 flips it after a staging run and a real AWS bill"

patterns-established:
  - "Optional-not-required config blocks: guarantee presence via defaults.yml + deep-merge instead of via schema `required`, so raw partial bodies from the dashboard stay valid"
  - "ADRs carry an explicit Proposed status with the named plan that will amend them, following ADR-0005's amendment convention"

duration: 21min
completed: 2026-09-10
---

# Phase 7 Plan 01: ADR-0007 + identity config block Summary

**AWS IoT Core native issuance (`CreateCertificateFromCsr`) recorded as the managed-PKI decision with a one-polling-interval revocation bound, plus a four-knob `identity` config block that is deliberately optional so it cannot 422 the dashboard.**

## Performance

- **Duration:** 21 min
- **Tasks:** 3/3
- **Files modified:** 5 (1 created, 4 modified)
- **Net diff:** 377 lines before this SUMMARY

## Accomplishments

- **SC1 and IDENT-01 are satisfied by this plan alone.** ADR-0007 names the service, the issuance API, the renewal story (none), and the revocation lever, and states the no-secure-element private-key exposure without hedging.
- **The $400/month trap is written down explicitly.** A reader who hears "AWS PKI" and reaches for AWS Private CA lands on ~$4,800/year before the first unit ships; the ADR makes that the most prominent sentence in the document.
- **The highest-risk edit in the phase landed without touching the dashboard.** `identity` is in the schema but not in its `required` list, and three new dashboard tests prove `buildSaveBody` round-trips an identity-bearing overlay rather than stripping it.

## Task Commits

1. **Task 1: ADR-0007 managed-PKI selection** — `58366ee` (docs)
2. **Task 2: optional identity config block** — `f3f7a5c` (feat)
3. **Task 3: identity-block regression tests** — `ed1e403` (test)

## Files Created/Modified

- `docs/architecture/0007-managed-pki-service-selection.md` (created, 229 lines) — SC1/IDENT-01 decision record. Status **Proposed**.
- `config/schema.yml` — `identity` object added after `ota`, with `additionalProperties: false` and its own four-key inner `required` list. **Top-level `required` is untouched at 8 entries.**
- `config/defaults.yml` — `identity` block with `provisioning_url: ""`, `credentials_endpoint: ""`, `role_alias: ""`, `poll_interval_seconds: 3600`.
- `runtime/lib/tests/test_arlowe_config.py` — `TestIdentityBlock`, 4 tests.
- `runtime/dashboard/tests/unit/audio-save-body.test.ts` — 3 tests; import extended to pull in `isFullConfig`.

## Decisions Made

**The identity knobs and their defaults**

| Knob | Default | Why |
|------|---------|-----|
| `provisioning_url` | `""` | Owner-authenticated CSR-broker endpoint, written at pairing (Phase 8). Account-identifying, so never a tracked literal. |
| `credentials_endpoint` | `""` | IoT credentials-provider host. Carries an account-specific prefix that the sanitize banlist does not catch; empty means "use the value in identity.json". |
| `role_alias` | `""` | IoT role alias. Empty means "use the provisioned value in identity.json". |
| `poll_interval_seconds` | `3600` (min 900, max 86400) | The number SC4 tests against. The 900 floor is what makes `credentialDurationSeconds=900 <= poll_interval` hold, which collapses `max(poll_interval, remaining_credential_lifetime)` to one polling interval. |

**`identity` is optional-not-required, and this is load-bearing.** `config/schema.yml` has `additionalProperties: false` and an 8-entry top-level `required` list that `runtime/dashboard/app/audio/save-body.ts` hard-codes as `REQUIRED_KEYS`. `POST /api/config` AJV-validates the raw body and returns 422 on anything partial. A 9th required key without a matching dashboard edit would 422 every dashboard audio save. Optional plus unconditional in `defaults.yml` gives the identical merged-dict guarantee via deep-merge, at zero dashboard risk. The three new dashboard tests fail if anyone later promotes `identity` to required without updating `save-body.ts`.

**ADR-0007 is Proposed, not Accepted.** Two claims in it are inference, not measurement: that AWS preserves the CSR subject CN, and that provisioning plus the credentials provider are genuinely unbilled. The second rests only on absence from a pricing page, which is weaker evidence than an explicit "no charge". 07-09 runs the staging flow, reads a real bill, and amends.

**Competitor pricing was deliberately not quoted as verified.** Azure, HashiCorp and Smallstep figures came from aggregators that disagree with each other, or are sales-gated. The ADR rules those options out on structural grounds (custody, churn, unplannability) and says so, rather than pretending to numbers it does not have.

## Deviations from Plan

None — plan executed exactly as written. No deviation rule fired.

## Issues Encountered

**`pnpm` is not installed on this machine.** The plan's Task 3 verify is `pnpm install --frozen-lockfile && pnpm test:unit`. `pnpm` is not on `PATH`; `corepack pnpm` resolves (11.24.0) but aborts with `ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY` because the existing `node_modules` was not created by pnpm, and forcing the purge would have disrupted a concurrently-running agent in the same working tree. Resolved by running the exact command `test:unit` expands to — `node --import tsx --test tests/unit/*.test.ts` — against the existing `node_modules`. **All 20 dashboard unit tests pass, including the 3 new ones.** No dependency was added by this plan, so `--frozen-lockfile` had nothing to enforce. Someone should still confirm a clean pnpm install on a fresh checkout before merge.

**A second agent was executing plan 07-02 in the same working tree.** Its in-flight edits to `.github/workflows/ci.yml`, `runtime/dashboard/package.json` and `runtime/lib/requirements-dev.txt` were visible in `git status` throughout. Every commit here staged files by explicit path, so nothing of 07-02's was swept in. This is the known "parallel dispatch needs git worktrees" hazard and it came within one `git add -A` of corrupting both plans.

## Verification Evidence

- `bash scripts/sanitize/check.sh` — exit 0 (230 files, 11 unit files, clean).
- Loader accepts: no overlay; full identity overlay; partial identity overlay (`poll_interval_seconds: 900` alone, siblings preserved); overlay with no identity block at all.
- Loader rejects `identity.poll_interval_seconds: 60` with `SystemExit(78)`.
- `PYTHONPATH=runtime/lib python3 -m pytest runtime/lib/tests/test_arlowe_config.py -q` — 11 passed (7 pre-existing, 4 new).
- Dashboard unit suite — 20 passed, 0 failed.
- `git diff --stat` shows **no change** to `runtime/dashboard/app/audio/save-body.ts`.
- `! grep -A 12 "^required:" config/schema.yml | grep -q identity` — exit 0.

**Not verified: CI coverage for the dashboard tripwire.** `ci.yml`'s `detect` step still tests for a ROOT `package.json` that does not exist, so every Node job is skipped and the new dashboard tests never fire on a PR (GitHub issue #120). Plan 07-02 repoints `detect` at `runtime/dashboard`; until that lands, these three tests are local-only.

## Next Phase Readiness

Ready. Downstream Phase 7 plans can now read `identity.provisioning_url`, `identity.credentials_endpoint`, `identity.role_alias` and `identity.poll_interval_seconds` from the merged config and can cite ADR-0007 for the issuance, renewal and revocation contract.

**Carried forward:**
- ADR-0007 stays Proposed until 07-09 supplies staging evidence and a real bill.
- Open question: does AWS preserve the CSR subject CN verbatim? Authorization deliberately does not depend on it (it binds to Thing name + certificate ID), so this is a documentation gap, not a design risk. 07-09 answers it with `openssl x509 -noout -subject`.
- The owner-account question (the customer half of IDENT-02) is explicitly deferred to Phase 8. IDENT-02 does not close with Phase 7.
- This plan's net diff plus this SUMMARY lands around 450 lines, over the 400-line `size-check` **warning** threshold but far under the 1500 hard cap.

---
*Phase: 07-device-identity-and-pki*
*Completed: 2026-09-10*
