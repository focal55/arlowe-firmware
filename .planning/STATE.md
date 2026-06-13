# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-04-30)

**Core value:** A factory-fresh Pi 5 + AX accelerator + Whisplay can flash this image, boot, pair to an owner, and run wake -> STT -> LLM -> TTS -> face entirely on-device, with no founder identity present anywhere in the image.
**Current focus:** Phase 5 (audio device auto-detection) COMPLETE (passed-with-notes). 7 plans merged (PRs #95/#96 for 05-01, #97-#101 for 05-02..06, #104 for 05-07). Phase 6 (image build with A/B partitions) is next — ready to plan (`/gsd:plan-phase 6`).

## Current Position

Phase: 5 of 12 (Audio device auto-detection) — COMPLETE (passed-with-notes)
Plan: 7 of 7 in Phase 5
Status: Phase 5 closed 2026-06-13. plughw:2,0 eliminated end-to-end: arlowe_audio enumeration+auto-pick+stable-card-id (05-01, #95 + #96 hardening), Python consumers (05-02 #98, incl. dual-pa.open wake-word fix), bash CLI (05-03 #97), dashboard picker+/api/audio/devices (05-04 #100, Opus-reviewed), udev hotplug (05-05 #99, Opus-reviewed), boot-check sentinel (05-06 #101), hardware runbook (05-07 #104). SC2 reframed (Pi 5 has no 3.5mm jack → wm8960 codec → HDMI); on-Pi SC1-SC4 run deferred to a hardware checkpoint per Phase 1/3/4 precedent (procedure: docs/operations/phase-5-audio.md). Next: Phase 6 (image build) — depends on Phase 1/3/4 (all done).
Last activity: 2026-06-13 -- Phase 5 executed via /workforce-tick loop (5 impl PRs, 2 Opus security reviews, 2 fix-and-re-review cycles caught real bugs) + #104 runbook; all merged; ROADMAP/STATE flipped to complete. Survived a resume-state reconciliation, an accidental-merge recovery, and a worktree sweep.

Progress: Phase 1 [██████████] 100% qualified; Phase 2 [██████████] 100%; Phase 3 [██████████] 100%; Phase 4 [██████████] 100% (passed-with-notes); Phase 5 [██████████] 100% (passed-with-notes); Phase 6 [░░░░░░░░░░] not started

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
| 5 | 7 | 7 | Complete (passed-with-notes; on-Pi SC1-4 deferred) |
| 6 | TBD | 0 | Not started |

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

Phase 5 follow-up chores (GitHub backlog, p2):
- #102 — dashboard CONFIG_DEFAULTS duplicates config/defaults.yml; single-source it
- #103 — auto_collect.py docstring missing ARLOWE_PLAY_DEVICE
- #94 SC1-SC4 on-Pi verification — DEFERRED to a hardware checkpoint (runbook: docs/operations/phase-5-audio.md)

In `.planning/todos/done/`:
- F5-adr-0001-why-option-2-internal-contradiction.md — closed by Plan 02-04 (ADR doc rewritten)

Workforce-infra debt tracked in Claude's memory store:
- Board-sync workflow needs PAT with `Projects: read/write` scope (`PROJECTS_TOKEN` secret) — owner must mint.
- pr-reviewer agents can't merge on the user ProjectV2 — Joe merges manually.

### Blockers/Concerns

- ADR pending (Phase 7): specific managed-PKI service selection.
- ADR pending (Phase 8): pairing channel mechanism (Wi-Fi captive portal vs. BLE).

## Session Continuity

Last session: 2026-06-13
Stopped at: Phase 5 COMPLETE — executed end-to-end via the `/workforce-tick` cron loop (5 impl PRs #97-#101, two `package:security` Opus reviews, two fix-and-re-review cycles that caught real bugs: a dead dashboard Save (422) and a journal-eating `2>&1`). #104 runbook merged. ROADMAP + STATE flipped to complete. Loop STOPPED (cron cancelled). Filed p2 chores #102/#103.
Resume file: none. Backlog: #78 (face-unit video/fb0 cleanup, type:bug), #102/#103 (Phase 5 p2 chores), #94 on-Pi SC run deferred. Stale agent worktrees in `.claude/worktrees/` accumulated this session — sweep pending. Loop is OFF.
Next action: `/gsd:plan-phase 6` (image build with A/B partitions). Depends on Phase 1 (runtime) + Phase 3 (fs layout) + Phase 4 (defaults.yml) — all done. No CONTEXT.md for Phase 6 yet → consider `/gsd:discuss-phase 6` first (pi-gen, A/B partitions, reproducibility are real unknowns).
