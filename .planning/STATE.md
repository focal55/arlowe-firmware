# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-04-30)

**Core value:** A factory-fresh Pi 5 + AX accelerator + Whisplay can flash this image, boot, pair to an owner, and run wake -> STT -> LLM -> TTS -> face entirely on-device, with no founder identity present anywhere in the image.
**Current focus:** Phase 4 (config overlay) COMPLETE (passed-with-notes) — all 4 plans merged (PRs #84/#85/#86/#87). Phase 5 (audio device auto-detection) is next — ready to plan (`/gsd:plan-phase 5`).

## Current Position

Phase: 4 of 12 (Config overlay) — COMPLETE (passed-with-notes)
Plan: 4 of 4 in Phase 4
Status: Phase 4 closed 2026-06-07. 04-01 (#80/PR#84), 04-02 (#81/PR#85, package:security), 04-03 (#82/PR#86), 04-04 (#83/PR#87) all MERGED. SC4 on-device persona-knob verification deferred to Phase 6/12 — arlowe-1 has no arlowe layout/venvs to run it; procedure written in docs/operations/phase-4-persona-slice.md. Next: Phase 5 (audio auto-detection) — depends on Phase 4 (done) + Phase 3 (done).
Last activity: 2026-06-07 -- PR #87 merged; Phase 4 marked complete (ROADMAP + STATE flipped). Local main synced to origin (307976d). Two stale Phase-1 worktrees + #78 still open.

Progress: Phase 1 [██████████] 100% qualified; Phase 2 [██████████] 100%; Phase 3 [██████████] 100%; Phase 4 [██████████] 100% complete (passed-with-notes); Phase 5 [░░░░░░░░░░] not started

## Performance Metrics

**Velocity:**
- Phase 1: 15 plans, ~3 days agent + 1 finalizer day
- Phase 2: 4 plans, 1 day (parallel fan-out of 02-01..02-03, then 02-04 SC4 cleanup)
- Phase 4: 4 plans, 1 day (04-01 schema/loader → 04-02 install/security → 04-03 dashboard write → 04-04 persona slice)

**By Phase:**

| Phase | Plans | Done | Status |
|-------|-------|------|--------|
| 1 | 15 | 15 | Complete (qualified) |
| 2 | 4 | 4 | Complete |
| 3 | 5 | 5 | Complete (passed-with-notes) |
| 4 | 4 | 4 | Complete (passed-with-notes) |
| 5 | TBD | 0 | Not started |

**Recent Trend (Phase 4):**
- 04-01: schema.yml + defaults.yml + shared Python loader/validator (#84)
- 04-02: ADR-0003 loosen-perms + /etc/arlowe install + phase-4 docker harness (#85, package:security)
- 04-03: ajv validate-before-write + atomic write + knob→restart (#86)
- 04-04: persona live slice + ExecStartPre fail-fast validators (#87) — closes Phase 4

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- **ADR-0001** (resolved): option-2 chosen for `openai_wrapper.py`. Router points at ax-llm `/api/chat` native (`localhost:8000`), not `/v1/chat/completions`. `qwen-openai.service` deprecated.
- **ADR-0002** (resolved): `arlowe-scheduled-summary.service` stripped from firmware.
- **ADR-0003** (resolved, Phase 4): loosen-perms for dashboard→/etc/arlowe/config.yml write; `ota.channel_url` + `support_mode.*` flagged for Phase 10 re-hardening.
- **Phase 4 schema** (resolved): one `config/schema.yml` (JSON-Schema-in-YAML), validated by jsonschema (Python) + ajv (dashboard). SC4 live knob = persona only; other CONFIG-06 knobs defined+validated, consumed in Phases 7–11. ExecStartPre `arlowe_config_validate` on the three python-bearing units (arlowe-face, arlowe-voice via voice venv; qwen-tokenizer via llm venv); qwen-api.service untouched (native, no venv).
- **Phase 4 SC4 deferral** (resolved): on-device persona-knob end-to-end check deferred to Phase 6/12 — arlowe-1 has no arlowe layout to run it; mirrors Phase 1 SC4 → Phase 12 and Phase 3 SC4 → staging.
- **Phase 2 sanitization gate** (resolved): three CI jobs (banlist-and-units, self-test, dashboard-rendered-text) gate every PR. `.sanitize-allowlist` codifies exception paths.
- **WhisPlay driver**: PiSugar (Apache 2.0). Strategy A — vendor at image build (Phase 6).
- **ax-llm submodule**: pinned at `df75c34c…` on `axcl-context` branch.
- **axcl deb**: SHA-256 pinned in `third_party/axcl/manifest.yml`, never committed (Strategy C). `scripts/verify-third-party.sh` gates.
- **Phase 3 layout** (resolved): `arlowe` system user (uid<1000, HOME=/var/lib/arlowe, nologin); code root-owned at `/opt/arlowe`, state at `/var/lib/arlowe`; six system-level units with PrivateTmp/ProtectSystem=strict/ReadWritePaths sandboxing; CLI symlinks at `/usr/local/sbin/arlowe-*`; udev (gpio/spi/axera) + polkit rules. SC4 verified on real hardware.
- **Phase 3 group set** (resolved #73): the `arlowe` *user* gets supplementary groups {audio, gpio, spi}; video+dialout dropped. **Residual debt (#78):** `units/arlowe-face.service` still declares `SupplementaryGroups=...video` + `DeviceAllow=/dev/fb0` — #73 missed the unit file. Open backlog bug, NOT auto-dispatched.
- **Axera NPU perms** (resolved #75): nodes 0660 root:arlowe; `install-arlowe-udev-polkit.sh` removes the axcl deb's broken `GROUP="<users>"` rule. Runtime verification deferred to Phase 6.

### Pending Todos

In `.planning/todos/pending/`:
- F1-port-8080-env-override.md — Phase 5-adjacent (face_service.py hardcoded port)
- F2-vendor-whisplay-driver.md — Phase 6 (image build)
- F3-arlowe1-persistent-journald.md — workforce infra (dev-env)
- F4-plan-13-rerun-post-phase-6.md — post-Phase-6 hybrid smoke-test re-run

In `.planning/todos/done/`:
- F5-adr-0001-why-option-2-internal-contradiction.md — closed by Plan 02-04 (ADR doc rewritten)

Workforce-infra debt tracked in Claude's memory store:
- Board-sync workflow needs PAT with `Projects: read/write` scope (`PROJECTS_TOKEN` secret) — owner must mint.
- pr-reviewer agents can't merge on the user ProjectV2 — Joe merges manually.

### Blockers/Concerns

- ADR pending (Phase 7): specific managed-PKI service selection.
- ADR pending (Phase 8): pairing channel mechanism (Wi-Fi captive portal vs. BLE).

## Session Continuity

Last session: 2026-06-07
Stopped at: Resumed session — confirmed PR #87 MERGED + #83 CLOSED. Synced local main to origin/main (307976d); discarded 2 stale planning-only WIP commits (preserved on branch `backup-04-04-handoff`). Flipped ROADMAP Phase 4 → [x] and STATE → Phase 4 complete. Phase 5 ready to plan.
Resume file: none (Phase 4 checkpoint consumed). Backlog: #78 (face-unit video/fb0 cleanup, type:bug), two stale locked Phase-1 worktrees in .claude/worktrees/ to sweep. Loop is OFF — run /workforce-tick manually.
Next action: `/gsd:plan-phase 5` (audio device auto-detection).
