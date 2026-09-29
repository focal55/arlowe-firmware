---
phase: 08-first-boot-pairing-and-wake-word
plan: 09
subsystem: auth
tags: [dashboard, argon2id, hmac, session, node24, ci]
requires: []
provides:
  - "verifyPassword(phc, password) on node:crypto argon2"
  - "issueSession / readSession / loadSessionKey / sessionCookieAttributes, SESSION_COOKIE"
  - "Throttle (5 failures, 30 s lock)"
  - "Dashboard CI and sanitize on Node 24"
affects: [08-16, 08-20, 08-21]
tech-stack:
  added: []
  patterns: ["Stateless HMAC session cookie; key file cached on mtime+size"]
key-files:
  created:
    - runtime/dashboard/lib/auth/argon2.ts
    - runtime/dashboard/lib/auth/session.ts
    - runtime/dashboard/lib/auth/throttle.ts
    - runtime/dashboard/tests/unit/auth-argon2.test.ts
    - runtime/dashboard/tests/unit/auth-session.test.ts
    - runtime/dashboard/tests/unit/fixtures/argon2-vector.json
  modified:
    - runtime/dashboard/package.json
    - runtime/dashboard/pnpm-lock.yaml
    - .github/workflows/ci.yml
    - .github/workflows/sanitize.yml
key-decisions:
  - "readSession takes the key explicitly; callers load it with loadSessionKey()"
  - "All times are epoch milliseconds (Date.now()); payload is {iat, exp} in ms"
duration: 20min
completed: 2026-09-28
---

# Phase 8 Plan 09: Dashboard Auth Primitives Summary

**Argon2id PHC verify on Node 24's `crypto.argon2`, checked against a vector hashed by argon2-cffi 21.1.0, plus an HMAC-SHA256 session cookie, a login throttle, and CI moved to Node 24.**

## Task Commits

1. **Task 1: Vector and cases (RED)** - `fb7ea7e` (test)
2. **Task 2: Primitives and Node 24 (GREEN)** - `6e3e7f2` (feat)

## Verification

- `node --version`: v24.15.0
- RED: both new test files failed with `Cannot find module '../../lib/auth/{argon2,session}.js'`
- GREEN: `pnpm test:unit` 34/34 pass; `pnpm typecheck` rc=0; `pnpm lint` 0 errors (8 pre-existing warnings, none in new files); `pnpm build` rc=0
- `grep -c "node-version: '20'"` on ci.yml and sanitize.yml: 0 and 0
- Net size (`git diff --shortstat origin/main...HEAD`, before this file): 302

## Interfaces for later plans

- `verifyPassword(phc: string, password: string): Promise<boolean>`. Never throws.
- `issueSession(key: Buffer, now = Date.now()): string`
- `readSession(value: string | undefined, key: Buffer | null, now = Date.now()): {iat, exp} | null`
- `loadSessionKey(dir = dashboardStateDir()): Buffer | null`. `dashboardStateDir()` reads `ARLOWE_DASHBOARD_STATE_DIR`, default `/var/lib/arlowe/dashboard`.
- `sessionCookieAttributes()` returns `HttpOnly; SameSite=Strict; Path=/; Max-Age=2592000`. `SESSION_MAX_AGE_S` is exported.
- `new Throttle(maxFailures = 5, lockMs = 30_000)` with `blocked(now)`, `fail(now)`, `succeed()`. It is a single global counter, not per client.

## Deviations from Plan

1. **Precondition check.** `git show main:pi-gen/config | grep -c FIRST_USER_PASS` prints 1, not 0. The one hit is the comment PR #201 added, which says the variable is deliberately unset. Nothing assigns it, and #201 is merged, so I proceeded.
2. **`readSession` signature.** The research's `proxy.ts` sketch calls `readSession(cookie)` with one argument. This implementation takes the key explicitly, so 08-21's proxy should call `readSession(cookie, loadSessionKey())`.
3. **Malformed-parameter guard (Rule 2).** A well-formed PHC string can still carry values out of range for `crypto.argon2` (p=0, a short salt), and those make it throw. `verifyPassword` catches the throw and returns false, as the spec requires.
4. **Key cache stamp.** The key cache is keyed on `mtimeNs` plus size, not mtime alone, so a rewrite within one timestamp tick is still picked up.
5. **Throttle cases** are in `auth-session.test.ts`, following the plan's file list, rather than in a separate file.
6. The vector was generated with argon2-cffi pinned to 21.1.0, the version bookworm's `python3-argon2` ships.
