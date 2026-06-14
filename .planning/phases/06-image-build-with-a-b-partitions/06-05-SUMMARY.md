---
plan: 06-05
phase: 06-image-build-with-a-b-partitions
status: complete
---

## Summary

Implemented the A/B boot selector (tryboot root= swap) and slot-B recovery stub, completing Phase 6 Wave 3.

## Artifacts produced

| File | What it does |
|------|-------------|
| `scripts/lib/boot-config.sh` | Build-time library: writes `config.txt` (tryboot_a_b=1), `cmdline.txt` (default root=slot-A), `tryboot.txt` (Phase 9 reserved), `tryboot_cmdline.txt` (slot-B cmdline) into p1 FAT; installs PARTUUID map into slot-A /etc/arlowe/ |
| `runtime/cli/arlowe-ab` | On-device CLI: `status`, `set A\|B`, `switch A\|B`; rewrites root= in cmdline.txt; Phase 9 OTA seam |
| `scripts/lib/recovery-stub.sh` | Build-time library: clones slot A → slot B, prunes runtime, installs recovery script + service + WhisPlay driver, writes slot-B fstab (models nofail), writes PARTUUID map, enables service |
| `runtime/recovery/arlowe-recovery.sh` | Recovery action: Whisplay face + serial/journal state print + root= reset to A + self-reboot |
| `runtime/recovery/arlowe-recovery.service` | Systemd oneshot, enabled in slot B's multi-user.target.wants |
| `docs/operations/phase-6-ab-recovery.md` | Operations doc: selector mechanism, arlowe-ab usage, SC3 procedure, slot-B experience, Pi 5 freeze caveat, SD-card fallback |

## Design decisions

- `arlowe-ab` reads `/etc/arlowe/ab-partuuid-map` (installed at build time) to resolve A/B names → PARTUUIDs without needing a build host at runtime.
- The root= rewrite primitive is the same in both `arlowe-ab set` and `arlowe-recovery.sh` (shared pattern, not a shared import — keeps slot B's dep surface tiny).
- Recovery stub approach: copy slot A + prune (avoids second debootstrap, keeps B well under 300 MB of active content).
- `tryboot.txt` laid down but NOT used by arlowe-ab — Phase 9 OTA seam preserved.
- `ab` added to `install-arlowe-cli.sh`'s CLIS array so the symlink is created on-device.

## Verification results

- `bash -n`: all scripts pass syntax check
- `shellcheck --severity=warning`: clean across all new scripts
- All plan `<verify>` checks pass (tryboot_a_b, root=, whisplay, oneshot, models/nofail, extension hooks, ops doc)

## What remains

- On-hardware A→B→recovery→A verification (deferred to plan 06-06 on-hardware checkpoint per plan)
- Phase 9 OTA will overwrite `tryboot.txt` and use `arlowe-ab` as the flip primitive
