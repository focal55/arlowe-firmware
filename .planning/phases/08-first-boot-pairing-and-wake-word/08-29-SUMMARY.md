---
phase: 08-first-boot-pairing-and-wake-word
plan: 29
subsystem: image-build
tags: [filesystem-layout, permissions, pi-gen, ab-slots, self-test]
requires: []
provides:
  - "/etc/arlowe keeps the chroot's root:arlowe 0770 through image assembly in both slots"
  - "tests/phase-07.1/test-etc-arlowe-mode.sh, run by pr-checks unit-substrate-gate-self-test"
affects: [08-27a, 08 pairing config commit, Phase 4 dashboard overlay write (#202)]
tech-stack:
  added: []
  patterns: ["post-build mount scripts use mkdir -p on contract directories, never install -d with a mode"]
key-files:
  created:
    - tests/phase-07.1/test-etc-arlowe-mode.sh
  modified:
    - scripts/lib/boot-config.sh
    - scripts/lib/recovery-stub.sh
    - .github/workflows/pr-checks.yml
    - docs/operations/phase-3-layout.md
decisions:
  - "sudo mkdir -p rather than install -d -g arlowe -m 0770: the build host has no arlowe group name"
metrics:
  duration: ~15min
  completed: 2026-09-28
---

# Phase 8 Plan 29: /etc/arlowe mode survives image assembly Summary

`boot-config.sh` (slot A) and `recovery-stub.sh` (slot B) ran `install -d -m 0755` on the existing `/etc/arlowe`, resetting the chroot's `root:arlowe 0770`. Both now use `mkdir -p`, and a CI self-test fails on any future `install -d` or `chmod` of that directory to a mode other than 0770.

## Tasks

| Task | Name | Commit |
| ---- | ---- | ------ |
| 1 | Self-test (RED) | a7fb1fd |
| 2 | Fix both scripts and the layout doc (GREEN) | 6b158ff |

## Verification (local, macOS)

- RED on main: `test-etc-arlowe-mode.sh` reported offenders `scripts/lib/boot-config.sh:87` and `scripts/lib/recovery-stub.sh:246`; `[partuuid-map-keeps-mode]` got 755; exit 1.
- GREEN: `test-etc-arlowe-mode.sh` 5 passed, 0 failed; `test-recovery-stub-units.sh` 5 passed, 0 failed.
- shellcheck clean on both scripts and the test; `scripts/sanitize/check.sh --grep-only` clean.
- Not verified here: a built image. 08-27a's read-only inspection of p2/p3 is the image-level proof.

## Deviations from Plan

1. **[Rule 2 - Missing Critical] Added a chmod negative fixture.** The plan listed a chmod rule for the scan but no case exercising it, so that half of the scan could have been vacuous. The test has 5 cases, not 4.
2. **[Rule 1 - Bug] Layout table's "Writable by arlowe?" cell for `/etc/arlowe/` changed from NO to `YES (group, ADR-0003)`.** At 0770 root:arlowe the arlowe group can write it; leaving NO would have kept the doc wrong.
3. **runtime/cli selection by shebang.** Those files have no `.sh` suffix, so the scan includes any `runtime/cli/*` whose first line ends in `bash` or `/sh`.
4. **Size: 106 insertions, 4 deletions (110)** against the plan's ~85, mostly the test (the extra case and portability for macOS bash 3.2: no `mapfile`).

## Next Phase Readiness

Images built before this merges still ship `/etc/arlowe` at 755. Pairing and the dashboard overlay write only work on an image built after it.
