# Phase 6 A/B boot selector + slot-B recovery

**Status:** Implementation reference — covers the tryboot root= swap selector,
the `arlowe-ab` CLI, and the slot-B recovery experience.

---

## A/B selector overview (ADR-0005)

The persistent A/B default is the `root=` (via `cmdline.txt`) inside the single
shared `/boot/firmware` FAT partition (p1). Per ADR-0005:

- `config.txt` sets `tryboot_a_b=1` and includes `cmdline.txt`.
- `cmdline.txt` holds the active `root=PARTUUID=<uuid>` line. This is the only
  field that changes between slot A and slot B — all other kernel flags are
  identical.
- `arlowe-ab` is the sole path for changing the persistent default. It rewrites
  only the `root=` in `cmdline.txt` and reboots. No other file is touched.
- The A/B selector swaps **only the rootfs** `root=`. Both slot A and slot B
  mount the **same shared read-only models partition** (`/opt/arlowe/models`)
  via their respective `/etc/fstab` entries. The selector does not touch the
  models mount (ADR-0004).

### tryboot.txt — RESERVED for Phase 9 OTA

`tryboot.txt` is present in `/boot/firmware` and mirrors the slot-B parameters
so that a manual `reboot 0 tryboot` lands on the recovery rootfs safely. This
file is **not used by `arlowe-ab`** for persistent flips. Phase 9 OTA will
overwrite `tryboot.txt` with trial-slot parameters before issuing
`reboot 0 tryboot`. Do not modify `tryboot.txt` manually.

### Boot config files

| File | Purpose |
|------|---------|
| `config.txt` | Sets `tryboot_a_b=1`; includes `cmdline.txt` |
| `cmdline.txt` | Active `root=` line; edited by `arlowe-ab` |
| `tryboot.txt` | Reserved for Phase 9 OTA one-shot trial-boot |
| `tryboot_cmdline.txt` | Cmdline for the tryboot one-shot path (slot B) |

---

## arlowe-ab — A/B slot selector CLI

Installed at `/usr/local/sbin/arlowe-ab` via `install-arlowe-cli.sh`.
Must be run as root.

### Usage

```
arlowe-ab status          # print current persistent default slot + PARTUUID
arlowe-ab set A|B         # rewrite cmdline.txt root=; no reboot
arlowe-ab switch A|B      # set + reboot
```

### Manual A→B flip (SC3 verification procedure)

1. SSH into the device as root (or `sudo su`).
2. Check current slot:
   ```
   arlowe-ab status
   # → Persistent default: slot A (root=PARTUUID=<uuid>)
   ```
3. Flip to slot B and reboot:
   ```
   arlowe-ab switch B
   ```
4. Device reboots into slot B (recovery rootfs in v1).
5. The slot-B recovery service runs: shows a recovery face on the Whisplay,
   logs state, resets the persistent default back to slot A, and reboots again.
6. After the self-heal reboot, the device is back in slot A:
   ```
   arlowe-ab status
   # → Persistent default: slot A (root=PARTUUID=<uuid>)
   ```

### PARTUUID map

`arlowe-ab` reads `/etc/arlowe/ab-partuuid-map` to resolve slot A/B names to
real PARTUUIDs. This file is written by `boot-config.sh` at image build time
and is present in both slot A and slot B rootfs images.

### Implementation notes

- Mounts `/boot/firmware` read-write before writing, then remounts read-only.
- Writes `cmdline.txt` atomically (write to `.tmp`, rename, sync) to minimise
  partial-write exposure on power-loss mid-flip.
- Does not use `reboot 0 tryboot` or `tryboot.txt` — those are Phase 9 OTA only.

---

## Slot-B recovery rootfs

Slot B (`system_b`, p3) holds a minimal model-free recovery rootfs in v1. It is
a pruned copy of slot A with the Arlowe runtime and models removed, leaving only
the OS, Python, the WhisPlay driver, and the recovery service.

### What slot B does at boot

`arlowe-recovery.service` is a systemd oneshot enabled in slot B's
`multi-user.target.wants`. It runs `arlowe-recovery.sh`, which:

1. Shows a static recovery face on the Whisplay display (red background,
   "RECOVERY / Resetting to slot A / Rebooting...").
2. Prints recovery state to serial (`/dev/ttyAMA0`) and journal: hostname,
   kernel version, uptime, current cmdline, PARTUUID map.
3. Resets the persistent default to slot A: mounts `/boot/firmware` read-write,
   rewrites `root=` in `cmdline.txt` back to slot A's PARTUUID, syncs, remounts
   read-only.
4. After 15 seconds (configurable via `RECOVERY_REBOOT_DELAY`), reboots into
   slot A.

### Recovery experience — what you will see

- The Whisplay lights up with a red recovery screen.
- Serial console (`/dev/ttyAMA0`, 115200 baud) and `journalctl` show
  `[arlowe-recovery]` lines.
- Device reboots into slot A after ~15 seconds.

### Models partition in slot B

Slot B's `/etc/fstab` carries the same shared models partition entry as slot A
(`PARTUUID=<models-uuid> /opt/arlowe/models ext4 ro,noatime,nofail`), but with
`nofail` set. Recovery boots and runs correctly even if the models partition is
absent or unmounted — the recovery face is a static framebuffer draw that does
not depend on any model artifacts.

### Pi 5 freeze caveat

If the Pi 5 bootloader encounters a corrupted or incompatible kernel, it may
**freeze rather than auto-falling back to the previous slot**. This is a Pi 5
firmware characteristic (no automatic rollback on kernel failure in v1 —
boot-count rollback is deferred to Phase 9).

**If the device freezes after a slot flip:** power-cycle the device. The device
will resume from `/boot/firmware/cmdline.txt`; if the persistent default was
reset to slot A before the freeze, it will boot into slot A normally.

---

## Recovery SD-card fallback (PART-06)

If slot A is also corrupted or the device is otherwise unrecoverable via the
A/B self-heal path, the v1 fallback is to flash a fresh image to a spare SD
card.

### Procedure

1. Download or build a fresh `arlowe.img`:
   - Use the pre-built release artifact, or
   - Run `scripts/build-image.sh` on an arm64 Linux build host.

2. Flash to a spare SD card (minimum 16 GB; 32 GB recommended):
   ```bash
   # With dd (slow, fully-corect):
   sudo dd if=arlowe.img of=/dev/sdX bs=4M status=progress conv=fsync
   # With bmaptool (fast, sparse-aware — recommended):
   sudo bmaptool copy arlowe.img /dev/sdX
   ```

3. Insert the spare SD card into the device and power on. The device will boot
   into slot A on the freshly flashed image.

4. After recovery, transfer owner-state from the original SD card if needed
   (mount p4 `owner_state` from the old card and rsync `/var/lib/arlowe/`).

See `docs/operations/phase-6-partitions.md` for partition layout reference.

---

## References

- ADR-0005: `docs/architecture/0005-ab-selector-tryboot-root-swap.md`
- ADR-0004: `docs/architecture/0004-shared-model-partition-sizing.md`
- Boot config library: `scripts/lib/boot-config.sh`
- Recovery stub library: `scripts/lib/recovery-stub.sh`
- A/B CLI: `runtime/cli/arlowe-ab`
- Recovery service: `runtime/recovery/arlowe-recovery.service`
- Recovery script: `runtime/recovery/arlowe-recovery.sh`
- Partition layout: `docs/operations/phase-6-partitions.md`
- Build script: `scripts/build-image.sh`
