# Phase 6: Image build with A/B partitions - Research

**Researched:** 2026-06-13
**Domain:** pi-gen image build, Raspberry Pi 5 tryboot/autoboot.txt A/B, arm64 CI
**Confidence:** HIGH on sizing + build host; HIGH on the tryboot mechanism (with one design correction the planner must absorb); MEDIUM on recovery-stub mechanics (Claude's-discretion build detail).

## Summary

Two findings gate the whole phase, and both contradict the ROADMAP/REQUIREMENTS text. The planner must reconcile them before writing tasks.

1. **16 GB is dead. Declare 32 GB the minimum.** Measured model artifacts make a single full rootfs slot ~10 GB (Qwen 7B) or ~6 GB (Qwen 1.5B) *before* headroom. Two equal-sized slots (required by the locked decision) + `/boot` + owner-state land at **~26.5 GB (7B)** or **~16.6 GB (1.5B)** — both exceed a 16 GB card's ~14.8 GB usable space. IMAGE-04's "≤16 GB target" and PART-05 are physically unsatisfiable under the locked "models baked into each rootfs" + "equal-sized A/B" decisions. Recommend the planner amend IMAGE-04/PART-05 to a 32 GB floor.

2. **The locked tryboot design ("single shared /boot, slots distinguished by `root=` only") is not how Pi firmware A/B natively works, but it is achievable with a specific config.** Pi 5 `autoboot.txt` natively switches *boot partitions*, not `root=`. To get the locked single-`/boot` behavior you set `tryboot_a_b=1` and use `config.txt` (slot A) vs `tryboot.txt` (slot B) *inside the one FAT partition*, each pointing `root=` at a different rootfs. The persistent default is flipped by editing/swapping those files (or an `autoboot.txt` partition entry). This is real and correct on Pi 5 — but PART-02/SC3's "U-Boot env or `/boot/active.txt`" wording is wrong for this design; the selector is firmware-native config files, not a custom flag file an initramfs reads.

**Primary recommendation:** Build with `pi-gen` (arm64 branch, Bookworm, Lite) via the `pi-gen-action` on a GitHub-hosted `ubuntu-24.04-arm` runner; emit ONE rootfs, then a post-process EXPORT stage repartitions to 4 partitions, clones rootfs into slot A, writes the recovery stub into slot B, and lays down the tryboot config files. Reuse the existing `install-arlowe-*.sh` provisioning scripts verbatim inside a custom chroot stage. Set the card minimum to 32 GB.

---

## GATE 1: 16 GB vs 32 GB sizing verdict (HIGHEST PRIORITY)

### Measured model sizes (HIGH confidence — HuggingFace API, 2026-06-13)

| Artifact | Disk size | Source |
|----------|-----------|--------|
| Qwen2.5-7B-Instruct GPTQ-Int4 (AX650 layout) | **5.51 GB** | `AXERA-TECH/Qwen2.5-7B-Instruct-GPTQ-Int4` (28 layer `.axmodel` @ 136 MB each + 1.09 GB embed + 594 MB post). The `-AX650` variant repo is gated/auth-walled; the base GPTQ-Int4 repo has identical layer structure and is the right proxy. |
| Qwen2.5-1.5B-Instruct GPTQ-Int4 AX650 | **1.53 GB** | `AXERA-TECH/Qwen2.5-1.5B-Instruct-GPTQ-Int4` (28 layers @ 28 MB + 467 MB embed + 254 MB post) |
| Whisper (faster-whisper small.en) | **0.49 GB** | `Systran/faster-whisper-small.en` (base.en=0.15 GB, medium=1.53 GB — actual model TBD by planner) |
| Piper en_US-lessac-medium | **0.07 GB** | `rhasspy/piper-voices` |
| Runtime tree (`runtime/`) | **0.46 GB** | `du -sh runtime` measured locally (includes dashboard `node_modules` + `.next` — may shrink after a production prune) |

### Per-slot footprint (estimate — verify with measure-then-set during the build)

Non-model base per slot: Pi OS Lite arm64 (~1.6 GB) + axcl installed footprint (~0.3 GB) + ALSA/NetworkManager/Python (~0.4 GB) + Python/ML deps (ctranslate2, onnxruntime, faster-whisper, piper, Node for dashboard ~1.2 GB) + runtime tree (0.46 GB) ≈ **~4 GB**.

| Config | Slot content (base + models) | +25% headroom = partition size | A+B+boot(0.5)+owner(1.0) | 16 GB card (~14.8 GB usable)? |
|--------|------------------------------|-------------------------------|--------------------------|-------------------------------|
| Qwen **7B** | ~10.0 GB | **~12.5 GB each** | **~26.5 GB** | NO → 32 GB |
| Qwen **1.5B** | ~6.0 GB | **~7.6 GB each** | **~16.6 GB** | NO → 32 GB |

### Verdict

**Declare 32 GB the real minimum.** Both model choices exceed 16 GB once the locked "equal-sized A/B slots, each a full self-contained rootfs with models baked in" rule is honored. 16 GB is reachable *only* by violating the equal-size rule (sizing B for just the ~300 MB recovery stub) — which CONTEXT explicitly forbids ("A and B must be equal size — a true slot swap later requires it").

**Recommended concrete sizing (32 GB card, Qwen 7B default):**
- `/boot` FAT32: **512 MB** (firmware + both slots' kernels + tryboot configs)
- system A (ext4): **13 GB** (12.5 GB slot + rounding)
- system B (ext4): **13 GB** (equal to A; holds recovery stub in v1, grows-into a full slot in Phase 9)
- `/var/lib/arlowe` (ext4, noatime): **remaining space**, grows-to-fill on first boot (~3–5 GB on a 32 GB card, more on 64 GB)
- These are MEASURE-THEN-SET starting points. The build must `du -sh` the assembled rootfs and set A/B from the real number + 25%.

**Gotcha if ignored:** If the planner trusts IMAGE-04 and targets 16 GB, the build either won't fit or will silently drop the second slot / shrink headroom below what a future OTA swap needs. Surface the 32 GB floor as a requirement amendment, not a footnote.

**Open lever for the planner:** A 7B-only image needs 32 GB; a 1.5B-only image *also* needs 32 GB (16.6 > 14.8). There is no "16 GB if we ship the small model" escape. The only way back to 16 GB is abandoning baked-in-each-slot models (shared models partition) — which contradicts the locked self-contained-slot decision and the Phase 9 OTA-swap-as-a-unit rationale. Do not reopen that; just set 32 GB.

---

## GATE 2: tryboot / autoboot.txt on Pi 5 — validation of the locked design

### How Pi 5 firmware A/B actually works (HIGH confidence — raspberrypi/documentation autoboot.adoc)

The Pi bootloader reads `/boot/firmware/autoboot.txt` (the EARLY config, before `config.txt`). Two A/B styles exist:

**Style 1 — partition-level (the firmware default):** `autoboot.txt` has `[all] boot_partition=N` and `[tryboot] boot_partition=M`. Normal boot uses partition N; `reboot "0 tryboot"` does a ONE-SHOT boot from partition M. Each slot is its OWN FAT boot partition with its own `config.txt`/kernel. **This is the two-FAT-boot-partition style the locked decision explicitly rejected** (SC2 wants a single shared `/boot`).

**Style 2 — file-level within ONE boot partition (the locked design):** Set `tryboot_a_b=1` in `config.txt`. Then when the tryboot flag is set, firmware loads **`tryboot.txt`** instead of **`config.txt`** *from the same FAT partition*. Slot A's `config.txt` sets `cmdline`/`root=` at partition for rootfs A; slot B's `tryboot.txt` sets `root=` for rootfs B. One shared `/boot`, both kernels present, slots distinguished by `root=` — exactly decision #1.

### Validation result

**Decision #1 is technically real on Pi 5 via Style 2 (`tryboot_a_b=1` + `config.txt`/`tryboot.txt`).** No U-Boot, no custom initramfs needed.

**The gotcha that bites (surface loudly):** The persistent-default and one-shot semantics differ from what PART-02/SC3 imply.

- `reboot "0 tryboot"` is a **one-shot** — it boots `tryboot.txt` ONCE; any reboot/power-cycle reverts to `config.txt` (slot A). This is the free fallback CONTEXT wants for recovery, BUT it means a *persistent* flip to B can't use the one-shot path.
- To make a **persistent** default-B flip, `arlowe-ab` must actually **swap the file contents** (make `config.txt` carry slot B's `root=`) or restructure so the persistent default lives in `autoboot.txt`. The cleanest pattern: keep `config.txt` as the persistent-default selector (edit/swap its `root=` or `os_prefix`), and reserve `tryboot.txt` + `reboot "0 tryboot"` for the one-shot trial path Phase 9 OTA will use.
- For v1 (hard-default A, manual flip to B for the recovery test), the simplest correct `arlowe-ab` is: **write the persistent default by editing `config.txt`'s `root=` (or `os_prefix=`) to point at the target slot, then `reboot`.** The recovery stub in B resets it back by rewriting `config.txt`'s `root=` to slot A.

**`os_prefix` alternative (worth the planner's attention):** Pi firmware supports `os_prefix=` to load kernel/cmdline/dtb from a subdirectory of the SAME boot partition. Some single-`/boot` A/B designs key the slot on `os_prefix` rather than juggling `root=`. The planner should pick ONE primitive (root= swap vs os_prefix swap vs config/tryboot file swap) and make `arlowe-ab` own it as the seam Phase 9 reuses. Recommend `root=` swap in `cmdline.txt`/`config.txt` as the least-magic option, with `tryboot_a_b=1` reserved for the future one-shot OTA trial.

**Concrete v1 boot layout:**
```
/boot/firmware/
  config.txt        # persistent default; cmdline points root= at slot A (PARTUUID/partition of A)
  tryboot.txt       # one-shot trial slot (Phase 9 uses; in v1 can mirror B/recovery)
  cmdline.txt        # or inline cmdline= in config.txt
  kernel_2712.img    # Pi 5 kernel (shared)
  *.dtb, overlays/   # shared firmware
tryboot_a_b=1 set in config.txt
```

**Pi-5-specific failure note (MEDIUM):** A corrupted/incompatible kernel on Pi 5 can freeze the bootloader rather than auto-fallback; a power cycle recovers. Relevant to PART-06 recovery framing — document "if it freezes, power-cycle."

---

## pi-gen mechanics & customization (HIGH confidence — RPi-Distro/pi-gen README)

### Stage model
- **stage0** debootstrap minimal rootfs; **stage1** makes it bootable (fstab, bootloader, raspi-config); **stage2** = Pi OS **Lite** (the build target here — stop at stage2). stage3-5 are desktop/full; SKIP them.
- Each stage has numbered sub-stages `NN-name/` containing: `00-run.sh` (host-side), `00-run-chroot.sh` (runs INSIDE the rootfs chroot), `00-packages` (apt list), `00-packages-nr` (`--no-install-recommends`), `files/` (copied in), `00-debconf`.
- `EXPORT_IMAGE` marker file in a stage triggers .img emission for that stage. `SKIP` skips a stage; `SKIP_IMAGES` runs the build but emits no image (dev iteration).
- Custom stages: add to `STAGE_LIST` env, e.g. `STAGE_LIST="stage0 stage1 stage2 stage-arlowe stage-export"`.
- `IMG_NAME`, `RELEASE=bookworm`, arm64 = use the **`arm64` branch** of pi-gen (not master).
- `on_chroot` helper runs commands inside the rootfs; `00-run-chroot.sh` is the standard hook.

### How to inject arlowe content (concrete task shape)
Create `stage-arlowe/` with:
1. `00-packages` — apt deps: `python3 python3-venv python3-pip alsa-utils network-manager` + axcl deb prerequisites + node (for dashboard). axcl `.deb` is `dpkg -i`'d from a `files/` copy (see verify-third-party reuse below).
2. `01-runtime/00-run.sh` — copy `runtime/`, `config/`, `units/`, `provision/`, `third_party/whisplay-driver/`, `scripts/provision/` into the chroot's `files/` staging, then `01-runtime/00-run-chroot.sh` runs the existing `install-arlowe-*.sh` scripts **in order** (see provisioning order below).
3. `02-models/00-run.sh` — stage the Qwen/Whisper/Piper artifacts into `/opt/arlowe/models/` (fetched/verified out-of-band, not committed — same "Strategy C" pattern as axcl).
4. `03-firstboot/files/` — the armed (stubbed) pairing first-boot hook + the tryboot config files.

### Privileged / loop-device needs
- `build.sh` (native) needs `binfmt_misc` + loop devices + root. `build-docker.sh` wraps it in a `--privileged` container.
- **This is why the Mac is out:** Docker Desktop on macOS can't expose host loop devices to the container. Confirmed by repeated pi-gen issues (#257, #482, #652).
- Pi 5 / arm64 builds work cleanly on the arm64 branch with Bookworm.

---

## A/B partition layout in pi-gen (HIGH confidence on approach, MEDIUM on exact tooling)

pi-gen natively emits a **2-partition** image (boot FAT + single rootfs ext4). The 4-partition A/B layout is NOT a pi-gen built-in; you produce it in a **custom EXPORT post-process stage**:

**Recommended approach — build-once-then-repartition:**
1. Let pi-gen build ONE rootfs (the slot-A content) through stage2 + stage-arlowe.
2. In a final `stage-export` (or a `scripts/build-image.sh` post-step), create a fresh blank `.img` of the target size with `parted`/`sgdisk`: 4 partitions (FAT32 boot, ext4 A, ext4 B, ext4 owner-state).
3. `losetup -P` the blank image; `mkfs.vfat` boot, `mkfs.ext4` A/B/owner.
4. `rsync -aHAX` the pi-gen rootfs into slot A; copy boot files into the FAT; write the recovery stub into slot B; lay down `config.txt`/`tryboot.txt`/`autoboot.txt`.
5. Set `/etc/fstab` (in BOTH slots) to mount `/boot/firmware` and `/var/lib/arlowe` (by PARTUUID, `noatime` on owner-state). Owner-state grows-to-fill via a first-boot `resize2fs` (the same trick Pi OS uses for its rootfs — adapt `raspi-config`'s `init_resize`/`resize2fs` logic but target partition 4, not the rootfs).

**Gotcha:** Owner-state grow-to-fill must run on FIRST boot and is idempotent (only grows once). Pi OS's stock `init_resize.sh` grows the *rootfs*; you need a variant pointed at the owner-state partition. Don't grow A or B (they're fixed-size for swap symmetry).

**Alternative considered:** Post-processing the pi-gen-emitted `.img` with `parted` resize + add-partition in place. More fragile (resizing/moving partitions in an existing image) than build-blank-then-rsync. Recommend build-blank-then-rsync.

---

## Recovery stub for slot B (MEDIUM — design detail, Claude's discretion)

**Cheapest correct option:** slot B = a **stripped minimal ext4 rootfs** (not a full second build, not a bare initramfs). Contents: a Pi-5-compatible kernel reference (shared from `/boot`), busybox/minimal userland, and a single oneshot systemd service (or `/sbin/init` script) that:
1. Lights the Whisplay with a recognizable "recovery face" (reuse `runtime/face` minimal path or a static framebuffer image — the WhisPlay driver is vendored at `/opt/arlowe/third_party/whisplay-driver/`, but in B you want the smallest possible dependency).
2. Prints recovery state to serial console + journal.
3. **Resets the persistent default to A** — concretely: mount `/boot/firmware`, rewrite `config.txt`'s `root=`/`cmdline` back to slot A's PARTUUID, sync.
4. Optionally `reboot` after a delay, so a stuck-in-B device self-heals.

**Why not a pure initramfs:** an initramfs that just resets-and-reboots is smaller, but you lose the "prove the hardware is alive on Whisplay" requirement (CONTEXT specials). A tiny rootfs with one face-render service satisfies "looks intentional, not bricked." Keep it under ~300 MB.

**Open decision for planner:** exact stub build mechanism (debootstrap a tiny rootfs vs strip a copy of A vs buildroot). Recommend "debootstrap minimal + busybox + one service" or "copy A, then aggressively prune" — both are testable. Claude's discretion per CONTEXT.

---

## Reproducibility levers in pi-gen (HIGH on what's controllable, honest on limits)

CONTEXT already scoped this to best-effort + documented exceptions, no hash gate. Concretely controllable:
- **Debian snapshot pin:** point apt at `snapshot.debian.org` for a fixed date so package versions are frozen. pi-gen's `APT_PROXY`/sources can be templated. (MEDIUM — pi-gen doesn't pin snapshot by default; you template `etc/apt/sources.list`.)
- **`SOURCE_DATE_EPOCH`:** set it; pi-gen and dpkg honor it for some timestamps.
- **apt pinning** for the specific deb versions (axcl is already SHA-pinned).
- **Strip obvious nondeterminism:** clear `/var/log`, machine-id, apt caches, SSH host keys (regenerated first boot anyway), Python `__pycache__` in the chroot.

**Cannot make reproducible (document-as-exception list):**
- ext4 filesystem internals (inode allocation order, timestamps) → image hash differs even with identical file content. This alone defeats bit-for-bit hashing.
- `apt`/`dpkg` install ordering side effects, generated caches.
- Any first-boot-regenerated material that's seeded at build (host keys, machine-id).

**Recommendation:** Do NOT promise image-hash equality. Promise *input* reproducibility (pinned snapshot + pinned debs + pinned submodule + SOURCE_DATE_EPOCH) and a documented exception list. This matches SC5's "inputs pi-gen permits" hedge. No CI hash gate in v1.

---

## GitHub arm64 runner feasibility (HIGH confidence — GitHub changelog + pi-gen-action docs)

- **GitHub-hosted arm64 Linux runners are GA.** Labels: `ubuntu-24.04-arm`, `ubuntu-22.04-arm`. Free in public repos; **as of 2026-01-29 also available in PRIVATE repos** (free-tier eligible). This repo is private — so hosted arm64 is usable here. Standard runner = 4 vCPU.
- **pi-gen-in-Actions is a solved pattern via `pi-gen-action`** (GitHub Marketplace, `usimd/pi-gen-action`). It runs pi-gen inside a container on the runner and handles the privileged/loop-device setup that raw `losetup` needs. It supports `ubuntu-24.04-arm` runners explicitly ("ARM-based runners are especially attractive to cut down on build times"), exposes `stage-list`, `image-name`, `release` (bookworm), and defaults `pi-gen-version` to the `arm64` branch.
- **Privileged loop devices on hosted runners:** raw pi-gen on a bare hosted runner historically hits "failed to setup loop device" (pi-gen #652) — but `pi-gen-action`'s containerized wrapper is designed around exactly this and is the de facto way people build on Actions. The hosted runner kernel does expose loop devices to a privileged container.
- **Disk footprint:** a 32 GB target image + intermediate rootfs/work dirs can exceed the default ~14 GB free on hosted runners. Plan for `USE_QCOW2=1` (sparse work image — pi-gen-action exposes `use-qcow2`) and/or free up runner disk first. This is the single most likely CI failure mode. Flag it.

**Recommendation:** **Primary = GitHub-hosted `ubuntu-24.04-arm` + `pi-gen-action` with `use-qcow2`.** Fallback = a manual `build-docker.sh` run on **arlowe-1** (Pi 5, native arm64, real loop devices) documented in `docs/`. Self-hosted-runner-on-arlowe-1 is possible but adds maintenance; document the manual-build fallback first. The Mac stays explicitly unsupported.

**Open decision:** confirm the 32 GB qcow2 build fits the hosted runner's disk; if not, the manual arlowe-1 build becomes primary. The planner should make the CI image-build job `workflow_dispatch` + release-tag only (per CONTEXT cadence) so a slow/large build doesn't gate PRs; PRs run shellcheck only.

---

## Sanitization gate reuse (HIGH — read the script directly)

`scripts/sanitize/check.sh` already has the `--scan-dir DIR` flag built for exactly this (Phase 2 delivered it). It:
- Enumerates files via `find DIR -type f` (instead of `git ls-files`), so it works on a mounted rootfs with no git.
- Runs BOTH the banned-literal grep gate (`banlist.txt`) and the banned-unit-name gate (`unit-prefixes.txt`, matching `*.service`/`*.timer`/etc).
- **Ignores `.sanitize-allowlist` in scan-dir mode** (the script comments this — every file in the image is fair game).
- Requires `rg` (ripgrep) present in the build environment.

**Wiring:** After rootfs assembly, before finalizing the `.img`, mount/loop slot A at e.g. `/mnt/img` and run `scripts/sanitize/check.sh --scan-dir /mnt/img`. Non-zero exit fails the build. This satisfies **SANIT-08** (no `openclaw-*`/`trace-*`/`workforce-metrics-snapshot.*` units in the image) against the actual image, not just the repo.

**Gotcha:** ripgrep must be installed on the build host/CI (the script `exit 2`s if `rg` missing). Add to build deps.

---

## Existing scripts to reuse vs create (HIGH — full inventory below)

### REUSE verbatim inside the chroot (do NOT duplicate)
Provisioning order matters — `install-arlowe-on-arlowe1-staging.sh` documents the exact sequence and dependencies. Run in the chroot in this order:

| # | Script | What it does | Prereq |
|---|--------|--------------|--------|
| 1 | `scripts/provision/install-arlowe-user.sh` | creates `arlowe` system user/group | — |
| 2 | `scripts/provision/install-arlowe-fs.sh` | `/opt/arlowe`, `/var/lib/arlowe`, `/etc/arlowe` layout | user exists; **must run AFTER `/var/lib/arlowe` partition mounted** (it says so in its header) |
| 3 | `scripts/provision/install-arlowe-config.sh` | ships `schema.yml`+`defaults.yml`+config loader to `/opt/arlowe/config` | fs done |
| 4 | `units/install-units.sh` | copies `*.service` to `/etc/systemd/system` (skips daemon-reload when systemd not PID1 — chroot-safe) | — |
| 5 | `scripts/provision/install-arlowe-cli.sh` | `/usr/local/sbin/arlowe-*` symlinks into `/opt/arlowe/runtime/cli` | fs done |
| 6 | `scripts/provision/install-arlowe-udev-polkit.sh` | udev + polkit rules | — |
| 7 | `scripts/provision/extract-axcl-udev-from-deb.sh` | pulls axcl udev rules out of the deb | axcl deb present |

**Critical reuse note:** these scripts hardcode the literal `arlowe` and resolve repo paths relative to their own location (`REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"`). To run them in the chroot, stage the repo tree (or the needed subdirs) at a known path inside the rootfs so `REPO_ROOT` resolves. `install-arlowe-config.sh` and `install-arlowe-cli.sh` both read from `${REPO_ROOT}/config`, `${REPO_ROOT}/runtime` — those must exist in-chroot at build time.

**The staging script (`install-arlowe-on-arlowe1-staging.sh`) is the reference composition** — it shows every script's ordering, prereqs, and which ones have repo-relative path lookups (config/cli/udev resolve relative to their location; user/fs/cli have no lookups). The planner should mirror its sequence, minus the `-staging` sed-transforms (the image uses the literal `arlowe`).

### REUSE for dependency gating
- `scripts/verify-third-party.sh` — run FIRST in `build-image.sh`. Verifies axcl deb SHA-256 (locates via `$AXCL_DEB` / `third_party/axcl/` / `/var/cache/arlowe-build/`) and the ax-llm submodule pin. Exits non-zero if deps missing — fail the build early.
- `third_party/axcl/manifest.yml` — axcl version/SHA source of truth (`V3.10.2`, sha pinned). deb NEVER committed (Strategy C) — CI must supply it via `$AXCL_DEB` secret/cache.

### CREATE new (Phase 6 deliverables)
| Script | Purpose | Requirement |
|--------|---------|-------------|
| `scripts/build-image.sh` | full pipeline: verify-third-party → pi-gen (stage2+stage-arlowe) → repartition → clone A / write B stub / lay tryboot config → sanitize scan → emit `.img` | IMAGE-01, IMAGE-05 |
| `scripts/flash-sd.sh` | write `.img` to connected SD (`dd`/`bmaptool`), confirm target device | IMAGE-05 |
| `scripts/dev-deploy.sh` | rsync `runtime/` over SSH to target (default arlowe-1), restart affected `arlowe-*` units | IMAGE-06 |
| `arlowe-ab` CLI | write persistent default slot + reboot (the Phase-9 OTA seam) | PART-02 |
| pi-gen `stage-arlowe/` tree | packages + chroot provisioning + models + first-boot stub | IMAGE-02 |
| owner-state grow-to-fill first-boot service | resize2fs partition 4 once | PART-04 |
| recovery stub (slot B) build | minimal bootable recovery rootfs | PART-03, PART-06 |
| `docs/operations/phase-6-*.md` | partition sizes, flash time, recovery SD procedure, repro exceptions | IMAGE-04, PART-05, PART-06, IMAGE-03 |

**Note `scripts/dev-pull-from-pi.sh` already exists** — it's the inverse (pull from Pi). `dev-deploy.sh` is its push counterpart; mirror its SSH/target conventions.

### F2 — vendor WhisPlay driver (in scope this phase)
`.planning/todos/pending/F2-vendor-whisplay-driver.md`: copy `WhisPlay.py` + Apache-2.0 LICENSE + attribution into `third_party/whisplay-driver/` (vendor-at-build, "Strategy A", NOT committed), image copies it to `/opt/arlowe/third_party/whisplay-driver/`. `face.py` default `ARLOWE_WHISPLAY_DRIVER_PATH` already points there. Also runs the WM8960 audio-HAT install (`install_wm8960_drive.sh` — kernel modules + config.txt SPI/I2S/I2C enable) as an image-build step (PROVENANCE.md §4). Confirm Waveshare WM8960 redistribution rights before bundling the HAT zip (flagged open in PROVENANCE.md).

---

## Recommended plan breakdown (natural boundaries / waves)

The phase has a clear dependency spine. Suggested plan/wave split:

**Wave 1 (parallel-safe, no image yet):**
- **P1 — pi-gen stage scaffold + chroot provisioning.** `stage-arlowe/` tree, package lists, stage the repo into the rootfs, wire the existing `install-arlowe-*.sh` in order, vendor WhisPlay (F2), `dpkg -i` axcl. Output: a single bootable arlowe rootfs (`SKIP_IMAGES` for fast iteration). Reuses Wave-1 nothing; depends only on the existing scripts.
- **P2 — build-image.sh + verify-third-party + sanitize wiring.** The orchestration script that calls verify-third-party first and runs `check.sh --scan-dir` on the assembled rootfs. Can be drafted against P1's output.

**Wave 2 (depends on a working rootfs from P1):**
- **P3 — 4-partition layout + A/B clone + owner-state grow.** Repartition, rsync rootfs→A, mkfs owner-state noatime, first-boot resize2fs service. Produces the real 4-partition `.img`.
- **P4 — tryboot config + `arlowe-ab` CLI.** `config.txt`/`tryboot.txt`/`autoboot.txt` with `tryboot_a_b=1`, persistent-default-A, `arlowe-ab` flip CLI. Depends on partition PARTUUIDs from P3.
- **P5 — recovery stub for slot B.** Minimal recovery rootfs + Whisplay recovery face + reset-default-to-A service. Depends on P3's partition layout + P4's flip primitive.

**Wave 3 (depends on a buildable image):**
- **P6 — CI workflow (arm64 image build) + flash-sd.sh + dev-deploy.sh + docs.** `pi-gen-action` on `ubuntu-24.04-arm`, `workflow_dispatch`+release-tag cadence, PR shellcheck job, flash/deploy scripts, all docs (sizes, flash time, recovery SD, repro exceptions).

This is a suggested shape, not prescriptive — the planner owns final wave/task decomposition. Note P4 and P5 are tightly coupled (the flip primitive and the recovery reset are two halves of the same mechanism) and could merge.

---

## Open decisions the planner must resolve

1. **32 GB amendment.** Get sign-off to change IMAGE-04 (≤16 GB) and PART-05 to a 32 GB floor. This is a requirements change, not just a plan note. (Sizing data above is decisive; recommend amend.)
2. **Which Whisper model actually ships?** base.en (0.15 GB), small.en (0.49 GB), or medium (1.53 GB)? Affects slot size. Not found in repo config — only `whisper-stt.service` references faster-whisper generically. The planner/build must pin this.
3. **A/B selector primitive:** `root=` swap in cmdline vs `os_prefix=` swap vs `config.txt`/`tryboot.txt` swap. Recommend `root=` swap + reserve `tryboot_a_b=1`/`tryboot.txt` for the Phase-9 one-shot OTA trial. Planner to lock one.
4. **Recovery stub build mechanism** (debootstrap-minimal vs strip-a-copy-of-A). Claude's discretion per CONTEXT; either is testable.
5. **Models distribution strategy** (where do the model artifacts come from at build time?). axcl uses Strategy C (user-supplies, SHA-pinned). Models likely need the same: a `third_party/models/manifest.yml` with SHA pins + a fetch step, NOT committed. The planner should mirror the axcl/verify-third-party pattern for models. **This is currently unspecified in the repo** — no model manifest exists yet.
6. **CI disk headroom for a 32 GB qcow2 build on a hosted arm64 runner** — verify it fits; if not, manual arlowe-1 build becomes primary.
7. **Waveshare WM8960 HAT redistribution rights** (PROVENANCE.md open question) before bundling the audio-HAT driver in the image.

## Requirement / SC reconciliation notes (for the planner to flag in ROADMAP/REQUIREMENTS)

| Text | Conflict with locked decision | Recommended resolution |
|------|-------------------------------|------------------------|
| **IMAGE-04** "Image size ≤ 16 GB target" | Two equal-sized model-laden slots need ~26.5 GB (7B) / ~16.6 GB (1.5B). Impossible at 16 GB. | Amend to **"≤ 32 GB; 32 GB card minimum."** Document measured sizes. |
| **PART-05** "system A and B equal-sized (image + 25% headroom); owner ~1 GB ... within 16 GB budget" | Same. | Amend budget to 32 GB; keep equal-size + 25% headroom + grow-to-fill owner-state. |
| **PART-02 / SC3** "selector reads a flag (U-Boot env or `/boot/active.txt`)" | Locked decision is Pi-native tryboot — NOT U-Boot, NOT a custom `active.txt` an initramfs reads. The selector is firmware-native `config.txt`/`tryboot.txt`/`cmdline` `root=`. | Reword PART-02/SC3: "Boot-time A/B selector is the Pi firmware tryboot mechanism (`config.txt`/`tryboot.txt` + `tryboot_a_b=1`); `arlowe-ab` writes the persistent default by editing the boot `root=`. No U-Boot, no `active.txt`." |
| **SC3** "system B ... boots to a recovery prompt in v1, since B is empty" | Locked decision: B is NOT empty — it's a minimal bootable recovery stub. | Reword: "B holds a minimal recovery rootfs that surfaces recovery state on Whisplay + serial and resets the default to A." (CONTEXT already supersedes; just align the SC text.) |
| **SC5 / IMAGE-03** "same inputs produce the same image hash" | ext4 nondeterminism defeats bit-for-bit hashing. | Keep CONTEXT's "best-effort + documented exceptions, no hash gate." Reframe as *input* reproducibility (pinned snapshot/debs/submodule + SOURCE_DATE_EPOCH). |

## Sources

### Primary (HIGH confidence)
- `RPi-Distro/pi-gen` README — stage system, build.sh/build-docker.sh, IMG_NAME/RELEASE/arm64, EXPORT_IMAGE/SKIP/SKIP_IMAGES, on_chroot.
- `raspberrypi/documentation` autoboot.adoc — `tryboot_a_b`, `autoboot.txt` `[all]`/`[tryboot]` `boot_partition`, `reboot "0 tryboot"` one-shot, persistent-default-via-file-swap.
- HuggingFace API (live, 2026-06-13) — measured model file sizes for Qwen2.5-7B/1.5B GPTQ-Int4, faster-whisper, piper-voices.
- GitHub Changelog (2025-01-16, 2025-08-07, 2026-01-29) — arm64 hosted runners GA, private-repo availability.
- `usimd/pi-gen-action` Marketplace docs — runs pi-gen on `ubuntu-24.04-arm`, handles privileged/loop, `stage-list`/`release`/`use-qcow2` inputs.
- Local repo (read directly): `scripts/sanitize/check.sh` (`--scan-dir`), `scripts/verify-third-party.sh`, all `scripts/provision/install-arlowe-*.sh`, `units/install-units.sh`, `install-arlowe-on-arlowe1-staging.sh` (composition reference), `config/defaults.yml`+`schema.yml` (model knob), `units/qwen-api.service`+`arlowe-voice.service` (model paths), `third_party/axcl/manifest.yml`+`INSTALL.md`, `third_party/whisplay-driver/PROVENANCE.md`, F2 todo, ROADMAP/REQUIREMENTS Phase 6.

### Secondary (MEDIUM confidence)
- pi-gen issues #257/#482/#652/#728 — loop-device/QCOW2 behavior on Actions/Docker.
- Canonical Ubuntu Pi A/B boot docs — corroborates partition-vs-file tryboot styles.
- Raspberry Pi forums (tryboot/autoboot threads) — Pi 5 freeze-on-corrupt-kernel fallback note.

### Tertiary (LOW — flagged for validation)
- Per-slot non-model footprint (~4 GB) is an ESTIMATE; the build's measure-then-set step must replace it with real `du` numbers before partition sizes are locked.
- The `-AX650` Qwen 7B repo is auth-gated; the 5.51 GB figure is from the structurally-identical base GPTQ-Int4 repo. Verify the exact AX650 deployment size when the model is fetched.

## Metadata

**Confidence breakdown:**
- 16/32 GB sizing verdict: HIGH (measured model sizes; conclusion holds even with generous estimate error since 1.5B already exceeds 16 GB by 1.8 GB).
- tryboot on Pi 5: HIGH on mechanism, with a design correction the planner must absorb (file-level vs partition-level, persistent-default semantics).
- Build host / arm64 CI: HIGH (hosted arm64 GA + private-repo + pi-gen-action confirmed); the qcow2-disk-headroom caveat is the one MEDIUM risk.
- Provisioning reuse: HIGH (scripts read directly; composition reference exists).
- Recovery stub: MEDIUM (design space, Claude's-discretion build mechanism).
- Reproducibility: HIGH on the exception list; no over-promise.

**Research date:** 2026-06-13
**Valid until:** ~2026-07-13 (model sizes/runner availability stable; pi-gen-action and HF repos may shift — re-verify model sizes at build time regardless).
