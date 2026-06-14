# ADR-0005: A/B selector — tryboot root= swap

<!-- status: accepted -->
**Status:** Accepted
**Date:** 2026-06-13
**Phase:** 6 (Image build with A/B partitions)
**Closes:** PART-02, SC3
**Corrects:** REQUIREMENTS.md PART-02/ROADMAP.md SC3 wording ("U-Boot env or `/boot/active.txt`")

## Context

REQUIREMENTS.md PART-02 and ROADMAP.md SC3 described the A/B boot selector as reading "a flag (U-Boot env or `/boot/active.txt`)". This is wrong for the locked single-shared-`/boot` + Pi-native tryboot design. This ADR records the correct mechanism.

**Pi 5 firmware A/B: two styles**

The Pi bootloader reads `/boot/firmware/autoboot.txt` early (before `config.txt`). Two A/B styles exist:

*Style 1 — partition-level (firmware default):* `autoboot.txt` carries `[all] boot_partition=N` and `[tryboot] boot_partition=M`. Normal boot uses partition N; `reboot "0 tryboot"` does a one-shot boot from partition M, reverting on the next power-cycle. Each slot is its own FAT boot partition with its own `config.txt` and kernel. **This is the two-FAT-boot-partition style.** The locked decision explicitly rejects it: Phase 6 requires a single shared `/boot` partition (SC2), so two FAT boot partitions are out.

*Style 2 — file-level within one boot partition (the locked design):* Set `tryboot_a_b=1` in `config.txt`. When the tryboot flag is set, firmware loads **`tryboot.txt`** instead of **`config.txt`** from the same FAT partition. Slot A's `config.txt` sets `cmdline`/`root=` to rootfs partition A; `tryboot.txt` sets `root=` to rootfs partition B. One shared `/boot`, both kernels present, slots distinguished only by the `root=` they point at. This is the Pi-native mechanism that makes Style 1's "partition-level" behavior file-level inside one boot partition.

**One-shot vs persistent semantics**

`reboot "0 tryboot"` is **one-shot**: it boots `tryboot.txt` once; any subsequent reboot or power-cycle reverts to `config.txt` (slot A). The free fallback behavior is desirable for Phase 9 OTA trial-boot, but it means `reboot "0 tryboot"` cannot implement a *persistent* slot flip.

To flip the **persistent** default to slot B, `arlowe-ab` must rewrite the `root=` in `config.txt` to point at slot B's PARTUUID — making `config.txt` itself carry slot B's boot parameters.

**No U-Boot, no `active.txt`**

U-Boot is not used on this platform. There is no custom initramfs that reads a flag file. `/boot/active.txt` is not part of the design.

## Decision

The **persistent A/B default** is the `root=` (or inline `cmdline=`) in the shared `/boot/firmware/config.txt`. `arlowe-ab` implements the persistent flip by rewriting the `root=` in `config.txt` to point at the target slot's PARTUUID, then rebooting. The recovery stub in slot B self-heals by rewriting `config.txt`'s `root=` back to slot A's PARTUUID and rebooting.

`tryboot_a_b=1` is set in `config.txt`. The resulting boot layout:

```
/boot/firmware/
  config.txt      # persistent default; root= points at slot A PARTUUID (factory default)
  tryboot.txt     # one-shot trial slot (reserved for Phase 9 OTA trial-boot; in v1 mirrors B/recovery)
  cmdline.txt     # or inline cmdline= in config.txt
  kernel_2712.img # Pi 5 kernel (shared by both slots)
  *.dtb, overlays/
```

**`arlowe-ab` owns the `root=` rewrite** as the seam Phase 9 OTA reuses. It is the single controlled path for changing the persistent default. Phase 9 OTA calls `arlowe-ab` rather than writing `config.txt` directly.

**`tryboot.txt` + `reboot "0 tryboot"` are RESERVED for Phase 9** OTA one-shot trial-boot. They are not used for v1 persistent flips.

Both slots mount the same shared `models` partition (ADR-0004) at `/opt/arlowe/models`. The A/B selector swaps only the rootfs `root=`; the models mount is identical for both slots and is not part of the flip logic.

## Consequences

**Positive:**
- No U-Boot dependency. No custom initramfs. The selector is pure Pi firmware + a config file rewrite.
- `arlowe-ab` is the sole abstraction Phase 9 OTA calls; the implementation detail (which file, which key) is encapsulated.
- The one-shot `tryboot.txt` / `reboot "0 tryboot"` path remains available for Phase 9 without any v1 changes.
- The slot-B recovery stub self-heals (resets default to A) without requiring a reflash.

**Negative / known constraints:**
- A corrupted or incompatible kernel on Pi 5 can freeze the bootloader rather than auto-falling back; a power-cycle recovers. This is a Pi 5 hardware characteristic relevant to the recovery framing (PART-06): document "if it freezes after a bad slot flip, power-cycle."
- The persistent default lives in `config.txt` inside the FAT partition; `arlowe-ab` must mount `/boot/firmware` read-write to rewrite it and must sync before rebooting to avoid a partial write on power-loss mid-flip.
- Boot-count / automatic A↔B rollback on failed boots is deferred to Phase 9. In v1 there is no auto-rollback; manual intervention or recovery-slot self-heal is the recovery path.

## References

- Research: `.planning/phases/06-image-build-with-a-b-partitions/06-RESEARCH.md` GATE 2
- Context: `.planning/phases/06-image-build-with-a-b-partitions/06-CONTEXT.md` §A/B switch mechanism, §A/B flip + fallback, §Slot B recovery experience
- Plan: `.planning/phases/06-image-build-with-a-b-partitions/06-05-PLAN.md` (arlowe-ab CLI + recovery stub)
- ADR-0004: shared model partition (models mount is identical for both slots; selector is rootfs-only)
- Requirements amended: REQUIREMENTS.md PART-02, PART-03; ROADMAP.md Phase 6 SC3
