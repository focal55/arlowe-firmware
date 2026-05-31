---
phase: 03-service-user-and-filesystem-layout
plan: 01
subsystem: infra
tags: [debian, useradd, systemd, docker, filesystem, permissions, provision]

# Dependency graph
requires: []
provides:
  - /opt/arlowe/ directory contract: root:arlowe 0750 with runtime/, third_party/, models/, venvs/, config/ subdirs — see docs/operations/phase-3-layout.md
  - /var/lib/arlowe/ directory contract: arlowe:arlowe 0750 with logs/, conversations/, identity/, state/, wake-word/, dashboard/cache/ subdirs — see docs/operations/phase-3-layout.md
  - /etc/arlowe/ directory: root:arlowe 0755, config.yml intentionally absent (CONFIG-03 pairing trigger)
  - OTA-01 amendment: OTA agent must run as sandboxed-root systemd service (not as arlowe user) with ReadWritePaths=/opt/arlowe; Phase 9 must honor or raise ADR — see docs/operations/phase-3-layout.md §OTA-01
  - Phase 8 pairing-daemon reservation: identity/ is arlowe:arlowe 0700 (writable by arlowe); /etc/arlowe/config.yml write requires root-one-shot pairing daemon pattern — see docs/operations/phase-3-layout.md §Phase 8
  - Docker testbed: tests/phase-3/docker/run-tests.sh — plans 03-02/03/03/04/05 can rely on this harness existing; SC1+SC2 assertions verified green
  - Env-var contract on assertion scripts: ARLOWE_USER / ARLOWE_GROUP / ARLOWE_HOME / ARLOWE_OPT / ARLOWE_ETC with arlowe defaults; plan 03-05 staging harness consumes without edit-back
affects:
  - phase-3-02-systemd-units (units install into /etc/systemd/system; layout already provisioned)
  - phase-3-03-udev-polkit (udev rules need gpio/spi groups which user.sh creates)
  - phase-3-04-cli-symlinks (symlinks target /opt/arlowe/runtime/cli/ which fs.sh creates)
  - phase-3-05-hardware-staging (reuses assertion scripts via ARLOWE_USER=arlowe-staging)
  - phase-4-config-overlay (defaults.yml path reserved at /opt/arlowe/config/; /etc/arlowe/ reserved)
  - phase-6-image-build (pi-gen stage runs install-arlowe-user.sh + install-arlowe-fs.sh unchanged)
  - phase-7-pki (identity/ reserved at /var/lib/arlowe/identity/ mode 0700)
  - phase-8-pairing (pairing trigger: absence of /etc/arlowe/config.yml; identity/ writable)
  - phase-9-ota (OTA-01 amendment: must run as sandboxed-root, not arlowe user)
  - phase-10-support-mode (.ssh/ NOT created by Phase 3; Phase 10 creates at activation)

# Tech tracking
tech-stack:
  added: [debian:bookworm-slim testbed, useradd --system, install -d, docker --privileged]
  patterns: [env-var-driven assertion scripts, auto-discovery provision harness, idempotent install scripts]

key-files:
  created:
    - scripts/provision/install-arlowe-user.sh
    - scripts/provision/install-arlowe-fs.sh
    - tests/phase-3/docker/Dockerfile
    - tests/phase-3/docker/run-tests.sh
    - tests/phase-3/assertions/01-user-shape.sh
    - tests/phase-3/assertions/02-fs-layout.sh
    - tests/phase-3/README.md
    - docs/operations/phase-3-layout.md
  modified:
    - .sanitize-allowlist (added tests/phase-3/assertions/01-user-shape.sh for founder-absent check)

key-decisions:
  - "OTA-01 amendment assumed-accepted: OTA agent must run as sandboxed-root, not arlowe user, because /opt/arlowe is root-owned"
  - "gpio/spi groups created in Dockerfile to simulate Pi OS environment; assertion scripts require them"
  - "install-arlowe-user.sh always runs first in harness (prerequisite for chown); auto-discovery loop skips it after"
  - "dialout + video group membership is speculative; asserted in SC1 with comment to remove if plan 05 finds unnecessary"
  - "run-tests.sh uses --entrypoint /bin/bash to override systemd ENTRYPOINT for harness execution"

patterns-established:
  - "Env-var-driven assertions: ARLOWE_USER/GROUP/HOME/OPT/ETC with sane defaults; re-target by exporting ARLOWE_USER"
  - "Auto-discovery harness: loops scripts/provision/install-arlowe-*.sh sorted, skipping staging; plans 03-02/03/04 just drop scripts"
  - "Idempotent provision scripts: install -d enforces perms on every run; useradd guard; usermod -aG is safe to re-run"
  - "Explicit non-creation: scripts document what they intentionally do NOT create (config.yml, defaults.yml, .ssh/)"

# Metrics
duration: ~90min
completed: 2026-05-31
---

# Phase 3 plan 01 summary

**Idempotent arlowe system-user + /opt/var/etc filesystem layout + Docker SC1/SC2 testbed with env-var-driven assertions**

## Performance

- **Duration:** ~90 min
- **Started:** 2026-05-31
- **Completed:** 2026-05-31
- **Tasks:** 3 (QA red, DEV green, layout doc)
- **Files modified:** 9 (8 created, 1 modified)

## Accomplishments

- `arlowe` system user provisioned (uid < 1000, HOME=/var/lib/arlowe, shell=/usr/sbin/nologin, supplementary groups audio/gpio/spi/dialout/video) via idempotent `install-arlowe-user.sh`
- Full /opt/arlowe/ + /var/lib/arlowe/ + /etc/arlowe/ skeleton created with correct ownership and modes via idempotent `install-arlowe-fs.sh`; explicit non-creation of config.yml, defaults.yml, and .ssh/ documented
- Docker testbed (`tests/phase-3/docker/`) with auto-discovery harness that plans 03-02/03/04 can extend by just dropping scripts — no run-tests.sh edits needed
- SC1 + SC2 assertion scripts verified green; idempotency confirmed (run-twice produces no stat changes)
- OTA-01 amendment documented in `docs/operations/phase-3-layout.md` for Phase 9 scanner pickup

## Task Commits

1. **Task 1: QA writes failing SC1/SC2 assertion scripts + Docker harness** — TDD red verified
2. **Task 2: DEV implements install-arlowe-user.sh + install-arlowe-fs.sh** — TDD green; both assertions pass; idempotency confirmed
3. **Task 3: Layout reference doc** — `docs/operations/phase-3-layout.md` written with OTA-01 amendment + Phase 8 pairing reservation

## Files Created/Modified

- `scripts/provision/install-arlowe-user.sh` — idempotent useradd + usermod -aG for 5 supplementary groups
- `scripts/provision/install-arlowe-fs.sh` — idempotent `install -d` for full /opt/arlowe + /var/lib/arlowe + /etc/arlowe skeleton
- `tests/phase-3/docker/Dockerfile` — debian:bookworm-slim + systemd + gpio/spi groups for Pi OS simulation
- `tests/phase-3/docker/run-tests.sh` — auto-discovery harness with user-first ordering and CLI pre-staging
- `tests/phase-3/assertions/01-user-shape.sh` — SC1: uid range, HOME, shell, founder-absent, group membership
- `tests/phase-3/assertions/02-fs-layout.sh` — SC2: stat-based ownership+mode assertions for every layout path
- `tests/phase-3/README.md` — quickstart, env-var override doc, assertion reference table
- `docs/operations/phase-3-layout.md` — canonical layout reference with OTA-01 amendment + Phase 8 + Phase 10 notes
- `.sanitize-allowlist` — added 01-user-shape.sh (contains intentional `focal55` founder-absent check)

## Decisions Made

- **OTA-01 amendment**: OTA-01 (requirements.md) says "OTA agent runs as arlowe user." /opt/arlowe is root-owned and read-only; arlowe cannot write to it. Amended to "sandboxed-root systemd service with ReadWritePaths=/opt/arlowe." Phase 9 must honor or raise ADR.
- **gpio/spi groups in Dockerfile**: These are Pi OS-specific groups absent from plain Debian. Created in Dockerfile to keep SC1 assertions meaningful in the Docker testbed.
- **Harness user-first ordering**: install-arlowe-user.sh is always run first (prerequisite) before the auto-discovery loop, without renaming scripts to use numeric prefixes. Filenames match the plan contract exactly.
- **--entrypoint /bin/bash**: The Dockerfile sets ENTRYPOINT=["/sbin/init"]; docker run overrides it with --entrypoint so the harness body executes directly.

## Deviations from Plan

### Auto-fixed Issues

**1. Alphabetical sort order placed fs before user**
- **Found during:** Task 2 (first test run)
- **Issue:** `install-arlowe-fs.sh` (`f` < `u`) ran before `install-arlowe-user.sh`, triggering the "arlowe user not found" guard
- **Fix:** Harness runs install-arlowe-user.sh explicitly as prerequisite before the auto-discovery loop; auto-discovery skips it to avoid double-run
- **Verification:** `bash tests/phase-3/docker/run-tests.sh` exits 0

**2. gpio/spi groups absent from debian:bookworm-slim**
- **Found during:** Task 2 (SC1 assertion failure: "missing gpio group")
- **Issue:** Plain Debian bookworm-slim does not include gpio or spi groups; these are Pi OS extras from raspi-gpio packages
- **Fix:** Added `groupadd --system gpio && groupadd --system spi` to Dockerfile
- **Verification:** SC1 assertion passes; arlowe user gets gpio+spi supplementary groups

**3. ENTRYPOINT ["/sbin/init"] swallowed docker run -c arguments**
- **Found during:** Task 2 (docker containers returning empty output)
- **Issue:** Dockerfile ENTRYPOINT takes precedence; `/bin/bash -c '<harness>'` was passed as args to init, not executed
- **Fix:** run-tests.sh uses `--entrypoint /bin/bash` so the harness body runs directly
- **Verification:** Container outputs match expected harness stdout

---

**Total deviations:** 3 auto-fixed (1 ordering, 1 missing Pi OS groups, 1 entrypoint)
**Impact on plan:** All auto-fixes required for correctness. No scope creep. Filenames, behavior, and contracts match the plan specification.

## Issues Encountered

None beyond the three auto-fixed deviations above.

## User Setup Required

None — Docker must be running. Run `bash tests/phase-3/docker/run-tests.sh` from repo root.

## Next Phase Readiness

- Plans 03-02 (systemd units), 03-03 (udev/polkit), 03-04 (CLI symlinks) can start immediately — user + filesystem contract is established
- Docker harness auto-discovers their install scripts with no changes to run-tests.sh
- Plan 03-05 (hardware staging on dev Pi) can re-target assertions via `ARLOWE_USER=arlowe-staging`
- Phase 4 (config overlay) has the /opt/arlowe/config/ parent dir and /etc/arlowe/ dir reserved
- Phase 9 must read the OTA-01 amendment in docs/operations/phase-3-layout.md before planning

---
*Phase: 03-service-user-and-filesystem-layout*
*Completed: 2026-05-31*
