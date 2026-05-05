---
plan: 07
phase: 01-runtime-extraction
type: summary
status: complete
pr: TBD
---

# Plan 07 Summary — Dashboard delete pass

## What was done

Copied `arlowe-dashboard` from `/Users/joeybarrajr/projects/iol-monorepo/packages/arlowe-dashboard/` to `runtime/dashboard/` and executed the full delete pass per `docs/architecture/dashboard-extraction-audit.md`.

## Counts

- **API route directories deleted:** 15 (`costs`, `cron`, `cron/run`, `gateway/restart`, `sub-agents` (3 routes), `subagent-types`, `tasks/active`, `usage`, `stats`, `iol/stats`, `playwright-reports` (4 routes))
- **Pages deleted:** 8 (`iol`, `sub-agents`, `subagent-types`, `cron`, `costs`, `pathway/[id]`, `testing`, `stats` per Q2 default, `config` per Q1 default)
- **Components deleted:** 10 (`ActiveTasksPanel`, `GlobalMetrics`, `ModelUsageChart`, `PathwayVisualization`, `RequestLog`, `KillConfirmModal`, `SessionHistoryModal`, `PlaywrightReportsViewer`, `ProfileSwitcher` (orphan per audit), `app/types/playwright.ts` (orphan))
- **Tests deleted:** 2 (`active-tasks.spec.ts`, `costs.spec.ts`)
- **Estimated LOC removed:** ~4,200 (per audit estimate)
- **Surviving source LOC (TS/TSX/CSS):** ~3,831

## Files annotated with TODO(plan-08)

The following REWRITE-flagged files retain founder paths but are marked for plan 08:

- `app/api/logs/route.ts` — `~/.openclaw/logs`, `~/.openclaw/agents/main/sessions`, `~/.openclaw/cron/runs` paths; journalctl service list (openclaw-gateway removed; arlowe-* services remain)
- `app/api/config/route.ts` — `~/.openclaw/workspace` path and `ALLOWED_FILES` list (SOUL/AGENTS/USER/etc.)
- `app/page.tsx` — `fetchData` function has TODO for plan-08 payload expansion

## Deviations from audit

- **Config page (Q1):** Applied the recommended default — `app/config/page.tsx` deleted. The `/api/config` API route is left (REWRITE, plan 08). Config UI deferred to Phase 11.
- **Stats page (Q2):** Applied the recommended default — `app/stats/page.tsx` deleted. Phase 11 can introduce a voice-activity stats page if needed.
- **ProfileSwitcher.tsx:** Orphan check confirmed it had zero imports in surviving files. Downgraded to DELETE per audit guidance.
- **ProviderBadge.tsx `openclaw:` entry:** 1-line delete applied in plan 07 (audit said plan 07 or 08 could handle it; cleaned up here since it was a trivial remove).

## Build status

`pnpm install && pnpm build` passes. Output:

- 9 KEEP API routes + 3 REWRITE API routes (12 total — correct)
- 4 pages: `/`, `/connectivity`, `/logs`, `/npu`
- TypeScript clean, no compile errors
- `.next/` artifact removed post-verify

## Remaining founder paths (plan 08 worklist)

All in REWRITE-flagged files:
- `/home/focal55/whisplay/logs` → `/var/lib/arlowe/logs/` (plan 08)
- `/home/focal55/.openclaw/logs` → remove (plan 08)
- `/home/focal55/.openclaw/agents/main/sessions` → remove (plan 08)
- `/home/focal55/.openclaw/cron/runs` → remove (plan 08)
- `/home/focal55/.openclaw/workspace` → `/etc/arlowe/config.yml` (plan 08)
