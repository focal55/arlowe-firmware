---
phase: 08-first-boot-pairing-and-wake-word
plan: 21
subsystem: auth
tags: [nextjs, proxy, session, csrf, dashboard]

requires:
  - phase: 08-first-boot-pairing-and-wake-word
    provides: "08-09 readSession/loadSessionKey; 08-16 originMatchesHost, /login page and login route"
provides:
  - "runtime/dashboard/proxy.ts: Next 16 session gate over every page and /api route"
  - "lib/auth/require-session.ts: requireSession(request) and hasSession(request)"
  - "Six mutating handlers guarded in-handler; verifyAuth/DASHBOARD_API_SECRET deleted"
affects: [08-20, 08-24, dashboard]

tech-stack:
  added: []
  patterns:
    - "Mutating route handlers start with `const denied = requireSession(request); if (denied) return denied;`"

key-files:
  created:
    - runtime/dashboard/proxy.ts
    - runtime/dashboard/lib/auth/require-session.ts
    - runtime/dashboard/tests/unit/auth-proxy.test.ts
  modified:
    - runtime/dashboard/app/api/config/route.ts
    - runtime/dashboard/app/api/voice/route.ts
    - runtime/dashboard/app/api/npu/chat/route.ts
    - runtime/dashboard/app/api/npu/benchmark/route.ts
    - runtime/dashboard/app/api/connectivity/connect/route.ts
    - runtime/dashboard/app/api/connectivity/saved/route.ts
    - runtime/dashboard/README.md
    - runtime/dashboard/.env.example
  deleted:
    - runtime/dashboard/app/api/middleware/auth.ts

key-decisions:
  - "Session is checked before Origin in requireSession: no session -> 401 {error:unauthorized}, cross-origin -> 403 {error:forbidden} (same error strings as 08-16)"
  - "proxy and requireSession share hasSession(); nothing re-implements 08-09/08-16 primitives"

duration: 25min
completed: 2026-09-29
---

# Phase 8 Plan 21: Dashboard Session Gate Summary

**Next 16 `proxy.ts` redirects every page to `/login?next=` and 401s every `/api` route without a valid HMAC session cookie, and the six mutating handlers re-check the session plus Origin/Host themselves.**

## Accomplishments
- `proxy.ts` matcher `/((?!_next/static|_next/image|favicon.ico|login|api/auth/login).*)`; `pnpm build` lists `ƒ Proxy (Middleware)`.
- `requireSession()` guards config POST, voice POST, npu chat POST, npu benchmark POST (gained a `request` parameter), Wi-Fi connect POST and saved-network DELETE. GETs are proxy-only, per plan.
- `app/api/middleware/auth.ts` deleted; the saved-network DELETE no longer always answers 403.

## Task Commits
1. **Task 1: Cases (RED)** - `5899143` (test) - failed on `Cannot find module '../../proxy.js'`
2. **Task 2: Proxy, guard, route edits, deletion (GREEN)** - `983e059` (feat)

## Verification
- `pnpm test:unit`: 58/58 pass (12 new).
- `pnpm typecheck`: clean. `pnpm lint`: 0 errors, 7 warnings, all pre-existing (none in touched lines).
- `pnpm build`: succeeds, lists the proxy.
- `grep -rn 'verifyAuth\|DASHBOARD_API_SECRET' app lib proxy.ts`: no hits.
- Manual smoke against `next start` with a temp state dir: `/` and `/logs` 307 to `/login?next=...`; `/login` and `/favicon.ico` 200; `/api/health` 401; with a minted cookie `/` 200; saved DELETE with `Origin: http://evil.example` 403, same-origin 400 (reached the handler's own validation).

## Deviations from Plan

**1. [Rule 3 - Adapted] "Proceeds" cases stop at the handler's own input check instead of mocking execFile.**
`mock.module` needs `--experimental-test-module-mocks`, which `test:unit` does not pass. Each handler's "proceeds" request is shaped to return before any side effect: malformed JSON (config, voice, chat -> 500), `{}` (connect, saved -> 400), and a mocked `fetch` that throws (benchmark -> 503). The status proves the guard let the request through; no nmcli, systemctl, curl or file write runs.

**2. [Rule 2 - Stale docs] README.md and .env.example documented `DASHBOARD_API_SECRET`.**
Replaced with `ARLOWE_DASHBOARD_STATE_DIR` and a short description of the session gate. The plan's grep covered only .ts/.tsx.

**3. Added `hasSession(request)`** export in require-session.ts so the proxy and the guard share one cookie/key check.

## Notes for later plans
- `/api/auth/logout` is behind the proxy (the matcher excludes only login), so logout without a valid session answers 401. Harmless: the cookie is already useless.
- The Playwright specs (`tests/connectivity.spec.ts`, `navigation.spec.ts`, `example.spec.ts`, `sanitize.spec.ts`) now need a login (session.key + cookie) to reach any page or API route. Not run in CI; not fixed here.
- `docs/architecture/dashboard-extraction-audit.md` still describes `verifyAuth` as KEEP; it is a historical audit and was left unchanged.
- 08-20 must write `session.key` (32 raw bytes) and `owner-credential.json` into `ARLOWE_DASHBOARD_STATE_DIR` or the dashboard stays locked.
