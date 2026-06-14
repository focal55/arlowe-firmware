# Phase 6 partition layout

**Status:** Build reference — canonical measured values will be filled in after
the first real image build (plan 06-06 on-hardware checkpoint).

---

## Five-partition layout

The arlowe image uses five GPT partitions. Partition order is fixed across all
supported card sizes.

| # | Label | Filesystem | Mount point | Size | Notes |
|---|-------|-----------|-------------|------|-------|
| p1 | boot | FAT32 | `/boot/firmware` | 512 MiB | Shared firmware + both slots' kernels + tryboot configs |
| p2 | system\_a | ext4 | `/` (active root) | measured (see below) | Model-free rootfs; fixed size for A/B swap symmetry |
| p3 | system\_b | ext4 | `/` (standby root) | equal to p2 | Recovery rootfs in v1; full standby from Phase 9 OTA |
| p4 | owner\_state | ext4 | `/var/lib/arlowe` | ~3 GiB fixed | Owner state; noatime; FIXED (not grow-to-fill) |
| p5 | models | ext4 | `/opt/arlowe/models` | seed + grows-to-fill | Shared read-only model store; mounted ro,noatime in both slots |

### Key design properties

- **Model-free slots:** system A and B do not contain model artifacts. Models
  live exclusively on p5 (mounted read-only at `/opt/arlowe/models`). This
  keeps slot size around ~2–3 GiB, enabling 16 GB cards.
- **Equal A/B size:** slot A and slot B are always the same partition size.
  True-swap symmetry is required for Phase 9 OS-OTA.
- **Models is the grow-to-fill partition (p5, LAST):** placing models last
  allows `growpart` to extend p5 to the disk end on first boot without
  relocating any subsequent partition.
- **Owner-state is FIXED (p4):** `/var/lib/arlowe` must NOT grow to fill the
  card. Factory reset (PAIR-07) wipes owner-state; models stored there would be
  lost. Its fixed size is set at image build time (~3 GiB per ADR-0004).

---

## Measured sizing (MEASURE-THEN-SET)

Partition sizes for system A/B are derived from a real `du` measurement of the
assembled model-free rootfs, not from estimates. The models partition initial
size is derived from a `du` measurement of the models staging tree.

### Rule

```
slot_size = du_rootfs_bytes + 25% headroom, rounded up to 64 MiB boundary
models_initial_size = du_models_bytes + 25% headroom, rounded up to 64 MiB
```

### Example (reference build — fill in after first real build)

| Measurement | Value |
|-------------|-------|
| Model-free rootfs (`du -sb`) | TODO: run build-image.sh and record |
| Slot size (rootfs + 25%, 64 MiB aligned) | TODO |
| Models staging tree (`du -sb`) | TODO |
| Models initial partition size | TODO |

ADR-0004 reference values (starting points, not hard requirements):

| Item | ADR-0004 estimate |
|------|-------------------|
| Model-free slot size | ~2–3 GiB |
| Models set (Qwen 7B + Whisper small.en + Piper) | ~6 GiB |
| Owner-state | ~2–4 GiB |

Build-image.sh logs both measured values and the chosen slot size during every
run. Record the numbers from the first successful build here.

---

## Card size requirements

| Card size | Viability | Notes |
|-----------|-----------|-------|
| 16 GB (~14.8 GiB usable) | **Viable** | Fixed overhead ~5.5 GiB (boot + slot A + slot B + owner-state) + ~6 GiB models seed ≈ ~11.5 GiB. Leaves ~3 GiB for models grow-to-fill on initial image. |
| 32 GB (~29.8 GiB usable) | **Recommended** | ~25 GiB models grow-to-fill headroom. Accommodates larger future models without reflashing. |
| 64 GB | Supported | Models partition grows to ~58 GiB on first boot. |

16 GB is **viable** per ADR-0004 (the single shared models partition makes it
feasible again after the earlier "models baked in each slot" design was
abandoned). 32 GB is **recommended** for larger-model headroom.

---

## Models partition: grow-to-fill behavior

On first boot, `arlowe-grow-models.sh` runs as an `ExecStartPre=` step in
`arlowe-firstboot.service`:

1. Checks sentinel `/var/lib/arlowe/.models-grow-done`. Exits 0 immediately if
   it exists (idempotent — never grows more than once).
2. Verifies the models partition (p5) is the last partition on the disk
   (safety check — aborts if not, to prevent corruption).
3. **Unmounts `/opt/arlowe/models`** — `arlowe-firstboot.service` has
   `After=local-fs.target`, and the models fstab entry (`ro,noatime`, pass=2,
   no `noauto`) causes systemd-fstab-generator to mount p5 as part of
   `local-fs.target` before `ExecStartPre=` fires. The grow script explicitly
   unmounts the partition before resizing so that e2fsck and resize2fs operate
   against an unmounted device (offline resize).
4. Runs `growpart <disk> 5` to extend the GPT partition entry to the disk end.
5. Runs `e2fsck -pf` (exit codes ≥ 4 abort the script to prevent resizing a
   corrupt filesystem) then `resize2fs` on the now-unmounted partition device.
6. **Remounts `/opt/arlowe/models`** so the runtime sees the grown partition.
7. Writes the sentinel.

**What is NOT grown:** system A (p2), system B (p3), and owner-state (p4) are
never touched by the grow script. They are fixed-size partitions.

---

## fstab (both slots)

Both slot A and slot B carry identical fstab entries for the shared partitions
(boot, models). The root entry (`/`) is not in fstab — it is supplied by the
kernel `root=` parameter (tryboot config, per ADR-0005).

```
# Boot firmware — shared FAT
PARTUUID=<boot-partuuid>    /boot/firmware      vfat  defaults          0  2

# Owner state — FIXED, noatime
PARTUUID=<owner-partuuid>   /var/lib/arlowe     ext4  defaults,noatime  0  2

# Shared model store — read-only in v1 (ADR-0004)
PARTUUID=<models-partuuid>  /opt/arlowe/models  ext4  ro,noatime        0  2
```

PARTUUIDs are written by `scripts/lib/partition-image.sh` at image build time.
The models PARTUUID replaces the placeholder token
`ARLOWE-MODELS-PARTUUID-REPLACE-BY-06-04` that plan 06-03 left in the rootfs
fstab during chroot provisioning.

---

## One image, multiple card sizes

The image is built at the target card size (default 32 GB; 16 GB supported via
`CARD_SIZE_GB=16`). When flashed to a larger card, the grow-to-fill behavior
ensures the models partition expands automatically on first boot — no
card-size-specific build required.

The boot, A, B, and owner-state partition sizes are fixed and do not change
regardless of card size. Only the models partition absorbs the extra space.

---

## Flash time

TODO: record flash time after first real build (plan 06-06).

Typical `dd`/`bmaptool` flash times for reference:
- 32 GB image to SD: ~10–20 minutes with `dd`; ~2–5 minutes with `bmaptool`
  (sparse write skips unwritten sectors).

---

## References

- ADR-0004: `docs/architecture/0004-shared-model-partition-sizing.md`
- ADR-0005: `docs/architecture/0005-ab-selector-tryboot-root-swap.md`
- Build script: `scripts/build-image.sh`
- Partition library: `scripts/lib/partition-image.sh`
- Grow script: `pi-gen/stage-arlowe/03-firstboot/files/arlowe-grow-models.sh`
- First-boot service: `pi-gen/stage-arlowe/03-firstboot/files/arlowe-firstboot.service`
