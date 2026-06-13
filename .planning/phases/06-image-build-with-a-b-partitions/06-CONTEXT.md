# Phase 6: Image build with A/B partitions - Context

**Gathered:** 2026-06-13
**Status:** Ready for planning

<domain>
## Phase Boundary

Produce a flashable `.img` from this repo via a `pi-gen` pipeline, with the A/B
partition layout provisioned from day one. **Five partitions** (revised
2026-06-13): `/boot` (shared FAT), system A (active), system B (recovery stub),
a **shared read-only `models` partition** mounted at `/opt/arlowe/models` in both
slots, and `/var/lib/arlowe` (owner-state, ext4, noatime). Ships a boot-time A/B
selector defaulting to A, a `dev-deploy.sh` for fast iteration without reflashing,
and builds that are reproducible-enough for CI. The shared models partition is
the grow-to-fill partition (maximizes model headroom); 16 GB is the viable
minimum, 32 GB recommended for larger models.

OS-OTA delivery (actually shipping new system slots) is **out of scope** — it
defers to Phase 9 (app-only OTA) and v2+ for OS OTA. Phase 6 lays the A/B
groundwork; it does not exercise A/B for real updates.

</domain>

<decisions>
## Implementation Decisions

### A/B switch mechanism
- **Pi-native `tryboot`**, not U-Boot and not a custom initramfs. Firmware reads
  `config.txt` for slot A or `tryboot.txt` for slot B. Chosen because the
  single-shared-`/boot` layout (SC2) rules out the two-FAT-boot-partition style,
  and tryboot needs no custom initramfs while giving one-shot + fallback
  semantics for free. Most future-proof for Phase 9 OTA.
- **Single shared `/boot` FAT** holds firmware + both slots' kernels. Slots are
  distinguished by rootfs only (which `root=` the active config points at).
- **System A and B are each a full rootfs** (complete OS + runtime; `/opt/arlowe`
  rides inside the active root). This matches the "A/B from day one" intent so
  Phase 9 OS-OTA is not a re-architecture. In v1 only slot A is populated.
- A and B partitions **must be equal size** — a true slot swap later requires it.

### A/B flip + fallback
- Manual flip via an **on-device `arlowe-ab` CLI** that writes the persistent
  default flag, then reboots. This establishes the switch pattern Phase 9 OTA
  reuses. (The flip is what SC3's manual A→B test exercises.)
- **Hard-default to slot A in v1.** Boot-count / auto-fallback logic is
  **deferred to Phase 9** — B is empty in v1, so real fallback has nothing
  useful to fall back to. tryboot's one-shot path stays available but no
  boot-counting is built now.

### Slot B recovery experience (v1)
- B holds a **minimal bootable recovery stub** (kernel + tiny initramfs/userland),
  not a blank ext4. Makes SC3's "boots to a recovery prompt" literally true
  instead of a kernel panic on no root.
- Recovery state surfaces on the **Whisplay (distinct recovery face/message) +
  serial console/journal**. No dashboard — the runtime isn't up, and the v1
  audience is the developer/founder, not paired owners.
- Recovery action: the stub **displays the state and resets the persistent
  default back to A**, so a plain reboot self-recovers. No reflash tooling and
  no OTA in recovery — those are later phases.

### Partition sizing + growth (REVISED 2026-06-13 — single shared model store)
- **Models (LLM/Axera, Whisper, Piper) live ONCE on a shared read-only `models`
  partition**, mounted at `/opt/arlowe/models` in both slots. This reverses the
  earlier "baked into each rootfs" decision. Rationale: one copy maximizes space
  for larger models, and it makes the 16 GB target achievable again. Accepted
  tradeoff: a future OS slot (v2 OS-OTA) shares the same models — a new OS
  needing different model formats can't swap them atomically. No v1 cost (Phase 9
  app-OTA touches `runtime/` only, never models; model-OTA is v2).
- **System A and B are still full rootfs per slot** (OS + runtime), just WITHOUT
  the bulky models — slots shrink to ~2-3 GB, preserving slot independence for
  everything except the shared model store.
- **The `models` partition is the grow-to-fill partition** (was owner-state).
  It consumes remaining card space on first boot, maximizing headroom for larger
  models via future model-OTA. `/var/lib/arlowe` owner-state becomes a FIXED
  modest partition (~2-4 GB; PART-05 needs ~1 GB) — it must NOT hold models
  because factory reset (PAIR-07) wipes it and it is owner-writable.
- **Models partition is read-only + root-owned in v1** (no model-OTA yet); a v2
  model-OTA agent can remount rw.
- **Measure-then-set sizing:** the planner builds the slot rootfs (now model-free),
  reads its real size, and sets fixed partition numbers from data; the models
  partition takes the remainder. Budget documented at that point.
- **16 GB viable, 32 GB recommended:** with a single ~6 GB model set, fixed
  overhead (~5.5 GB: boot + slot A + recovery B + owner-state) leaves ~9 GB for
  models on a 16 GB card — fits. 32 GB gives ~25 GB model headroom. The earlier
  "32 GB floor mandate" is downgraded to a recommendation; IMAGE-04's ≤16 GB
  target is achievable again.

### Build environment + reproducibility
- **Supported build host: arm64 Linux.** Primary = a GitHub arm64 CI runner;
  fallback = arlowe-1 (Pi 5) for local builds. `build-image.sh` targets both
  native-arm64 Linux hosts. **The Mac is not a supported builder** — pi-gen
  needs loop devices + privileged mounts that Docker Desktop on macOS can't do.
- **Reproducibility: best-effort + documented exceptions** (SC5's "inputs pi-gen
  permits"). Pin a Debian snapshot, set `SOURCE_DATE_EPOCH`, strip obvious
  nondeterminism, and document the residual exceptions. **No hash-equality CI
  gate in v1** — pi-gen nondeterminism makes a strict gate a time sink now.
- **CI cadence:** full image build runs on **release tags + `workflow_dispatch`**,
  not every PR. PRs run cheap lint/shellcheck on the build scripts only, to keep
  PR feedback fast.

### dev-deploy
- `dev-deploy.sh` **rsyncs `runtime/` over SSH to a target (default arlowe-1),
  then restarts only the affected `arlowe-*` units.** Fast inner loop without
  reflashing.

### Claude's Discretion
- Exact `arlowe-ab` CLI surface (subcommands, flag names).
- Recovery-stub Whisplay face/message wording and exact build mechanism.
- Concrete partition byte sizes (driven by measurement).
- Debian snapshot pin date and the exact reproducibility exception list.
- arm64 CI runner choice (GitHub-hosted larger runner vs alternative) and the
  shellcheck/lint job shape.

</decisions>

<specifics>
## Specific Ideas

- The `arlowe-ab` CLI should set up the same switch primitive Phase 9 OTA will
  call — treat it as the seam, not a throwaway test helper.
- Recovery on slot B should prove the hardware is alive (Whisplay lights up with
  a recognizable recovery face) rather than going dark — the failure should look
  intentional, not bricked.

</specifics>

<deferred>
## Deferred Ideas

- Boot-count / automatic A↔B rollback on failed boots — Phase 9 (needs a real
  OTA payload to fall back from).
- Actually populating and shipping slot B / real OS-OTA delivery — v2+ (OS OTA
  is explicitly out of v1 scope).
- Re-flash / repair tooling inside recovery mode — later phase.
- Strict bit-for-bit reproducibility hash gate in CI — revisit post-v1 if it
  earns its keep.

</deferred>

---

*Phase: 06-image-build-with-a-b-partitions*
*Context gathered: 2026-06-13*
