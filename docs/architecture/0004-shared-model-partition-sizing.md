# ADR-0004: Shared model partition + sizing

<!-- status: accepted -->
**Status:** Accepted
**Date:** 2026-06-13
**Phase:** 6 (Image build with A/B partitions)
**Closes:** IMAGE-04, PART-01, PART-05
**Supersedes:** GATE 1 "16 GB impossible → 32 GB floor" verdict in `.planning/phases/06-image-build-with-a-b-partitions/06-RESEARCH.md`

## Context

Phase 6 research (GATE 1) measured the model artifact sizes needed by Arlowe v1:

| Artifact | Disk size |
|----------|-----------|
| Qwen2.5-7B-Instruct GPTQ-Int4 (AX650 layout) | 5.51 GB |
| Qwen2.5-1.5B-Instruct GPTQ-Int4 AX650 | 1.53 GB |
| faster-whisper small.en | 0.49 GB |
| Piper en_US-lessac-medium | 0.07 GB |
| runtime/ tree | 0.46 GB |

A single shared model set (7B + whisper small.en + piper) totals approximately 6 GB.

The original REQUIREMENTS.md (PART-01/PART-05) described models baked into each rootfs slot — that is, each slot carried its own full copy of the model artifacts alongside the OS and runtime. Under the locked "equal-sized A/B slots" constraint, this produced:

- Qwen 7B config: ~10 GB per slot → ~26.5 GB total (A + B + /boot + owner-state)
- Qwen 1.5B config: ~6 GB per slot → ~16.6 GB total

Both exceed a 16 GB card's ~14.8 GB usable space. GATE 1 concluded 32 GB was a hard floor.

That conclusion is superseded. The owner reversed the "models baked into each slot" decision. Models now live ONCE on a shared partition, not duplicated in each slot.

Model-free slot footprint: Pi OS Lite arm64 (~1.6 GB) + axcl + ALSA/NetworkManager/Python + Python/ML deps + runtime tree ≈ ~2–3 GB per slot.

Fixed overhead with model-free slots: ~5.5 GB (/boot 0.5 GB + slot A ~2.5 GB + slot B ~2.5 GB recovery + owner-state ~2 GB initial). One ~6 GB model set + ~5.5 GB overhead = ~11.5 GB, well within a 16 GB card's ~14.8 GB usable. Approximately 3 GB remains for the models grow-to-fill partition on a 16 GB card; on a 32 GB card that headroom is ~25 GB.

## Decision

A **single shared, read-only, root-owned `models` partition** is mounted at `/opt/arlowe/models` in **both slot A and slot B**. System A and B remain full per-slot rootfs (complete OS + runtime, equal-sized — the locked slot-independence decision is unchanged) but without the bulky model artifacts.

Partition layout (five partitions total):

| Partition | Filesystem | Size | Notes |
|-----------|-----------|------|-------|
| `/boot` (shared FAT) | FAT32 | 512 MB | firmware + both slots' kernels + tryboot configs |
| system A (ext4) | ext4 | ~3 GB + 25% headroom | active root; model-free; fixed size for swap symmetry |
| system B (ext4) | ext4 | equal to A | recovery rootfs in v1; full standby from Phase 9 |
| shared `models` (ext4) | ext4 | grows-to-fill | mounts at `/opt/arlowe/models` in both slots; read-only + root-owned in v1 |
| `/var/lib/arlowe` (ext4, noatime) | ext4 | ~2–4 GB fixed | owner state; FIXED size (not grow-to-fill) |

The **`models` partition is the grow-to-fill partition**: a first-boot service runs `resize2fs` on it once to consume all remaining card space, maximizing headroom for larger models via future model-OTA. `/var/lib/arlowe` owner-state is a **fixed** modest partition. The concrete starting sizes for A, B, and owner-state are MEASURE-THEN-SET values: plan 06-04 measures the assembled model-free slot rootfs with `du` and sets fixed partition numbers from the real data; the models partition takes the remainder.

**Sizing:**
- **16 GB is VIABLE.** One ~6 GB model set + ~5.5 GB fixed overhead (boot + slot A + slot B + owner-state) fits a 16 GB card's ~14.8 GB usable space, leaving ~3 GB for the models grow-to-fill partition on initial image (the first-boot resize2fs expands it to the card's full remainder). IMAGE-04's ≤16 GB target is achievable again.
- **32 GB is RECOMMENDED** for larger-model headroom (~25 GB for the models partition on a 32 GB card) but is NOT mandated. There is no 32 GB floor.

**In v1**, the `models` partition is read-only and root-owned. A v2 model-OTA agent can remount it read-write for updates.

**Models must NOT live on `/var/lib/arlowe` owner-state.** Factory reset (PAIR-07) wipes owner-state, and it is owner-writable. Storing models there would lose them on reset and violate the read-only model contract.

## Accepted tradeoff: v2 OS-OTA model sharing

A future OS slot (v2 OS-OTA) shares the same `models` partition. If a new OS version requires model artifacts in a different format or layout, it cannot swap models atomically with the OS slot — the models partition upgrade must be handled separately.

This is acceptable:
- Phase 9 app-OTA touches `runtime/` only; it never modifies the `models` partition.
- Model-OTA is a v2 concern (MOD-OTA-01 through MOD-OTA-03 are v2 requirements).
- There is no v1 cost to this tradeoff. v2 can introduce a coordinated OS+model-OTA agent if needed.

## Consequences

**Positive:**
- 16 GB cards are viable again. IMAGE-04's target is achievable.
- A single model copy maximizes headroom for larger models as AI capabilities improve.
- Equal-sized A/B slots remain enforced (the model-free slot size is the slot size, and both slots are equal).
- The models partition grow-to-fill approach means larger cards automatically get more model headroom without any build configuration change.

**Negative / known tradeoffs:**
- v2 OS-OTA cannot atomically swap models with the OS slot (see accepted tradeoff above).
- The models partition must be mounted in both slots' `/etc/fstab` by PARTUUID; forgetting this mount in the recovery rootfs (slot B) would prevent recovery from accessing models if recovery ever needs them. Plan 06-05 owns the fstab wiring.

## References

- Research: `.planning/phases/06-image-build-with-a-b-partitions/06-RESEARCH.md` GATE 1 (superseded by this decision)
- Context: `.planning/phases/06-image-build-with-a-b-partitions/06-CONTEXT.md` §Partition sizing + growth
- Plan: `.planning/phases/06-image-build-with-a-b-partitions/06-04-PLAN.md` (measure-then-set partition sizing)
- Plan: `.planning/phases/06-image-build-with-a-b-partitions/06-05-PLAN.md` (fstab wiring for both slots)
- Requirements amended: REQUIREMENTS.md IMAGE-04, PART-01, PART-05
