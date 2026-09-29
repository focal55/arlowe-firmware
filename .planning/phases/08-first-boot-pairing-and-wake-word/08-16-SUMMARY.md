---
phase: 08-first-boot-pairing-and-wake-word
plan: 16
subsystem: dashboard-auth
tags: [nextjs, argon2id, session-cookie, login, throttle]
requires: [08-09]
provides: [POST /api/auth/login, POST /api/auth/logout, /login page, loadOwnerCredential, originMatchesHost, loginThrottle]
affects: [08-20, 08-21]
tech-stack:
  added: []
  patterns: [route handlers read dashboard state dir per request, module-level login throttle]
key-files:
  created:
    - runtime/dashboard/app/api/auth/login/route.ts
    - runtime/dashboard/app/api/auth/logout/route.ts
    - runtime/dashboard/app/login/page.tsx
    - runtime/dashboard/lib/auth/credential.ts
    - runtime/dashboard/tests/unit/auth-login.test.ts
  modified:
    - runtime/dashboard/lib/auth/throttle.ts
decisions:
  - "loginThrottle lives in lib/auth/throttle.ts: Next route files may only export route handlers, so the instance and its test reset cannot sit in route.ts"
  - "An absent Origin header is allowed; a present one must parse and its host must equal Host (an opaque 'null' origin is 403)"
  - "A missing session key is treated like a missing credential: 401, counted by the throttle"
metrics:
  completed: 2026-09-28
---

# Phase 8 Plan 16: Dashboard login and logout Summary

Owner login at `/login` verifies the pairing password against `owner-credential.json` with 08-09's Argon2id verifier and sets the `arlowe_session` cookie. It is throttled at 5 failures, then 30 s. Logout expires the cookie.

## Tasks

| Task | Commit | Result |
|------|--------|--------|
| 1 RED: cases | 025b009 | 7 cases; the file failed on the missing route module |
| 2 GREEN: routes, reader, page | ad298a7 | 7/7 pass; full unit suite 45/45 |

## Behaviour delivered

- Right password: 200 and `Set-Cookie: arlowe_session=<v>; HttpOnly; SameSite=Strict; Path=/; Max-Age=2592000`, no `Secure`.
- Wrong password: 401 `{"error":"invalid_credentials"}`, no cookie, counted.
- Five failures make the sixth attempt 429 `{"error":"too_many_attempts"}`, even with the right password, until 30 s pass. The test runs the clock with `mock.timers` (Date only).
- No credential file (or no session key): 401 for any password.
- `Origin` present and not matching `Host`: 403 (login and logout).
- Malformed JSON or a non-string `password`: 400, not counted.
- `/login` redirects to `?next=` only when it starts with `/` and not `//` or `/\`; otherwise to `/`. It reads `window.location.search` at submit time rather than `useSearchParams`, so the page prerenders statically without a Suspense boundary.

## Verification

- `pnpm test:unit`: 45 tests, 45 pass (7 new).
- `pnpm typecheck`: clean.
- `pnpm lint`: 0 errors. The 8 warnings are all in files that were already there (#123 and `app/api/middleware/auth.ts`), none in new files.
- `pnpm build`: succeeds; `/login` static, `/api/auth/login` and `/api/auth/logout` dynamic.
- `scripts/sanitize/check.sh`: clean.
- Not verified here: a browser login on the device. That needs a paired unit with 08-20's credential writer.

## Deviations from Plan

1. **[Rule 3 - Blocking] `loginThrottle` exported from `lib/auth/throttle.ts`, not from the route.** Next's build rejects extra exports from `route.ts`. The test hook is `loginThrottle.succeed()`, which already clears both the counter and the lock, so no new method was added.
2. **[Rule 2 - Missing Critical] `originMatchesHost` placed in `lib/auth/credential.ts` and also applied to logout.** ADR-0012 says every mutating route checks Origin against Host. 08-21's `require-session.ts` can import this helper instead of writing its own.

## Notes for 08-21

- `/api/auth/logout` is not in 08-21's matcher exclusions. Behind the proxy, a logout without a valid session gets the proxy's 401 rather than the handler's 200. That is harmless, but the page should not rely on logout succeeding while signed out.
- The login page renders inside the root layout, so the navigation shows on `/login`. Hide it there if 08-21 wants a bare login screen.
