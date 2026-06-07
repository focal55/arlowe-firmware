---
phase: 04-config-overlay
plan: 03
type: summary
completed: 2026-06-07
pr: pending
requirements_covered: [CONFIG-04, CONFIG-05]
---

## What was done

- Installed `ajv@^8.20.0` (dependencies) and `tsx@^4.22.4` (devDependencies) via pnpm; both land in `pnpm-lock.yaml` and `node_modules`.
- Created `runtime/dashboard/app/api/config/restart-map.ts`: knob→unit map with `unitsForChange()` helper; only polkit-authorized unit prefixes (`arlowe-*`, `qwen-*`); `ports` carries the no-live-consumer comment per plan.
- Rewrote `runtime/dashboard/app/api/config/route.ts` POST handler:
  - Reads schema from `ARLOWE_SCHEMA_PATH` (default `/opt/arlowe/config/schema.yml`), validates with `Ajv2020` (draft 2020-12 dialect). Invalid body → 422, no write.
  - Preserved the existing `writeFile(CONFIG_TMP_PATH)` + `rename(CONFIG_PATH)` atomic write.
  - Removed the `TODO(phase-4): validate against config/schema.yml` marker.
  - Diffs changed top-level keys against prior on-disk overlay; calls `unitsForChange()` and restarts via the `ARLOWE_SYSTEMCTL_MODE` seam (mirrors `api/voice/route.ts`). Restart failure is non-fatal; response includes `restarted` and `restartErrors` arrays.
- Added `testIgnore: ['**/unit/**']` to `runtime/dashboard/playwright.config.ts` so `pnpm test:e2e` ignores `tests/unit/`.
- Added `test:unit` script (`node --import tsx --test tests/unit/*.test.ts`) to `package.json`.
- Created `runtime/dashboard/tests/unit/config-validate.test.ts` (`node:test` + `node:assert`): covers `unitsForChange` exact matches, deduplication, polkit regex guard, schema accepts valid config, schema rejects invalid `ota.channel` enum, schema rejects missing required keys.

## Verification

- `pnpm test:unit`: 9/9 pass, no Next build or server boot.
- `pnpm exec tsc --noEmit`: clean.
- `pnpm exec playwright test --list`: unit test NOT listed (44 tests from 4 `.spec.ts` files only).
- `scripts/sanitize/check.sh`: clean (152 files, 9 units).
- Lint: same 8 pre-existing warnings/errors as baseline; no new issues introduced.
