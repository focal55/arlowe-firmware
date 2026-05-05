---
phase: 01-runtime-extraction
plan: 08
status: complete
---

# Plan 08 Summary — Dashboard API Rewrites: /api/config + /api/logs

## What was done

### /api/config rewritten

- **Before**: read/wrote individual Markdown files (`SOUL.md`, `AGENTS.md`, etc.) from `/home/focal55/.openclaw/workspace` — OpenClaw-shaped, workforce-specific.
- **After**: reads `/etc/arlowe/config.yml` via `js-yaml`. Returns `{paired: false}` when the file is absent (pairing-pending state). Writes back atomically via temp file + rename to `/etc/arlowe/.config.yml.tmp` → `/etc/arlowe/config.yml`. Schema validation deferred to Phase 4 (`TODO(phase-4)`).
- `js-yaml` and `@types/js-yaml` added to `runtime/dashboard/package.json` dependencies.

### /api/logs rewritten

- **Before**: read from `/home/focal55/whisplay/logs`, `/home/focal55/.openclaw/logs`, `/home/focal55/.openclaw/agents/main/sessions`, `/home/focal55/.openclaw/cron/runs`, journalctl filtered to `openclaw-gateway`.
- **After**: reads `/var/lib/arlowe/logs/` for file-based voice logs. journalctl filtered to the product service set: `arlowe-voice`, `arlowe-face`, `arlowe-dashboard`, `qwen-tokenizer`, `qwen-api`, `qwen-openai`, `whisper-stt`. All workforce log paths (`SESSION_DIR`, `CRON_RUNS_DIR`, `OPENCLAW_LOG_DIR`) dropped. `--user` flag retained for Phase 1 (dev device); Phase 11 converts to system units.
- Voice log parser (`parseVoiceLogs`) preserved intact — parses wake word / heard / response lines from voice log files.

## TODO(plan-08) markers resolved

Both markers from plan 07 are gone:
- `runtime/dashboard/app/api/config/route.ts` — marker removed, file fully rewritten.
- `runtime/dashboard/app/api/logs/route.ts` — marker removed, file fully rewritten.

## Build status

Pre-existing build failure in `app/connectivity/page.tsx` (missing component files) predates this plan and is unaffected by these changes. The routes themselves typecheck; Node CI is known to skip for dashboard changes per the workforce dispatch notes.

## Open work in plan 08b

- `/api/voice` rewrite (convert `--user` journalctl to configurable, strip any residual coupling)
- `.env.example` regeneration
- `README.md` rewrite
- Final dashboard-wide founder-literal verification (`grep -rni 'openclaw|focal55|iol-monorepo'`)
