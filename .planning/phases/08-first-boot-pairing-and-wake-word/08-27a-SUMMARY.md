---
phase: 08-first-boot-pairing-and-wake-word
plan: 27a
subsystem: image-build
tags: [pi-gen, build, inputs-reference, rootfs-inspection]
requires: [08-01..08-26, 08-07b, 08-15b, 08-29, "#201"]
provides:
  - "build/arlowe.img on the build host, built from c057696, rootfs proven to carry Phase 8"
  - "inputs reference re-recorded with the four Phase 8 package rows"
affects: [08-27b, 07.3-09]
key-files:
  created: []
  modified:
    - docs/operations/phase-07.2-inputs.reference
    - docs/operations/phase-8-pairing.md
decisions:
  - "Synced the build host with a git bundle plus detached checkout, then an rsync --checksum dry run proved the tree identical; rsyncing a worktree's .git file would have clobbered the host's .git directory"
  - "Preserved build A's image as build/arlowe-07.3-buildA-20260926.img before the build overwrote build/arlowe.img"
metrics:
  duration: "~50 min (build ~30 min)"
  completed: 2026-09-30
---

# Phase 8 Plan 27a: Phase 8 Build Summary

Image built from `c057696` with `BUILD-EXIT 0`. The inputs diff moved exactly the four Phase 8 `pkg` rows plus `source_date_epoch`. A read-only inspection confirmed every Phase 8 unit, link, polkit/NM file and package in slot A, and `/etc/arlowe` is `770 0 992` in both slots.

## Task 1: preconditions (all met)

1. #201 merged (`26c0dc4`, `0692b60`). `grep -c FIRST_USER_PASS pi-gen/config` = 1, and the match is the comment; `grep -c '^FIRST_USER_PASS=' pi-gen/config` = 0. The build gate is `scripts/lib/login-gate.sh` (default-login gate), and it passed on the built rootfs, slot A and slot B.
2. SUMMARYs exist for 08-01 through 08-26, 08-07b, 08-15b and 08-29, and all their merges are on main.
3. N10: 07.3-09 was amended to build from `c008e84` on main (`91140af`, #259). 07.3-09 itself is not closed (ADR-0010 is still Proposed).
4. Main's CI run on `c057696` (Phase 8 workflow): shell tests 6/6 PASS; bookworm container `182 passed, 2 skipped`; PKI broker `66 passed`; Node compat `2 passed`.

## Task 2: build, re-record, inspect

- The build used `CARD_SIZE_GB=32` (the same value as 07.3-08, whose image is 34359738368 bytes), `ARLOWE_INPUTS_ACCEPT=1`, and a clean tree at `c057696` (`worktree_clean true`). `sudo rm -rf build/pi-gen-work` ran first.
- Gates: Debian 0 off-pin; Pi archive 0 off-pin, 0 unattributed; kernel 6.12.96; unit substrate, journal, sanitize, identity-store and default-login gates all OK.
- Diff: `+pkg python3-argon2 21.1.0-2`, `+pkg python3-png 0.20220715.0-1`, `+pkg python3-qrcode 7.4.2-2`, `+pkg python3-typing-extensions 4.4.0-1`, and `source_date_epoch 1790470120 -> 1790737975`. Nothing else moved.
- The rootfs checks are recorded verbatim in `docs/operations/phase-8-pairing.md` section 2 ("Phase 8 build evidence"). The `.bmap` sha256 was the same before and after the inspection.

## Verify

- `grep -c 'Build complete' build/logs/phase-08-build.log` returns 1.
- `grep -cP '^pkg\tpython3-(qrcode|png|typing-extensions|argon2)\t' docs/operations/phase-07.2-inputs.reference` returns 4.
- The diff excluding .planning is 49 lines (5+/1- in the reference, 44 in the runbook).
- The plan's second-build check (a rebuild without the accept passes the gate) was not run, as the plan specifies.

## Deviations from Plan

1. **[Rule 3 - Blocking] Sync method.** The worktree's `.git` is a file, so the tree could not be rsynced with its git metadata. I bundled main's head, fetched the bundle into the host's own repo (no GitHub), and ran `git checkout --detach c057696`. An `rsync -anc` dry run then showed zero content differences. Before that I discarded the host's uncommitted reference edit; it was byte-identical to main's (`git diff c057696` empty). After the build I restored the host tree to clean `c057696`.
2. **Build run detached, not through `| tee`.** Per the dispatch, I used a nohup wrapper (`build/run-build-08.sh`) that writes the same log path and appends `BUILD-EXIT`.
3. **Slot B unit checks.** The plan's unit and link checks apply to the system slot (A). Slot B has none of the 12 repo units because `recovery-stub.sh` removes them and enables only `arlowe-recovery.service`. This is by design and is not a defect. Slot B does still carry `runtime/pair`, `runtime/cli`, the polkit rule and the NM files, because the prune does not cover them.
4. **Ownership display.** The host shows GID 992 as `render`. Ownership was verified numerically against the image's `etc/group`, as the plan requires.

## Next Phase Readiness (for 08-27b)

- The image is `build/arlowe.img` (+ `.bmap`) on the build host, built from `c057696`. The SSH key is **not** staged yet: do runbook section 2's rw key step, then regenerate the `.bmap`.
- A 32 GiB image needs a 64 GB card. Flash from the Mac's SD slot with read-back, not the SY-T18 USB reader.
- Build A's image was kept as `build/arlowe-07.3-buildA-20260926.img`.
