# Dashboard Extraction Audit

**Authored:** 2026-05-02
**Phase:** 1, plan 06
**Issue:** #6
**Source tree:** `/Users/joeybarrajr/projects/iol-monorepo/packages/arlowe-dashboard/`
**Targets plans 07 (delete pass), 08 (API rewrite pass), and 08b (config / `.env.local` rewrite).**
**Status:** Pure analysis. No code is touched in this plan.

This audit categorizes every API route, page, top-level component, and top-level config file in the existing `arlowe-dashboard` Next.js app as **KEEP**, **REWRITE**, or **DELETE**, with rationale grounded in the live source.

## Source enumeration (verified 2026-05-02)

- **27** API routes under `app/api/**/route.ts`
- **13** pages under `app/**/page.tsx`
- **1** layout (`app/layout.tsx`) + **12** top-level components in `app/components/`
- **3** route-scoped component groups: `app/connectivity/components/` (8 files), `app/sub-agents/components/` (2), `app/testing/components/` (1)
- **1** middleware module (`app/api/middleware/auth.ts`)
- Top-level: `package.json`, `next.config.ts`, `tsconfig.json`, `eslint.config.mjs`, `playwright.config.ts`, `pnpm-lock.yaml`, `pnpm-workspace.yaml`, `postcss.config.mjs`, `.env.example`, `.gitignore`, `README.md`, `app/globals.css`, `app/favicon.ico`, `public/*.svg`, `tests/*.spec.ts` (5)

Total `app/` LOC: ~9,621. Total package LOC (incl. tests): ~10,391.

## Summary

| Category | API routes | Pages | Components | Top-level | Notes |
|---|---:|---:|---:|---:|---|
| **KEEP** (sanitize-only)        |  9 |  3 | 9 |  9 | Generic system / product surfaces |
| **REWRITE** (backend or content swap) |  3 |  4 | 3 |  4 | Surface stays; founder-paths or env coupling die |
| **DELETE**                       | 15 |  6 | 5 |  0 | Workforce / OpenClaw / IOL / founder-only / dev-only |
| **Total**                        | 27 | 13 | 17 | 13 | |

**Estimated LOC removed by plan 07 (delete pass):** ~4,200 LOC (~43% of `app/`) — see "Delete pass LOC budget" below.
**Estimated LOC rewritten by plan 08 (API rewrite):** ~470 LOC (config + logs + voice routes).
**Estimated LOC rewritten by plan 08b (env / config coupling):** ~30 LOC plus `.env.example` regeneration.

## Decision criteria

A file is **DELETE** if any of:
1. It reads from `~/.openclaw/...` (workforce data store).
2. It calls the OpenClaw control plane (`localhost:18789`, `openclaw-gateway`, `openclaw cron`, `openclaw` CLI).
3. It hardcodes a founder GitHub URL (`github.com/focal55/...`).
4. Its purpose is sub-agent / cron / cost / IOL / playwright introspection — none of which exist on a customer firmware.
5. It is dev/test infrastructure (`playwright-reports`, `testing` page).

A file is **REWRITE** if it is product-relevant but currently:
1. Reads `/home/focal55/...` paths that won't exist on a customer device, OR
2. Reads founder-private OpenClaw paths but the surface (config UI, log viewer) is genuinely useful, OR
3. Hardcodes `--user` systemd flags that need to become system-level on a customer image, OR
4. Pulls secrets from the dashboard's `.env.local` instead of `/etc/arlowe/config.yml` (Plan 08b territory).

A file is **KEEP** if it is generic Next.js / generic system code with at most cosmetic sanitization (banner strings, `Arlowe-1` literals).

## API routes (`app/api/**/route.ts`)

| Path | Decision | Reads / does | Rationale |
|---|---|---|---|
| `/api/health` (`app/api/health/route.ts`) | **KEEP** | `top`, `free`, `/sys/class/thermal/*/temp`, `df`, `uptime -p`, `axcl-smi` | Pure Linux + NPU stats. No founder paths. Plan 08 baseline. |
| `/api/voice` (`app/api/voice/route.ts`) | **REWRITE** (plan 08) | `systemctl --user is-active arlowe-voice`, posts to `localhost:8080/state` | Surface (start/stop/toggle) is the most product-relevant route in the app. Convert `--user` → system unit when image build lands; for Phase 1 keep `--user` and document. |
| `/api/connectivity/networks` | **KEEP** | `nmcli device wifi rescan`, `nmcli ... wifi list` | Generic Wi-Fi scan. Note: log line says `Model: google-gemini/gemini-2.5-flash` — strip that comment string in plan 08 sanitization (cosmetic, not gating). |
| `/api/connectivity/status` | **KEEP** | `nmcli connection show --active`, `nmcli -g IP4.ADDRESS device show` | Generic connection status. No founder data. |
| `/api/connectivity/saved` | **KEEP** | `nmcli connection show` (filtered to 802-11-wireless) | Generic. Already imports `verifyAuth` middleware. |
| `/api/connectivity/connect` | **KEEP** | `nmcli ... wifi connect ...` (with password) | Generic. Auth is currently TODO-disabled — flag as a security follow-up in plan 08, not a delete reason. |
| `/api/npu/status` | **KEEP** | `ss -tlnp`, `ps aux | grep main_api_axcl` | Generic NPU process check. |
| `/api/npu/benchmark` | **KEEP** | HTTP to `localhost:8000/api/{reset,generate,stream}` | Native ax-llm endpoint (port 8000). No founder coupling. |
| `/api/npu/chat` | **KEEP** | HTTP to `localhost:8000/api/{reset,generate,stream}` | Same as above. |
| `/api/config` (`app/api/config/route.ts`) | **REWRITE** (plan 08) | Reads/writes `/home/focal55/.openclaw/workspace/{SOUL,AGENTS,USER,TOOLS,MEMORY,HEARTBEAT,IDENTITY}.md` | Surface (file-list config editor) is plausible for product, but the **content** is workforce-specific. Plan 08 must (a) repoint to `/etc/arlowe/config.yml` (or a directory under `/var/lib/arlowe/`), and (b) re-decide what files the config UI actually edits. The current allow-list (SOUL/AGENTS/USER/...) is OpenClaw-shaped and does not survive translation. Plan 08 should treat this as essentially a fresh implementation that reuses the markdown-preview UI shell. |
| `/api/logs` (`app/api/logs/route.ts`) | **REWRITE** (plan 08) | `/home/focal55/whisplay/logs`, `/home/focal55/.openclaw/logs`, `/home/focal55/.openclaw/agents/main/sessions`, `/home/focal55/.openclaw/cron/runs`, `journalctl ... openclaw-gateway` | Voice-log parsing is real product value (lines 28-90: parses `🔔 Wake word`, `🎤 Heard:`, `🔊 Response`). Drop sessions / cron / openclaw-gateway log paths. Repoint voice logs to `/var/lib/arlowe/logs/`. Net: ~120 of 324 lines survive. |
| `/api/middleware/auth.ts` | **KEEP** | `process.env.DASHBOARD_API_SECRET`, `Authorization: Bearer ...` | Generic Bearer-token check. Self-contained. Used by `gateway/restart`, `cron`, `connectivity/saved`, `sub-agents/[sessionId]/kill`. After the delete pass, only `connectivity/saved` keeps a real consumer (rest are deleted). KEEP — and reactivate the disabled `verifyAuth` calls under `connectivity/connect` in plan 08 once a UI auth flow exists (research §EXTRACT-06 noted this as a follow-up). |
| `/api/costs` | **DELETE** (plan 07) | `/home/focal55/.openclaw/agents/main/sessions`, `/home/focal55/.openclaw/workspace/budget-config.json` | Workforce cost tracking. No customer analog. ~165 LOC. |
| `/api/cron` | **DELETE** | `/home/focal55/.openclaw/cron/jobs.json` | OpenClaw cron config. ~75 LOC. |
| `/api/cron/run` | **DELETE** | Shells out `/home/focal55/.npm-global/bin/openclaw cron run <id>` | OpenClaw CLI invocation. ~25 LOC. |
| `/api/gateway/restart` | **DELETE** | HTTP to `http://localhost:18789/api/gateway` with hardcoded bearer token | Restarts `openclaw-gateway`. **Also leaks a hardcoded auth token** (`3693d83e56...`). Token must die regardless. ~30 LOC. |
| `/api/sub-agents` | **DELETE** | Walks `~/.openclaw/agents/main/sessions/` JSONL files | Workforce sub-agent introspection. ~285 LOC. |
| `/api/sub-agents/[sessionId]` | **DELETE** | Reads sub-agent session history from `~/.openclaw/...` | Workforce. ~115 LOC. |
| `/api/sub-agents/[sessionId]/kill` | **DELETE** | Edits `~/.openclaw/agents/main/sessions/sessions.json` | Workforce. ~70 LOC. |
| `/api/subagent-types` | **DELETE** | Static array of "sub-agent type" archetypes (DnD-themed) | Founder workforce UI taxonomy. ~360 LOC. |
| `/api/tasks/active` | **DELETE** | Reads `~/.openclaw/agents/main/sessions/sessions.json` | Workforce active-task list. ~145 LOC. |
| `/api/usage` | **DELETE** | Walks `~/.openclaw/agents/main/sessions/` for token/cost aggregation | Workforce usage. ~185 LOC. |
| `/api/stats` | **DELETE** | `/home/focal55/.openclaw/workspace/usage-stats.json` | Workforce stats rollup. ~205 LOC. |
| `/api/iol/stats` | **DELETE** | HTTP to `http://localhost:3100/stats` (IOL Control Plane) | IOL infra. ~12 LOC. |
| `/api/playwright-reports` | **DELETE** | Reads `playwright-report/`, `test-results/` | Dev-only test infra; do not ship to product. ~340 LOC. |
| `/api/playwright-reports/files/[...path]` | **DELETE** | Streams files out of `playwright-report/`, `test-results/` | Dev-only. ~125 LOC. |
| `/api/playwright-reports/flush` | **DELETE** | Deletes Playwright output directories | Dev-only. ~30 LOC. |
| `/api/playwright-reports/run` | **DELETE** | `spawn('npx', ['playwright', 'test', ...])` | Dev-only test runner. ~80 LOC. |

### Routes total

- KEEP: 9 routes (~570 LOC)
- REWRITE: 3 routes (config + logs + voice; ~470 LOC pre-rewrite, expect ~250 LOC post-rewrite)
- DELETE: 15 routes (~2,250 LOC)

## Pages (`app/**/page.tsx`)

| Path | Decision | Rationale |
|---|---|---|
| `app/page.tsx` (homepage / Overview) | **REWRITE** (plan 07/08) | Imports `ActiveTasksPanel` (workforce — DELETE component) and renders three hardcoded `ProviderBadge` tiles for `local` / `gemini` / `anthropic` (workforce metering UI). Surface (system health card + voice toggle) is the v1 dashboard's reason to exist. Plan 07 strips the `ActiveTasksPanel` import and provider tiles; plan 08 swaps any usage-data calls (today they hit `/api/usage`) for a future health/voice-only payload. ~274 LOC, expect ~160 LOC after. |
| `app/connectivity/page.tsx` | **KEEP** | Wi-Fi management UI. Plain CRUD against the connectivity routes (which we keep). |
| `app/npu/page.tsx` | **KEEP** | NPU diagnostics + chat playground. Generic. |
| `app/config/page.tsx` | **REWRITE** (plan 08) | Listed file set is OpenClaw-shaped (`SOUL.md`, `AGENTS.md`, `USER.md`, `TOOLS.md`, `MEMORY.md`, `HEARTBEAT.md`, `IDENTITY.md`). UI shell (markdown editor + preview tabs) is reusable; the `configFiles[]` array gets rewritten to whatever Phase 4's `/etc/arlowe/config.yml` schema looks like. For Phase 1, plan 08 either (a) reduces this to "view-only" against a placeholder config file, or (b) flags the page as deferred to Phase 11 (dashboard surfaces). See open question Q1. |
| `app/logs/page.tsx` | **REWRITE** (plan 08) | UI shell (filter chips, time-grouped list) is product-relevant for voice-interaction history. Filter chips include `subagent`, `cron`, `session` types — strip those. After plan 08's `/api/logs` rewrite, the page wires through unchanged. |
| `app/stats/page.tsx` | **REWRITE** (plan 07/08) | Charts daily local/gemini/claude call counts and Claude $ — workforce-shaped data. Needs to either be stripped to "voice-interaction count over time" or deleted entirely. **Recommend DELETE for Phase 1**, defer any product-relevant stats page to Phase 11. Marked REWRITE here because the markdown audit framework forces a category and this is the most ambiguous; see open question Q2. |
| `app/iol/page.tsx` | **DELETE** | IOL control plane UI. Hardcodes `https://github.com/focal55/iol-monorepo/issues/<id>` at L412. ~430 LOC. |
| `app/sub-agents/page.tsx` | **DELETE** | Sub-agent monitoring UI. Hardcodes `https://github.com/focal55/iol-monorepo/issues/<id>` at L155. Imports the two sub-agent components (KillConfirmModal, SessionHistoryModal). ~340 LOC. |
| `app/subagent-types/page.tsx` | **DELETE** | Workforce taxonomy UI (DnD-themed sub-agent archetypes). ~280 LOC. |
| `app/cron/page.tsx` | **DELETE** | OpenClaw cron management UI. ~290 LOC. |
| `app/costs/page.tsx` | **DELETE** | Cost-budget UI. ~280 LOC. |
| `app/pathway/[id]/page.tsx` | **DELETE** | Pathway visualization for a request log — IOL-specific routing diagram. ~210 LOC. |
| `app/testing/page.tsx` | **DELETE** | Playwright report viewer (dev tool). ~30 LOC. |

### Pages total

- KEEP: 3 pages (connectivity, npu, plus implicitly the logs/stats/config UI shells that get rewrites)
- REWRITE: 4 pages (homepage, config, logs, stats — but stats is borderline DELETE; see Q2)
- DELETE: 6 pages (~1,860 LOC)

## Components

### Top-level (`app/components/`)

| File | Decision | Rationale |
|---|---|---|
| `StatusCard.tsx` | **KEEP** | Generic stat tile primitive. |
| `RetroActivityMonitor.tsx` | **KEEP** | Generic decorative widget on the homepage. |
| `Header.tsx` | **KEEP** (sanitize) | Top bar. Audit for `Arlowe-1` literals during plan 08 cosmetic pass. |
| `Navigation.tsx` | **REWRITE** (plan 07) | Nav rail hardcodes 12 routes including `/iol`, `/sub-agents`, `/subagent-types`, `/cron`, `/costs`, `/testing` — all DELETE. Plan 07 trims `navItems[]` to the surviving routes (`/`, `/npu`, `/config`, `/logs`, `/connectivity`, plus whatever stats/voice pages survive). ~47 LOC. |
| `MarkdownPreview.tsx` | **KEEP** | Generic markdown renderer (consumed by config page). |
| `ProfileSwitcher.tsx` | **KEEP** (audit usage) | Not currently imported by any surviving page after the delete pass — verify in plan 07 whether it's referenced from a deleted page only. If orphaned, downgrade to DELETE. |
| `ProviderBadge.tsx` | **REWRITE** (plan 07/08) | At line 17 the `providerInfo` map contains `openclaw: { label: 'System', icon: '⚙️', className: 'badge-local' }`. The `OpenClaw` literal must die per Phase 2 sanitization gate. Used by `app/page.tsx` (3 hardcoded tiles), `app/logs/page.tsx`, `app/stats/page.tsx`. After homepage rewrite drops the provider tiles, the badge is still consumed by logs/stats. Plan 08 either strips the openclaw map entry (5-line delete) or removes the component if logs/stats stop using provider attribution. |
| `ActiveTasksPanel.tsx` | **DELETE** | Workforce panel; consumed only by the homepage (which gets rewritten to drop it) and `/api/tasks/active` (DELETE). |
| `GlobalMetrics.tsx` | **DELETE** | Workforce metrics widget. Audit usage in plan 07 — if only consumed by deleted pages, delete; otherwise reclassify. |
| `ModelUsageChart.tsx` | **DELETE** | Workforce model-usage chart; consumed by `app/stats/page.tsx` and `app/costs/page.tsx`, both DELETE/borderline-DELETE. |
| `PathwayVisualization.tsx` | **DELETE** | Consumed only by `app/pathway/[id]/page.tsx` (DELETE). |
| `RequestLog.tsx` | **DELETE** | Workforce request log; not consumed by surviving pages after the delete pass. |

### Route-scoped

| Path | Decision | Rationale |
|---|---|---|
| `app/connectivity/components/*` (8 files: `AvailableNetworks`, `ConnectionStatus`, `ConnectToNetworkModal`, `CurrentStatus`, `NetworkList`, `PasswordModal`, `SavedNetworks`, `SavedNetworksList`) | **KEEP** | Wi-Fi UI primitives. Generic. |
| `app/sub-agents/components/{KillConfirmModal,SessionHistoryModal}.tsx` | **DELETE** | Consumed only by `app/sub-agents/page.tsx` (DELETE). |
| `app/testing/components/PlaywrightReportsViewer.tsx` | **DELETE** | Dev-only. Consumed only by `app/testing/page.tsx` (DELETE). |

### Components total

- KEEP: 6 top-level + 8 connectivity-scoped = 14
- REWRITE: 3 top-level (Navigation, ProviderBadge, Header-cosmetic)
- DELETE: 5 top-level + 2 sub-agents + 1 testing = 8

## Top-level files

| File | Decision | Rationale |
|---|---|---|
| `package.json` | **KEEP** | Standard Next.js 16 + React 19 + tailwind 4 deps. No founder-private packages. Plan 08 may rename `"name": "arlowe-dashboard"` → keep as-is (the name is product-aligned). |
| `next.config.ts` | **KEEP** | Stock. |
| `tsconfig.json` | **KEEP** | Stock. |
| `eslint.config.mjs` | **KEEP** | Stock. |
| `postcss.config.mjs` | **KEEP** | Stock. |
| `playwright.config.ts` | **REWRITE** (plan 07) | Keep e2e infra for the surviving routes (homepage, connectivity); strip configs that only matter for deleted pages. Test files (see below) drive what's needed. |
| `pnpm-workspace.yaml` | **REWRITE** (plan 07/08b) | The dashboard is currently inside iol-monorepo's pnpm workspace; once extracted to `runtime/dashboard/` it stands alone or joins the firmware repo's workspace. Mechanical change. |
| `pnpm-lock.yaml` | **KEEP** (regenerate) | Lockfile regenerates on first install in the new tree. |
| `.env.example` | **REWRITE** (plan 08b) | Currently only documents `DASHBOARD_API_SECRET`. Plan 08b expands this to whatever `/etc/arlowe/config.yml` overlay envs the rewritten routes need (e.g. `ARLOWE_CONFIG_PATH`, `ARLOWE_LOG_DIR`). Per research §R4, `tts_sync.py` reaches into the dashboard's `.env.local` for `ELEVENLABS_API_KEY`; plan 08b moves that read into the firmware config so the dashboard's `.env.local` stops being a cross-package secret store. |
| `.gitignore` | **KEEP** | Standard ignore set. |
| `README.md` | **REWRITE** (plan 08) | Currently 1450 bytes — generic Next.js README. Replace with firmware-tree-aware doc pointing at the `runtime/dashboard/` path and the config file the routes read. |
| `app/globals.css` | **KEEP** | Tailwind + retro theme styles. Audit for any literal "Arlowe-1" / "OpenClaw" strings in custom CSS classes (e.g., `badge-local` is the `openclaw` class, harmless). |
| `app/layout.tsx` | **KEEP** | Already says `title: "Arlowe Dashboard"` and `description: "Control panel for Arlowe-1"` — the `Arlowe-1` literal is the cosmetic kind research §Founder-Literal-Inventory marked as "soft" — sanitize to `"Arlowe device"` in plan 08 (one line). |
| `public/*.svg` | **KEEP** (audit) | Default Next.js scaffold SVGs (`next.svg`, `vercel.svg`, etc.). Probably unused; plan 07 can prune any orphans. |
| `app/favicon.ico` | **KEEP** (audit) | Default Next.js favicon. Replace with an Arlowe favicon in a future cosmetic-pass phase, not Phase 1. |

## Tests (`tests/*.spec.ts`)

| File | Decision | Rationale |
|---|---|---|
| `tests/example.spec.ts` | **KEEP** | Stock Playwright sanity test. |
| `tests/navigation.spec.ts` | **REWRITE** (plan 07) | Asserts navigation across the 12-item nav rail. Update to the trimmed nav set. |
| `tests/connectivity.spec.ts` | **KEEP** | Tests the connectivity page (which we keep). |
| `tests/active-tasks.spec.ts` | **DELETE** | Tests the `ActiveTasksPanel` (DELETE component). |
| `tests/costs.spec.ts` | **DELETE** | Tests `app/costs/page.tsx` (DELETE). |

## Founder GitHub URL audit

Two confirmed leaks (verified via `grep -n 'github.com/focal55'`):

- `app/sub-agents/page.tsx:155` — `https://github.com/focal55/iol-monorepo/issues/${agent.parsed.taskId}` (page DELETE)
- `app/iol/page.tsx:412` — `https://github.com/focal55/iol-monorepo/issues/${agent.issue}` (page DELETE)

Both URLs are inside DELETE pages and disappear with plan 07.

After plan 07's deletes, `grep -rn 'focal55\|github.com/focal55' .` against the dashboard tree must return zero. Plan 07's verify step enforces this.

## Hardcoded auth-token leak (plan 07 must remove regardless)

`app/api/gateway/restart/route.ts` line 5 hardcodes a bearer token:

```ts
const GATEWAY_TOKEN = '3693d83e56ea9af7b9cf7e7a4c410654dfd78a99d975a338';
```

Even though the route is DELETE, the token sat in plain source — note for the team's secrets-rotation hygiene that this token is now considered exposed and should be retired in the OpenClaw gateway's config. Out of scope for plan 07 (just delete the file), in scope for whoever owns the live gateway.

## OpenClaw / IOL literal sweep (plan 07 verify target)

Files that match `grep -l 'openclaw\|focal55\|iol-monorepo'`:

- 11 routes (`config`, `costs`, `cron`, `cron/run`, `gateway/restart`, `logs`, `stats`, `sub-agents/*` x3, `tasks/active`, `usage`) — all either DELETE or REWRITE. Post-plan-08, only `/api/logs` and `/api/config` should survive, and both will be rewritten to drop the literals.
- `app/components/ProviderBadge.tsx` — REWRITE (drop the `openclaw:` map entry).
- `app/iol/page.tsx`, `app/sub-agents/page.tsx` — DELETE.

Phase 2 sanitization gate banlist (per research): after plans 07 + 08 complete, `grep -rni 'openclaw\|focal55\|\.openclaw\|iol-monorepo\|github\.com/focal55' .` against `runtime/dashboard/` must return zero hits.

## Plan 07 / 08 / 08b division of labor

This audit feeds three downstream plans:

- **Plan 07 — Delete pass.** Mechanically remove every DELETE row from this audit. Trim `Navigation.tsx`'s `navItems[]` to surviving routes. Trim `tests/` to surviving specs. Run the founder-literal grep verify. PR-size budget: -4,200 LOC.
- **Plan 08 — Backend rewrite pass.** Rewrite `/api/config`, `/api/logs`, `/api/voice` to read from `/etc/arlowe/config.yml` (or the Phase-4 config layer's path) instead of `~/.openclaw/...`. Strip the `openclaw:` entry from `ProviderBadge.tsx`. Update homepage to drop the workforce provider tiles and `ActiveTasksPanel`. Update `app/layout.tsx`'s "Arlowe-1" literal. PR-size budget: ~+250/-470 net.
- **Plan 08b — `.env.local` decoupling.** Replace the `tts_sync.py` cross-package read of the dashboard's `.env.local` with a config read. Regenerate `.env.example`. Confirm the dashboard's local `.env.local` is gitignored (it is — `.gitignore` line 35 covers it).

## Delete pass LOC budget

Routes (~2,250):
- costs 165, cron 75, cron/run 25, gateway/restart 30, sub-agents 285+115+70=470, subagent-types 360, tasks/active 145, usage 185, stats 205, iol/stats 12, playwright-reports 340+125+30+80=575

Pages (~1,860):
- iol 430, sub-agents 340, subagent-types 280, cron 290, costs 280, pathway 210, testing 30

Components (~600):
- ActiveTasksPanel ~130, GlobalMetrics ~80, ModelUsageChart ~110, PathwayVisualization ~180, RequestLog ~50, KillConfirmModal ~25, SessionHistoryModal ~30, PlaywrightReportsViewer ~?

Tests (~50):
- active-tasks ~25, costs ~25

**Approximate plan-07 delta:** −4,200 LOC removed, +20 LOC of `Navigation.tsx` edits and trimmed `playwright.config.ts`. Comfortably within the 400-line PR cap **only if plan 07 is split** into 2–3 sub-PRs (e.g. `delete-workforce-routes`, `delete-workforce-pages`, `delete-orphan-components`). The 06 plan does not pre-decide the PR split — that is a plan-07 task. Flagging here.

## Open audit questions

### Q1 — Config page reuse vs. defer

The `app/config/page.tsx` UI is a markdown-file editor (SOUL/AGENTS/USER/...). Two paths for plan 08:

- **(a) Repurpose:** keep the markdown editor shell; rewrite `configFiles[]` to whatever Phase-4 `/etc/arlowe/config.yml` schema looks like. Risk: Phase 4 hasn't decided the schema yet, so plan 08 either has to make the call or stub.
- **(b) Defer to Phase 11:** plan 07 deletes the page, plan 08 leaves the API surface (`/api/config`) as a thin "read /etc/arlowe/config.yml" endpoint with no UI. Phase 11 reintroduces a config UI.

**Recommendation: (b).** The markdown editor model assumes free-form file text; a YAML config file wants a structured form. Reusing the wrong UI shell is technical debt. Plan 07 deletes `app/config/page.tsx`; plan 08 keeps `/api/config` as a stripped-down read-only route. Plan 11 designs the real config UI.

If the user disagrees, plan 08 implementer should re-classify `app/config/page.tsx` from REWRITE to KEEP-after-rewrite.

### Q2 — Stats page: REWRITE or DELETE?

`app/stats/page.tsx` charts daily local/gemini/claude call counts and Claude cost. The shape is workforce-specific (multi-provider routing analytics). A v1 product device has no comparable signal — there's just a voice-interaction stream.

**Recommendation: DELETE.** Phase 11 can introduce a "voice activity over time" page if there's product demand. For Phase 1, the dashboard does not ship `/stats`. This downgrades the audit's REWRITE count for pages from 4 to 3 and bumps DELETE pages from 6 to 7.

If the user disagrees, plan 08 keeps a stripped-down version that reads from rewritten `/api/logs` aggregation.

### Q3 — `/api/voice` `--user` flag

Plan 08 has to decide whether to keep `systemctl --user is-active arlowe-voice` or migrate to system-level. Per research §R7, the recommendation is keep `--user` for Phase 1 (smoke test on Joe's unit), convert to system in Phase 11 (image build).

**Recommendation: keep `--user` in plan 08.** Document the tech debt in a follow-up ticket. No re-audit needed.

### Q4 — `/api/connectivity/connect` auth re-enable

Auth is currently TODO-disabled because there's no UI flow for entering the bearer token. Plan 08 either (a) leaves the TODO and ships, or (b) implements a first-boot bearer-token UX that wires through.

**Recommendation: (a) leaves the TODO.** Customer first-boot pairing is Phase 7 (per roadmap). Phase 1 is not the moment to design the auth UX. Document in plan 08's notes that connectivity-mutation routes ship with auth disabled until Phase 7.

### Q5 — `/api/middleware/auth.ts` after the delete pass

Once plans 07/08 land, the only remaining destructive route guarded by `verifyAuth` is `/api/connectivity/saved` (and `/api/connectivity/connect` once Q4 is resolved). Two paths:

- Keep the middleware as-is (small file, no harm).
- Inline the bearer check into the two connectivity routes and delete the middleware file.

**Recommendation: keep.** It's 70 LOC, the pattern is sane, and Phase 7 will likely reuse it. No action needed in plan 07/08.

## References

- Issue: focal55/arlowe-firmware#6
- Plan: `.planning/phases/01-runtime-extraction/06-PLAN.md`
- Research: `.planning/phases/01-runtime-extraction/01-RESEARCH.md` §EXTRACT-06, §R2, §Founder-Literal-Inventory, §R4 (`.env.local` cross-package coupling)
- Roadmap requirement: EXTRACT-06
- Dashboard source: `/Users/joeybarrajr/projects/iol-monorepo/packages/arlowe-dashboard/` (verified 2026-05-02)
