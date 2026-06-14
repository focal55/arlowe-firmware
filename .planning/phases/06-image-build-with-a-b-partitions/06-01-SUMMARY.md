---
plan: 06-01
phase: 06-image-build-with-a-b-partitions
status: complete
date: 2026-06-13
---

## What was done

Two ADRs written and REQUIREMENTS.md / ROADMAP.md Phase 6 text amended to reflect two design decisions that contradicted the existing spec.

### ADR-0004 — Shared model partition + sizing

`docs/architecture/0004-shared-model-partition-sizing.md`

Records the reversal of "models baked into each rootfs slot" in favor of a single shared read-only `models` partition mounted at `/opt/arlowe/models` in both slots. Includes measured model-size evidence from GATE 1 (Qwen 7B 5.51 GB, Qwen 1.5B 1.53 GB, Whisper small.en 0.49 GB, Piper 0.07 GB). States that the GATE 1 "32 GB floor" conclusion is superseded. Documents 16 GB as viable (one ~6 GB model set + ~5.5 GB fixed overhead fits a 16 GB card's ~14.8 GB usable), 32 GB recommended but not mandated. Records the accepted v2-OS-OTA model-sharing tradeoff.

### ADR-0005 — A/B selector: tryboot root= swap

`docs/architecture/0005-ab-selector-tryboot-root-swap.md`

Corrects PART-02/SC3 "U-Boot env or /boot/active.txt" wording. Records the Pi-native tryboot mechanism: `tryboot_a_b=1` + file-level slot distinction inside one shared /boot FAT partition. Documents that `reboot "0 tryboot"` is one-shot (reverts on power-cycle), so the persistent default flip must rewrite `root=` in `config.txt`. `arlowe-ab` owns the rewrite; `tryboot.txt` + one-shot path are reserved for Phase 9 OTA trial-boot.

### REQUIREMENTS.md amendments

- IMAGE-02: models stage now describes shared read-only `models` partition; "pairing daemon armed" replaced with "first-boot hook armed — ready-to-pair state; the pairing daemon itself is Phase 8"
- IMAGE-03: reframed as input reproducibility (pinned inputs); no image-hash gate (ext4 nondeterminism); documented exception list
- IMAGE-04: "≤ 16 GB target" changed to "≤ 16 GB viable ... 32 GB recommended" with ADR-0004 citation
- PART-01: "four partitions" changed to "FIVE partitions" with the shared models partition listed
- PART-02: U-Boot/active.txt wording replaced with tryboot_a_b=1 / root= / arlowe-ab description; ADR-0005 cited
- PART-03: "system B is empty/standby in v1" replaced with "minimal recovery rootfs that boots to recovery and resets default to A"
- PART-05: reframed with model-free slot sizing, grow-to-fill models partition, FIXED owner-state, ADR-0004 citation

### ROADMAP.md Phase 6 amendments

- Goal line: reframed from "small enough to fit on a 16 GB SD card" to "shared model partition keeps a 16 GB SD card viable (32 GB recommended)"
- SC1: "pairing daemon armed" → "first-boot hook armed — ready-to-pair state; the pairing daemon itself is Phase 8"; "16 GB+ SD card" → "16 GB+ SD card (32 GB recommended)"
- SC2: "four partitions" → "FIVE partitions" with five-partition list; grow-to-fill and sizing note
- SC3: U-Boot/active.txt/empty-B wording replaced with tryboot root= selector and minimal recovery rootfs
- SC5: appended "(input reproducibility only; no image-hash gate — ext4 nondeterminism documented as an exception)"

Phase 8 block was not touched (pairing daemon wording there is correct for Phase 8).

## Verification results

All 18 greps from the plan passed:
- ADR-0004: file exists, contains "shared", "5.51", "grow-to-fill", "16 GB"
- ADR-0005: file exists, contains "tryboot_a_b", "root="
- REQUIREMENTS.md: "single shared read-only", "FIVE partitions", "tryboot", "first-boot hook armed" present; "four partitions", "pairing daemon armed", "32 GB floor/minimum" absent
- ROADMAP.md: "FIVE partitions", "first-boot hook armed" present; "16 GB budget", "four partitions" absent
