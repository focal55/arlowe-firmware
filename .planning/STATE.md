# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-04-30)

**Core value:** A factory-fresh Pi 5 + AX accelerator + Whisplay can flash this image, boot, pair to an owner, and run wake -> STT -> LLM -> TTS -> face entirely on-device, with no founder identity present anywhere in the image.
**Current focus:** Phase 2 complete. Phase 3 (service user and filesystem layout) planned, ready to execute.

## Current Position

Phase: 2 of 12 (Sanitization gate) — COMPLETE
Plan: 4 of 4 in Phase 2
Status: Phase 2 closed 2026-05-27. All four SC criteria met (grep gate, units gate, dashboard Playwright gate, runtime/ zero banned literals). Phase 3 plans (5) and research committed in this PR.
Last activity: 2026-05-27 -- Phase 2 PRs #58-#61 all merged; Phase 3 plans ready to seed as issues via /issue-from-plan 3

Progress: Phase 1 [██████████] 100% qualified; Phase 2 [██████████] 100% complete; Phase 3 [░░░░░░░░░░] 0/5 planned

## Performance Metrics

**Velocity:**
- Phase 1: 15 plans, ~3 days agent + 1 finalizer day
- Phase 2: 4 plans, 1 day (parallel fan-out of 02-01..02-03, then 02-04 SC4 cleanup)

**By Phase:**

| Phase | Plans | Done | Status |
|-------|-------|------|--------|
| 1 | 15 | 15 | Complete (qualified) |
| 2 | 4 | 4 | Complete |
| 3 | 5 | 0 | Planned |

**Recent Trend (Phase 2):**
- 02-01: grep gate runner, allow-list, CI workflow (#58)
- 02-02: systemd unit-name block + --scan-dir reuse (#59)
- 02-03: Playwright dashboard rendered-text gate (#60)
- 02-04: SC4 runtime/ cleanup + F5 ADR-0001 fix (#61) — closes Phase 2

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- **ADR-0001** (resolved): option-2 chosen for `openai_wrapper.py`. Router points at ax-llm `/api/chat` native (`localhost:8000`), not `/v1/chat/completions`. `qwen-openai.service` deprecated.
- **ADR-0002** (resolved): `arlowe-scheduled-summary.service` stripped from firmware.
- **Phase 2 sanitization gate** (resolved): three CI jobs (banlist-and-units, self-test, dashboard-rendered-text) gate every PR. `.sanitize-allowlist` codifies exception paths. Provenance comments in `runtime/*/requirements.txt` and `tts/manifest.yml` allow-listed by Plan 02-04 disposition matrix.
- **WhisPlay driver**: PiSugar (Apache 2.0). Strategy A — vendor at image build (Phase 6).
- **ax-llm submodule**: pinned at `df75c34c…` on `axcl-context` branch.
- **axcl deb**: SHA-256 pinned in `third_party/axcl/manifest.yml`, never committed (Strategy C). `scripts/verify-third-party.sh` gates.

### Pending Todos

In `.planning/todos/pending/`:
- F1-port-8080-env-override.md — Phase 2 or Phase 5 (face_service.py hardcoded port)
- F2-vendor-whisplay-driver.md — Phase 6 (image build)
- F3-arlowe1-persistent-journald.md — workforce infra (dev-env)
- F4-plan-13-rerun-post-phase-6.md — post-Phase-6 hybrid smoke-test re-run

In `.planning/todos/done/`:
- F5-adr-0001-why-option-2-internal-contradiction.md — closed by Plan 02-04 (ADR doc rewritten)

Workforce-infra debt tracked in Claude's memory store:
- Board-sync workflow needs PAT with `Projects: read/write` scope (`PROJECTS_TOKEN` secret) — owner must mint.
- OpenClaw bearer token leaked in `iol-monorepo` source — separate repo, should rotate.

### Blockers/Concerns

- ADR pending (Phase 7): specific managed-PKI service selection.
- ADR pending (Phase 8): pairing channel mechanism (Wi-Fi captive portal vs. BLE).

## Session Continuity

Last session: 2026-05-27
Stopped at: Phase 2 closed. Phase 3 research + 5 plans drafted and committed. Branch `chore/phase-3-seed` opened to land planning artifacts. Next step: merge this PR, then run `/issue-from-plan 3` to populate board for workforce-tick dispatch.
Resume file: branch `chore/phase-3-seed`, `.planning/phases/03-service-user-and-filesystem-layout/`
