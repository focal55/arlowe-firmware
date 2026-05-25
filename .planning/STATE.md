# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-04-30)

**Core value:** A factory-fresh Pi 5 + AX accelerator + Whisplay can flash this image, boot, pair to an owner, and run wake -> STT -> LLM -> TTS -> face entirely on-device, with no founder identity present anywhere in the image.
**Current focus:** Phase 1 complete (qualified). Ready for Phase 2 (sanitization gate).

## Current Position

Phase: 1 of 12 (Runtime extraction) — COMPLETE (qualified)
Plan: 15 of 15 in current phase
Status: Phase 1 closed 2026-05-17 as passed-with-notes; SC4 hardware-loop deferred to Phase 12 + plan F4
Last activity: 2026-05-17 -- branch `plan-13/smoke-test` (5 commits) ready to PR; phase metadata committed

Progress: [██████████] 100% (15/15 plans done, qualified)

## Performance Metrics

**Velocity:**
- Total plans completed: 15 (01, 02, 03, 03b, 04, 05, 06, 07, 08, 08b, 09, 10, 11, 12, 13)
- Plan 13 closed as passed-with-notes after 3 Task 4 retry iterations surfaced 4 staging-scaffolding bugs (3 fixed in-iteration, 1 deferred to F1)
- Total execution time: ~3 days of agentic workforce dispatch + 1 finalizer day

**By Phase:**

| Phase | Plans | Done | Avg/Plan |
|-------|-------|------|----------|
| 1 | 15 | 15 | ~3hr agent + queue time |

**Recent Trend:**
- Wave 1 (Plan 01): scaffold — 1 PR
- Wave 2 (Plans 02, 03, 03b, 05, 06, 09, 10, 11, 12): parallel fan-out — 9 PRs in one batch
- Wave 3 (Plans 04, 07): STT/TTS + dashboard delete pass — 4 PRs (07 split into 3 stacked)
- Wave 4 (Plan 08): dashboard /api/config + /api/logs rewrite — 1 PR
- Wave 5 (Plan 08b): dashboard /api/voice + .env.example + README — 1 PR
- Wave 6 (Plan 13): smoke test — 3 retry iterations on hardware, closed passed-with-notes; branch `plan-13/smoke-test` (5 commits) ready to PR
- Plus 3 infra PRs (CI fixes #18, #29, #39 — Node-job gating, cap raise, lockfile exclusion)

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- **ADR-0001** (resolved): option-2 chosen for `openai_wrapper.py`. Router points at ax-llm `/api/chat` native (`localhost:8000`), not `/v1/chat/completions`. `qwen-openai.service` deprecated.
- **ADR-0002** (resolved): `arlowe-scheduled-summary.service` stripped from firmware.
- **WhisPlay driver**: PiSugar (Apache 2.0). Strategy A — vendor at image build (Phase 6). Runtime face.py already honors `ARLOWE_WHISPLAY_DRIVER_PATH` (default `/opt/arlowe/third_party/whisplay-driver`).
- **ax-llm submodule**: pinned at `df75c34c…` on `axcl-context` branch.
- **axcl deb**: SHA-256 pinned in `third_party/axcl/manifest.yml`, never committed (Strategy C — user supplies). `scripts/verify-third-party.sh` gates.
- **Dashboard audit**: 12 of 27 API routes retained; 4 of 13 pages retained. OpenClaw/iol-monorepo couplings stripped.
- **Plan 13 closure**: passed-with-notes; hardware wake-phrase loop not exercised this session. Acceptance: Phase 1 SC4 qualified-pass per plan front-matter; fully-sanitized first-flash test owned by Phase 12; hybrid live/test re-run unblocked once F2 lands.

### Pending Todos

In `.planning/todos/pending/`:
- F1-port-8080-env-override.md — Phase 2 or Phase 5 (face_service.py hardcoded port)
- F2-vendor-whisplay-driver.md — Phase 6 (image build)
- F3-arlowe1-persistent-journald.md — workforce infra (dev-env)
- F4-plan-13-rerun-post-phase-6.md — post-Phase-6 hybrid smoke-test re-run

Workforce-infra debt tracked in Claude's memory store:
- Board-sync workflow needs PAT with `Projects: read/write` scope (`PROJECTS_TOKEN` secret) — owner must mint.
- OpenClaw bearer token leaked in `iol-monorepo` source — separate repo, should rotate.

### Blockers/Concerns

- **`plan-13/smoke-test` branch not yet PR'd**: 5 commits ahead of main, ready for owner-initiated `gh pr create`.
- ADR pending (Phase 7): specific managed-PKI service selection.
- ADR pending (Phase 8): pairing channel mechanism (Wi-Fi captive portal vs. BLE).

## Session Continuity

Last session: 2026-05-17
Stopped at: Phase 1 closed as passed-with-notes. Plan 13 SUMMARY written; smoke-test doc Observed-run section finalized; F1-F4 deferred items captured as todos. Next step: open PR for `plan-13/smoke-test`, then `/gsd:discuss-phase 2` for sanitization-gate planning.
Resume file: branch `plan-13/smoke-test`, `.planning/phases/01-runtime-extraction/01-13-SUMMARY.md`
