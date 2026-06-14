---
phase: 06-image-build-with-a-b-partitions
plan: 04
status: complete
pr: 114
---

# Summary: build-image.sh + 5-partition A/B layout + shared models grow + sanitize gate

## What was built

### Task 1: scripts/build-image.sh — full pipeline orchestration

- Runs `verify-third-party.sh` FIRST; aborts if any dep is missing/mismatched.
- Drives pi-gen (arm64 branch, `SKIP_IMAGES=1`) through `stage0 stage1 stage2
  stage-arlowe` to produce the model-free rootfs and the separate models
  staging tree (assembled by 06-03's `02-models/00-run.sh`).
- MEASURES both with `du -sb`: rootfs bytes and models bytes. Computes slot
  size = rootfs + 25% headroom, rounded up to 64 MiB boundary. Logs both
  measured values and the chosen slot size loudly. Warns (does not abort) if
  either value materially exceeds ADR-0004's reference estimates.
- Calls `scripts/lib/partition-image.sh` (`build_partition_image` function)
  with measured sizes, rootfs path, and models staging tree path.
- **Extension point for plan 06-05:** sources `scripts/lib/boot-config.sh`
  (calls `write_boot_config`) and `scripts/lib/recovery-stub.sh` (calls
  `write_recovery_stub`) if those files exist. Absent files are skipped with a
  log note — 06-05 wires in by dropping its libs alongside, with no
  restructuring of this script needed.
- SANITIZE GATE: loop-mounts slot A read-only; runs `check.sh --scan-dir` over
  the assembled rootfs (SANIT-08 — no banned literals or forbidden unit names
  in the real image). Requires `rg` on the build host. Non-zero exit aborts.
- Emits the final `.img` to `$OUTPUT_IMG` (default: `build/arlowe.img`),
  prints its size and the full partition table via `parted -s print`.

### Task 2: scripts/lib/partition-image.sh — 5-partition layout library

Implements build-blank-then-rsync for the five-partition shared-model A/B layout:

**Partition order (models LAST for grow-to-fill):**
- p1 `/boot` FAT32 — 512 MiB
- p2 system A ext4 — measured model-free slot size
- p3 system B ext4 — equal to p2 (true-swap symmetry)
- p4 `/var/lib/arlowe` ext4 — ~3 GiB FIXED (owner-state; not grow-to-fill)
- p5 `models` ext4 — seed + grows-to-fill on first boot (LAST for clean growpart)

Partition layout justification: placing models (p5) last means `growpart` can
extend it to the disk end without any subsequent partition to relocate. The
FIXED owner-state (p4) sits before it at a fixed size.

Steps: create blank sparse `.img` → GPT + 5 partitions via `parted` → loop-mount
→ `mkfs.vfat` (boot) + `mkfs.ext4` (A, B, owner, models) → rsync model-free
rootfs into slot A → copy boot files into FAT → seed models partition from
staging tree → write slot-A fstab (boot PARTUUID + owner-state noatime PARTUUID
+ models ro,noatime PARTUUID, with the placeholder token from 06-03 substituted)
→ export all five PARTUUIDs to the map file.

The PARTUUID map file is consumed by build-image.sh's sanitize step (slot-A
loop-mount) and by plan 06-05's boot-config and recovery-stub extensions.

### Task 3: arlowe-grow-models.sh + arlowe-firstboot.service + docs

**`pi-gen/stage-arlowe/03-firstboot/files/arlowe-grow-models.sh`:**
- First-boot, run-once, idempotent grow of the MODELS partition (p5) only.
- Sentinel at `/var/lib/arlowe/.models-grow-done` — exits 0 immediately on
  subsequent boots.
- Safety check: verifies p5 is the last partition (aborts if not, to prevent
  GPT corruption).
- Unmounts `/opt/arlowe/models` (mounted ro by local-fs.target before
  ExecStartPre= fires), then runs `growpart <disk> 5` → `e2fsck -pf` →
  `resize2fs` against the unmounted partition device, then remounts ro.
- A, B, and owner-state partitions are never touched.

**`arlowe-firstboot.service` (updated):**
- Added `ExecStartPre=/opt/arlowe/runtime/cli/arlowe-grow-models` stanza before
  the existing `ExecStart=/opt/arlowe/runtime/cli/boot-check --first-boot`.
- local-fs.target mounts the models partition ro before ExecStartPre= fires;
  the script unmounts it, resizes, then remounts it before the main service
  body runs.

**`pi-gen/stage-arlowe/03-firstboot/00-run-chroot.sh` (updated):**
- Installs `arlowe-grow-models.sh` to `/opt/arlowe/runtime/cli/arlowe-grow-models`
  (executable, root-owned) from the pi-gen `files/` tree.

**`docs/operations/phase-6-partitions.md`:**
- Five-partition layout table (p1-p5, all properties).
- Measured sizing explanation (MEASURE-THEN-SET rule + TODO placeholders for
  first real build numbers).
- Card size viability: 16 GB viable, 32 GB recommended (ADR-0004 rationale).
- Models grow-to-fill behavior (steps, sentinel, safety constraints).
- fstab format for both slots.
- One image, multiple card sizes note.

## Key design decisions followed

- **ADR-0004 partition layout:** models last (p5) for clean growpart; owner-state
  FIXED (p4); equal-sized model-free A/B (p2/p3); 16 GB viable.
- **Measure-then-set:** all partition sizes derived from `du` on real artifacts, not
  estimates. ADR-0004 estimates are reference points with mismatch warnings.
- **Extension point architecture:** 06-05's boot-config and recovery-stub libs drop
  in via source + function call; build-image.sh checks for their presence and skips
  gracefully when absent.
- **PARTUUID placeholder substitution:** the `ARLOWE-MODELS-PARTUUID-REPLACE-BY-06-04`
  token left by 06-03's chroot is replaced with the real models PARTUUID in
  partition-image.sh's fstab write step.

## Deferred to 06-05

- `scripts/lib/boot-config.sh` — tryboot_a_b=1, config.txt/tryboot.txt, persistent
  default root= pointing at slot A's PARTUUID.
- `scripts/lib/recovery-stub.sh` — writes minimal recovery rootfs into slot B (p3).
- `runtime/cli/arlowe-ab` — on-device A/B persistent-default flip CLI.
- Slot B fstab (identical to slot A's shared mounts).

## Verification

All plan verification checks passed:

```
bash -n scripts/build-image.sh                                              OK
grep "verify-third-party" scripts/build-image.sh                            OK
grep "scan-dir" scripts/build-image.sh                                      OK
grep -qi "du " scripts/build-image.sh                                       OK
grep -qi "models" scripts/build-image.sh                                    OK

bash -n scripts/lib/partition-image.sh                                      OK
grep "mkfs.ext4" scripts/lib/partition-image.sh                             OK
grep "rsync" scripts/lib/partition-image.sh                                 OK
grep -qi "PARTUUID" scripts/lib/partition-image.sh                          OK
grep -qi "models" scripts/lib/partition-image.sh                            OK

bash -n pi-gen/stage-arlowe/03-firstboot/files/arlowe-grow-models.sh       OK
grep "resize2fs" arlowe-grow-models.sh                                      OK
grep -qi "models" arlowe-grow-models.sh                                     OK
test -f docs/operations/phase-6-partitions.md                               OK
grep -qi "five partitions" docs/operations/phase-6-partitions.md            OK
grep -qi "16 GB" docs/operations/phase-6-partitions.md                      OK
```

shellcheck: not installed on the Mac dev environment; scripts use standard
bash constructs only. Will run on arm64 Linux CI.
