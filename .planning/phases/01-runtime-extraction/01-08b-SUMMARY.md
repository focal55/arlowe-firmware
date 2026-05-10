---
plan: 08b
phase: 01-runtime-extraction
status: COMPLETE
pr: (pending)
---

# Plan 08b Summary — Dashboard rewrites: /api/voice + .env.example + README

## What was done

### Task 1 — /api/voice SYSTEMCTL_MODE knob

Rewrote `runtime/dashboard/app/api/voice/route.ts`:

- Replaced `execSync` with `execFile` + `promisify` (safer: no shell injection surface).
- Extracted `systemctlArgs()` helper that branches on `ARLOWE_SYSTEMCTL_MODE`:
  - `user` (Phase 1 default): passes `--user` flag to systemctl
  - `system` (Phase 11+ production image): drops the flag
- Documented the tech-debt rationale in a comment referencing research R7 and the Phase 3/Phase 11 milestones.
- Verified no founder literals anywhere in the file.

### Task 2 — .env.example and README.md

`.env.example` documents four knobs:
- `ARLOWE_CONFIG_PATH` — config overlay path (default `/etc/arlowe/config.yml`)
- `ARLOWE_LOGS_DIR` — voice log directory (default `/var/lib/arlowe/logs`)
- `ARLOWE_SYSTEMCTL_MODE` — `user` or `system`; controls voice/service invocation mode
- `DASHBOARD_API_SECRET` — bearer token for destructive routes; Phase 7 wires auth

No secrets, no founder values.

`runtime/dashboard/README.md` (101 lines) documents:
- Module purpose and port (3000)
- 4-route navigation (Overview, NPU Lab, Logs, Connectivity)
- Runtime reads table: `/etc/arlowe/config.yml`, `/var/lib/arlowe/logs/`, journalctl, axcl-smi, systemctl, nmcli
- Runtime writes table: `/etc/arlowe/config.yml` (atomic POST /api/config)
- journalctl service set (7 services)
- Environment variable table
- How to run locally on arlowe-1
- Full API surface table (11 endpoints)
- Authentication status (Phase 7 deferred)

### TODO(plan-08) markers

Resolved:
- `app/page.tsx` — stale TODO comment removed; the fetches were already correct (health + voice)

Outstanding plan-08 TODO resolved in plan 08 (PR #37):
- `app/api/config/route.ts` — repointed to `/etc/arlowe/config.yml` (done in plan 08)
- `app/api/logs/route.ts` — repointed to `/var/lib/arlowe/logs/`, workforce paths dropped (done in plan 08)

Remaining deferred TODOs (not plan-08 markers):
- `app/api/config/route.ts:32` — `// TODO(phase-4): validate against config/schema.yml` — explicitly deferred to Phase 4

### Task 3 — Final verification

```
pnpm build: PASS
Founder-literal sweep (dashboard-wide, excl. node_modules/.next): 0 hits
```

## Dashboard surface tally (Plans 06–08b combined)

| Category | API routes | Pages | Components |
|---|---:|---:|---:|
| KEEP | 9 | 3 | 14 |
| REWRITE (completed) | 3 | 3 | 1 |
| DELETE (completed in plan 07) | 15 | 7 | 8 |
| **Total** | **27** | **13** | **23** |

(Stats page downgraded from REWRITE to DELETE per audit Q2 recommendation.)

## EXTRACT-06: COMPLETE

Plans 06 (audit), 07 (delete pass), 08 (backend rewrites), and 08b (voice knob + env + README) are all done. The dashboard is standalone-buildable, dev-serveable, and ships zero founder literals.
