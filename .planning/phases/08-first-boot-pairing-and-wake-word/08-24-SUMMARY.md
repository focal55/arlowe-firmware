---
phase: 08-first-boot-pairing-and-wake-word
plan: 24
subsystem: dashboard
tags: [nextjs, factory-reset, auth, argon2, systemd]
requires:
  - phase: 08-first-boot-pairing-and-wake-word
    provides: "08-09 session/argon2/throttle, 08-16 credential helpers, 08-18 arlowe-factory-reset@.service, 08-21 requireSession"
provides:
  - "POST /api/device/reset (202 {status: resetting})"
  - "/settings page with logout and factory reset"
affects: [08-25, 08-27b, 11]
tech-stack:
  added: []
  patterns: ["Test seams for route handlers live in lib/ modules (Next route files may export handlers only)"]
key-files:
  created:
    - runtime/dashboard/app/api/device/reset/route.ts
    - runtime/dashboard/lib/device/reset.ts
    - runtime/dashboard/app/settings/page.tsx
    - runtime/dashboard/tests/unit/device-reset.test.ts
  modified:
    - runtime/dashboard/app/components/Navigation.tsx
key-decisions:
  - "The server also requires confirm == \"RESET\" in the body, not just the UI"
  - "A correct re-entered password clears loginThrottle, as a successful login does"
  - "systemctl start failure answers 500 {error: reset_failed}"
duration: 15min
completed: 2026-09-29
---

# Phase 8 Plan 24: Dashboard factory reset Summary

**Authenticated dashboard reset: session + Origin check, Argon2id password re-entry throttled with login, typed RESET, then `systemctl start --no-block arlowe-factory-reset@dashboard.service` and 202.**

## Accomplishments
- `POST /api/device/reset`: `requireSession` first (401 unauthorized / 403 forbidden), `loginThrottle.blocked()` 429 too_many_attempts, body `{password: string, confirm: "RESET"}` else 400 bad_request, `verifyPassword` against `loadOwnerCredential()` else 401 invalid_credentials and `loginThrottle.fail()`, then the unit start and 202 `{"status":"resetting"}`; start failure 500 `{"error":"reset_failed"}`. Journal lines: "factory reset requested (dashboard)", "factory reset start failed: ...".
- `/settings`: logout button, the ADR-0013 erase list, password and typed-confirmation fields, and a "resetting, the unit will restart into setup mode" state.
- Navigation gains a Settings link.

## Task Commits
1. Task 1 (RED): `e2649c8` test(08-24): failing cases for the dashboard factory reset route
2. Task 2 (GREEN): `5379570` feat(08-24): dashboard factory reset with password re-entry

## Deviations from Plan
1. [Rule 3 - Blocking] The execFile seam is in a new `runtime/dashboard/lib/device/reset.ts` (`resetDeps.execFile`, `startReset()`, `RESET_UNIT`). The connectivity routes have no seam to copy, and Next rejects non-handler exports from route modules at build time.
2. [Rule 2 - Missing Critical] The server enforces `confirm: "RESET"`, so a scripted or accidental POST with only the password cannot wipe the unit. The plan put the typed confirmation in the UI only.
3. Seven test cases instead of six: an extra case covers systemctl failure (500).

## Verification
- `pnpm test:unit`: RED 58/59 (device-reset failed to load: route absent); GREEN 65/65.
- `pnpm typecheck`: clean. `pnpm lint`: 0 errors, 7 pre-existing warnings, none in the touched files. `pnpm build`: succeeds, lists `/api/device/reset` and `/settings`.
- `scripts/sanitize/check.sh`: clean.
- Not verified: a real reset on hardware (08-27b). The dashboard unit must be allowed to start `arlowe-factory-reset@dashboard.service` over D-Bus (polkit arlowe- prefix, sandbox address families); that is 08-25's to confirm.

## Next Phase Readiness
- 08-25: confirm the dashboard service's sandbox and polkit rule let it start `arlowe-factory-reset@dashboard.service`.
- Phase 11 owns the full settings view; `/settings` is minimal by scope.
