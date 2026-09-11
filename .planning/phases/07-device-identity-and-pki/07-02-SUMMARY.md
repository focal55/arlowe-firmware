---
phase: 07-device-identity-and-pki
plan: 02
subsystem: testing
tags: [github-actions, pytest, pnpm, eslint, debian-bookworm, cryptography, requests, pi-gen]

requires:
  - phase: 04-configuration
    provides: runtime/lib/arlowe_config.py and its pytest suite, the tests these jobs run
  - phase: 06-image-build
    provides: pi-gen/stage-arlowe/00-packages/00-packages-nr and build-image.sh's declared-package guard
provides:
  - "python-test CI job: pytest runtime/lib/tests/ on every PR, ungated"
  - "python-floor-bookworm CI job: same suite against apt cryptography 38.0.4 / requests 2.28.1"
  - "Node CI jobs repointed at runtime/dashboard; pnpm test:unit and tsc --noEmit now run on PRs"
  - "runtime/lib/requirements.txt owns cryptography + requests for all of Phase 7"
  - "python3-cryptography and python3-requests declared as image apt packages"
affects: [07-03, 07-06, 07-07, 07-08a, dashboard-lint-cleanup]

tech-stack:
  added: [pytest==8.3.4, cryptography==43.0.3, requests==2.32.5, python3-cryptography, python3-requests]
  patterns:
    - "Dual-surface Python deps: pip pins for CI, apt packages for the image, with the bookworm floor as the binding constraint"
    - "continue-on-error to keep a red job non-blocking without skipping it, preserving downstream needs"

key-files:
  created:
    - runtime/lib/requirements-dev.txt
  modified:
    - .github/workflows/ci.yml
    - runtime/lib/requirements.txt
    - runtime/dashboard/package.json
    - pi-gen/stage-arlowe/00-packages/00-packages-nr

key-decisions:
  - "python-floor-bookworm uses apt python3-cryptography in a debian:bookworm container, not a pip pin, because apt is what the image actually ships"
  - "pnpm pinned to 10 in CI, not 9: pnpm-workspace.yaml carries settings-only keys that pnpm 9 rejects"
  - "The 5 pre-existing eslint errors are waived via continue-on-error, not fixed, and stay on issue #120"

patterns-established:
  - "Any runtime/lib code Phase 7 adds must pass under cryptography 38.0.4 before it can ship"
  - "Later plans copy the python-test env block verbatim rather than inventing path overrides"

duration: 42min
completed: 2026-09-10
---

# Phase 07 Plan 02: CI Enforcement and Python Dependency Declaration Summary

**CI now actually runs tests: an ungated pytest job, a debian:bookworm container job that pins Phase 7 to cryptography 38.0.4's API surface, and dashboard jobs repointed from a nonexistent root `package.json` to `runtime/dashboard`.**

## Performance

- **Duration:** ~42 min
- **Tasks:** 3 (task 2 required no code change; see below)
- **Files modified:** 5 (1 created, 4 modified)

## Accomplishments

- Closed the hole where **no test job of any kind ran on a pull request**. `detect` gated on a root `package.json` that does not exist, so `lint`, `typecheck`, `test` and `build` were silently skipped on every PR, and there was no Python job at all.
- Added `python-floor-bookworm`, which turns the cryptography 38.0.4 API floor from a laptop-only assertion into a CI gate. Verified locally under OrbStack: the container reports `cryptography 38.0.4 requests 2.28.1` and the suite passes 85/85.
- Declared Phase 7's Python deps on both surfaces in one place, so 07-06 and 07-07 no longer contend over `runtime/lib/requirements.txt` and can run in the same wave.

## Task Commits

1. **Task 1: Make CI actually run tests** - `7750d32` (ci)
2. **Task 2: Make the existing suite green in a clean checkout** - no commit; verification-only, see below
3. **Task 3: Declare Phase 7's Python dependencies on both surfaces** - `7adab79` (feat)

## The pytest invocation later plans copy

```yaml
env:
  ARLOWE_SCHEMA_PATH: config/schema.yml
  ARLOWE_DEFAULTS_PATH: config/defaults.yml
  ARLOWE_CONFIG_PATH: /nonexistent
  PYTHONPATH: runtime/lib
run: python -m pytest runtime/lib/tests/ -q
```

`ARLOWE_CONFIG_PATH: /nonexistent` is deliberate: it forces the loader down the defaults-only path
so the suite never picks up a host config. Both Python jobs use this identical block.

## The bookworm API floor (07-06 depends on this)

Job name **`python-floor-bookworm`** — do not rename it; 07-06 cites it as the enforcement its floor
claim rests on. It runs in `container: debian:bookworm` and installs exactly:

```
python3 python3-cryptography python3-requests python3-yaml python3-jsonschema python3-pytest
```

Measured versions in that container: **cryptography 38.0.4, requests 2.28.1**. All `runtime/lib`
code must stay within those APIs — no `x509.verification`, no `not_valid_after_utc`, no other 42+-only
call. The image runs system python3 with these apt packages; `/opt/arlowe/venvs` is empty, so the
`cryptography==43.0.3` pin in `requirements.txt` governs CI and local dev only, never the device.

The apt list covers the `python3-*` entries `runtime/lib` imports. It deliberately omits
`python3-rpi.gpio` and `python3-spidev` from `00-packages-nr`, which are Pi-only and stubbed in tests.

## Dashboard CI: what enforces and what does not

| Job | Status | Reason |
|---|---|---|
| `typecheck` (`tsc --noEmit`) | **blocking** | green at HEAD; script did not exist, added to `package.json` |
| `test` (`pnpm test:unit`) | **blocking** | green, 20 tests. `pnpm test` does not exist; this is what makes 07-01's tripwire real |
| `build` (`next build`) | **blocking** | verified green locally, so no waiver needed |
| `lint` (`eslint`) | **non-blocking** (`continue-on-error: true`) | 5 pre-existing errors, issue #120 |
| `test:e2e` | **not wired** | needs browsers and a running Next server; its own change |

The 5 waived errors, all `react-hooks/set-state-in-effect`, so the follow-up plan does not rediscover them:

| file | line |
|---|---|
| `runtime/dashboard/app/page.tsx` | 44 |
| `runtime/dashboard/app/logs/page.tsx` | 53 |
| `runtime/dashboard/app/components/RetroActivityMonitor.tsx` | 56 |
| `runtime/dashboard/app/connectivity/components/NetworkList.tsx` | 58 |
| `runtime/dashboard/app/connectivity/components/SavedNetworksList.tsx` | 98 |

`continue-on-error` rather than an `if:` skip because `build` declares `needs: [detect, lint, typecheck, test]`
and a skipped dependency skips the dependent. The job still completes, so `needs` stays satisfied.
Posted to issue #120 with this table.

## Decisions Made

- **apt, not pip, for the floor job.** A pip-resolved `cryptography==38.0.4` would only approximate the
  device surface. The container installs the same Debian package the image installs.
- **pnpm 10 in CI, not the plan's 9.** See deviations.
- **Waive, do not fix, the 5 lint errors.** They are dashboard render-logic refactors, pre-existing
  rather than Phase 7 breakage, and pulling them in would blow this plan's blast radius.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] pnpm 9 cannot run in `runtime/dashboard` at all**

- **Found during:** Task 1, while running the plan's own verification commands
- **Issue:** The plan specified keeping `pnpm/action-setup@v4` at `version: 9`. `runtime/dashboard/pnpm-workspace.yaml`
  contains only settings (`ignoredBuiltDependencies: [sharp, unrs-resolver]`) with no `packages` key.
  pnpm 9 reads that file as a workspace definition and aborts with
  `ERR_PNPM_... packages field missing or empty` — reproduced locally with pnpm 9.15.9 on `install`,
  `typecheck` and `test:unit` alike. Every dashboard job would have gone red on infrastructure, making
  the now-blocking `typecheck` and `test` jobs permanently red and defeating the plan's purpose.
- **Fix:** Pinned all four Node jobs to `version: 10`. `node_modules/.modules.yaml` records
  `packageManager: pnpm@10.15.0`, confirming 10 is the version the project is actually developed with.
- **Files modified:** `.github/workflows/ci.yml`
- **Verification:** pnpm 10.34.5: `install --frozen-lockfile` → "Lockfile is up to date"; `typecheck` exit 0;
  `test:unit` exit 0, 20 pass; `build` exit 0.
- **Committed in:** `7750d32`

**2. [Rule 1 - Bug] Floor-job comment overclaimed a superset relationship**

- **Found during:** Task 3
- **Issue:** The comment written in task 1 said the floor job's apt list must stay "a superset of the
  Python entries in `00-packages-nr`". It is not and cannot be: `python3-rpi.gpio` and `python3-spidev`
  have no amd64 equivalent. A future plan trusting that comment would either add unsatisfiable packages
  or conclude the job is broken.
- **Fix:** Reworded to the true invariant — cover the `python3-*` entries `runtime/lib` imports.
- **Files modified:** `.github/workflows/ci.yml`
- **Committed in:** `7adab79`

---

**Total deviations:** 2 auto-fixed (1 x Rule 3, 1 x Rule 1)
**Impact on plan:** Both were necessary for the plan's stated outcome. No scope creep; the 5 lint
errors were left untouched as instructed.

## Issues Encountered

**Task 2 required no code change.** The plan anticipated missing `.keep` files from git's inability to
track empty directories. Audited: all 15 leaf fixture directories under
`runtime/lib/tests/fixtures/proc_asound/` already carry a tracked `.keep`. A fresh clone of the branch
into a temp dir with a clean venv passes **85/85**, and `find .../fixtures -type d -empty` returns
nothing. No file was invented to manufacture a commit for this task.

**Docker Desktop was stuck on a license prompt**, so the floor job was reproduced locally under the
OrbStack context instead. Same `debian:bookworm` image, same result.

**Test count moved 81 → 85 mid-execution.** Plan 07-01 landed `58366ee..03e1d77` on this branch
concurrently, adding `TestIdentityBlock` to `test_arlowe_config.py`. No file overlap with this plan;
both commit sets are disjoint. Dashboard `test:unit` similarly went 17 → 20 via 07-01's tripwire.

## Verification Evidence

- Clean venv + `pytest runtime/lib/tests/ -q` → 85 passed
- Fresh `git clone` + clean venv → 85 passed; no empty fixture dirs
- `debian:bookworm` container, apt packages → `cryptography 38.0.4 requests 2.28.1`, 85 passed
- `runtime/dashboard`: `install --frozen-lockfile`, `typecheck`, `test:unit` (20), `build` all exit 0
- `pnpm lint 2>&1 | grep -c set-state-in-effect` → exactly 5 (asserted, not printed)
- `bash scripts/sanitize/check.sh` → clean, 231 files
- `00-packages-nr` parsed by `build-image.sh`'s guard → 15 declared packages including the 2 new ones
- Net diff for this plan: 108 insertions, 6 deletions across 5 files

## User Setup Required

None.

## Next Phase Readiness

Ready. Every Python test written in 07-03, 07-06, 07-07 and 07-08a will run on every PR, under both
CI python 3.11 and bookworm's 3.11 + cryptography 38.0.4. `runtime/lib/requirements.txt` is final for
Phase 7, so 07-06 and 07-07 can execute in parallel.

**Concerns:**

- These jobs have never executed on GitHub Actions — all verification here is local reproduction of the
  job steps. The first PR that opens against `main` is the real proof. In particular
  `pnpm/action-setup@v4` runs from the repo root where there is no `package.json`; it is given an
  explicit `version`, which should be sufficient, but confirm on the first run.
- `lint` stays non-blocking until issue #120's 5 errors are fixed. Anyone reading a green CI run should
  not read it as "eslint clean".

---
*Phase: 07-device-identity-and-pki*
*Completed: 2026-09-10*
