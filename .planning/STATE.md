# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-04-30)

**Core value:** A factory-fresh Pi 5 + AX accelerator + Whisplay can flash this image, boot, pair to an owner, and run wake -> STT -> LLM -> TTS -> face entirely on-device, with no founder identity present anywhere in the image.
**Current focus:** Phase 3 (service user and filesystem layout) complete, passed-with-notes (#73–#75 cleanups merged). Phase 4 (config overlay) is next — planning now.

## Current Position

Phase: 3 of 12 (Service user and filesystem layout) — COMPLETE (passed-with-notes)
Plan: 5 of 5 in Phase 3
Status: Phase 3 closed 2026-06-07. SC1–3 via Docker testbed; SC4 verified on REAL hardware via the arlowe-1 staging harness (plan 03-05). Phase-4 cleanups #73–#75 already merged: supplementary groups tightened to {audio,gpio,spi}; Axera NPU nodes → 0660 root:arlowe (broken axcl-deb rule removed by installer); founder-absence check split into image-only 06-image-sanitization.sh.
Last activity: 2026-06-07 -- PRs #68–#72 (Phase 3) + #76–#77 (cleanups) merged; sanitize gate green on main; planning Phase 4.

Progress: Phase 1 [██████████] 100% qualified; Phase 2 [██████████] 100%; Phase 3 [██████████] 100% complete; Phase 4 [░░░░░░░░░░] planning

## Performance Metrics

**Velocity:**
- Phase 1: 15 plans, ~3 days agent + 1 finalizer day
- Phase 2: 4 plans, 1 day (parallel fan-out of 02-01..02-03, then 02-04 SC4 cleanup)

**By Phase:**

| Phase | Plans | Done | Status |
|-------|-------|------|--------|
| 1 | 15 | 15 | Complete (qualified) |
| 2 | 4 | 4 | Complete |
| 3 | 5 | 5 | Complete (passed-with-notes) |
| 4 | TBD | 0 | Planning |

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
- **Phase 3 layout** (resolved): `arlowe` system user (uid<1000, HOME=/var/lib/arlowe, nologin); code root-owned at `/opt/arlowe`, state at `/var/lib/arlowe`; six system-level units with PrivateTmp/ProtectSystem=strict/ReadWritePaths sandboxing; CLI symlinks at `/usr/local/sbin/arlowe-*`; udev (gpio/spi/axera) + polkit (arlowe→systemctl arlowe-*/qwen-*/whisper-stt) rules. SC4 (write-deny outside /var/lib/arlowe) verified on real hardware.
- **Phase 3 group set** (resolved #73): the `arlowe` *user* is created with supplementary groups {audio, gpio, spi} only; `video`+`dialout` dropped (unused on hardware — no /dev/fb0, WM8960 codec is I2C/in-kernel). **Residual debt:** `units/arlowe-face.service` still declares `SupplementaryGroups=gpio spi video` + `DeviceAllow=/dev/fb0` — #73 fixed the user-creation + assertions but missed the unit, so the face *service process* still gets `video` at runtime. Tracked for cleanup (see todos / new issue); intentionally NOT touched by Phase 4.
- **Axera NPU perms** (resolved #75): nodes 0660 root:arlowe; `install-arlowe-udev-polkit.sh` removes the axcl deb's broken `GROUP="<users>"` rule. Runtime verification deferred to Phase 6 image (can't verify on the focal55 dev Pi without breaking the daily-driver LLM).

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

Last session: 2026-06-07
Stopped at: Phase 3 fully complete (5 plans merged via PRs #68–#72; SC4 hardware-verified). Phase-4 cleanups #73–#75 merged; sanitize gate green on main. Now planning Phase 4 (config overlay).
Resume file: `.planning/phases/04-config-overlay/` (being created)
