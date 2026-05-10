# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-04-30)

**Core value:** A factory-fresh Pi 5 + AX accelerator + Whisplay can flash this image, boot, pair to an owner, and run wake -> STT -> LLM -> TTS -> face entirely on-device, with no founder identity present anywhere in the image.
**Current focus:** Phase 1 (Runtime extraction) — final manual smoke test

## Current Position

Phase: 1 of 12 (Runtime extraction)
Plan: 14 of 15 in current phase
Status: Plan 13 (manual smoke test) outstanding; requires owner on arlowe-1
Last activity: 2026-05-10 -- PR #40 (Plan 08b) merged; all autonomous extraction work complete

Progress: [█████████░] 93% (14/15 plans done)

## Performance Metrics

**Velocity:**
- Total plans completed: 14 (01, 02, 03, 03b, 04, 05, 06, 07, 08, 08b, 09, 10, 11, 12)
- Plans remaining in Phase 1: 1 (13 — smoke test, manual)
- Total execution time: ~3 days of agentic workforce dispatch (2026-05-03 to 2026-05-05)

**By Phase:**

| Phase | Plans | Done | Avg/Plan |
|-------|-------|------|----------|
| 1 | 15 | 14 | ~3hr agent + queue time |

**Recent Trend:**
- Wave 1 (Plan 01): scaffold — 1 PR
- Wave 2 (Plans 02, 03, 03b, 05, 06, 09, 10, 11, 12): parallel fan-out — 9 PRs in one batch
- Wave 3 (Plans 04, 07): STT/TTS + dashboard delete pass — 4 PRs (07 split into 3 stacked)
- Wave 4 (Plan 08): dashboard /api/config + /api/logs rewrite — 1 PR
- Wave 5 (Plan 08b): dashboard /api/voice + .env.example + README — 1 PR
- Wave 6 (Plan 13): pending — manual smoke test on arlowe-1
- Plus 3 infra PRs (CI fixes #18, #29, #39 — Node-job gating, cap raise, lockfile exclusion)

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- **ADR-0001** (resolved in part): `iol_router.py` extracted as `runtime/llm/router.py` with founder paths excised; `openai_wrapper.py` resolution pending Plan 13 Task 1 (option-2 recommended).
- **ADR-0002** (resolved): `arlowe-scheduled-summary.service` stripped from firmware (no product value, costs $, banned-literal target). Phase 2 SANIT-08 follow-up flagged.
- **WhisPlay driver**: PiSugar (Apache 2.0). Strategy A — vendor at image build (Phase 6).
- **ax-llm submodule**: pinned at `df75c34c…` on `axcl-context` branch.
- **axcl deb**: SHA-256 pinned in `third_party/axcl/manifest.yml`, never committed (Strategy C — user supplies). `scripts/verify-third-party.sh` gates.
- **Dashboard audit**: 12 of 27 API routes retained; 4 of 13 pages retained. OpenClaw/iol-monorepo couplings stripped.
- Roadmap: Sanitization CI gate lands in Phase 2 so banned literals can't sneak back.
- Roadmap: A/B system partition layout designed and provisioned in v1 even though OS OTA delivery defers to v2+.
- Roadmap: Managed-PKI provisioning server (no self-rolled CA); device cert issued at first-boot pairing.
- Roadmap: Owner-consented support access built into v1; default-deny, time-bound, audit-logged.

### Pending Todos

None in `.planning/todos/`. Workforce-infra debt tracked in Claude's memory store:
- Board-sync workflow needs PAT with `Projects: read/write` scope (`PROJECTS_TOKEN` secret) — owner must mint.
- OpenClaw bearer token leaked in `iol-monorepo` source — separate repo, should rotate.
- Plan 13 deferred: `openai_wrapper.py` resolution and on-device smoke test.

### Blockers/Concerns

- **Plan 13 awaiting owner**: smoke test requires Joe on arlowe-1 (wake phrase, face observation, tear-down). `agent:verifier` + `status:needs-human`.
- ADR pending (Phase 7): specific managed-PKI service selection.
- ADR pending (Phase 8): pairing channel mechanism (Wi-Fi captive portal vs. BLE).

## Session Continuity

Last session: 2026-05-10
Stopped at: All autonomous extraction work merged. Plan 13 prep (smoke-test runbook draft) staged in this PR. Next step is owner-driven Plan 13 Task 1 (option decision) → Task 2 (router.py edit + ADR update) → Task 3 (stage on arlowe-1) → Task 4 (run test) → Task 5 (record observed run). Phase 1 closes when Task 5 lands.
Resume file: `docs/operations/phase-1-smoke-test.md` (runbook with Observed-run section pending)
