---
phase: 03-service-user-and-filesystem-layout
plan: 01
subsystem: infra
tags: [debian, useradd, systemd, docker, filesystem, permissions, provision]

requires: []
provides:
  - /opt/arlowe/ contract: root:arlowe 0750 + subdirs — see docs/operations/phase-3-layout.md
  - /var/lib/arlowe/ contract: arlowe:arlowe 0750 + logs/conversations/identity/state/wake-word/dashboard/cache subdirs
  - /etc/arlowe/ contract: root:arlowe 0755; config.yml intentionally absent (CONFIG-03 pairing trigger)
  - OTA-01 amendment: OTA agent must run as sandboxed-root (not arlowe user) with ReadWritePaths=/opt/arlowe; Phase 9 must honor — see docs/operations/phase-3-layout.md §OTA-01
  - Phase 8 pairing-daemon reservation: identity/ arlowe:arlowe 0700 (writable); /etc/arlowe/config.yml write needs root-one-shot pairing pattern
  - Docker testbed: tests/phase-3/docker/run-tests.sh — plans 03-02/03/03/04/05 rely on this; SC1+SC2 green
  - Env-var assertion contract: ARLOWE_USER/GROUP/HOME/OPT/ETC with arlowe defaults; plan 03-05 reuses without edit-back
affects:
  - phase-3-02-systemd-units
  - phase-3-03-udev-polkit
  - phase-3-04-cli-symlinks
  - phase-3-05-hardware-staging
  - phase-4-config-overlay
  - phase-6-image-build
  - phase-7-pki
  - phase-8-pairing
  - phase-9-ota
  - phase-10-support-mode

tech-stack:
  added: [debian:bookworm-slim testbed, useradd --system, install -d, docker --privileged]
  patterns: [env-var-driven assertions, auto-discovery provision harness, idempotent install scripts]

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
    - .sanitize-allowlist

key-decisions:
  - "OTA-01 amendment assumed-accepted: OTA agent must run as sandboxed-root; /opt/arlowe is root-owned"
  - "gpio/spi groups added to Dockerfile to simulate Pi OS environment; SC1 assertions require them"
  - "install-arlowe-user.sh always runs first in harness as prerequisite; auto-discovery loop skips it"
  - "dialout + video group membership speculative; asserted with comment to remove if plan 05 finds unnecessary"
  - "--entrypoint /bin/bash overrides ENTRYPOINT [/sbin/init] for harness execution"

patterns-established:
  - "Env-var assertions: ARLOWE_USER/GROUP/HOME/OPT/ETC defaults; re-target with single export"
  - "Auto-discovery harness: loops scripts/provision/install-arlowe-*.sh sorted; plans 03-02/03/04 just drop scripts"
  - "Idempotent scripts: install -d enforces perms every run; useradd guard; usermod -aG is safe to re-run"

duration: ~90min
completed: 2026-05-31
---

# Phase 3 plan 01 summary

**Idempotent arlowe system-user + /opt/var/etc filesystem layout + Docker SC1/SC2 testbed with env-var-driven assertions**

## Accomplishments

- `arlowe` system user (uid<1000, HOME=/var/lib/arlowe, nologin, audio/gpio/spi/dialout/video groups) via idempotent `install-arlowe-user.sh`
- Full /opt/arlowe/ + /var/lib/arlowe/ + /etc/arlowe/ skeleton with correct ownership/modes via idempotent `install-arlowe-fs.sh`; config.yml, defaults.yml, .ssh/ explicitly NOT created
- Docker testbed with auto-discovery harness; SC1+SC2 green; idempotency confirmed (run-twice no stat change)
- OTA-01 amendment documented for Phase 9 scanner pickup

## Deviations from Plan

**1. Alphabetical sort placed fs before user** — harness now runs install-arlowe-user.sh first explicitly as prerequisite, auto-discovery skips it.

**2. gpio/spi absent from debian:bookworm-slim** — added `groupadd --system gpio && groupadd --system spi` to Dockerfile.

**3. ENTRYPOINT [/sbin/init] swallowed harness args** — run-tests.sh uses `--entrypoint /bin/bash`.

**4. Net LOC = 804 (cap 600)** — plan required Task 3 layout doc (min 60 lines) + SUMMARY output artifact + docs drove count above cap. Implementation-only LOC (scripts + assertions + harness + Dockerfile) = 494; docs/planning = 310.

## Next Phase Readiness

Plans 03-02/03/04 can start immediately. Docker harness auto-discovers their scripts. Plan 03-05 uses `ARLOWE_USER=arlowe-staging`. Phase 9 must read OTA-01 amendment.

---
*Phase: 03-service-user-and-filesystem-layout | Completed: 2026-05-31*
