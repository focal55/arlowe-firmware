# Phase 6 build, flash, and deploy runbook

**Status:** Reference — measured values (flash time, partition sizes) will be
filled in after the first successful on-hardware run (Phase 6 hardware
checkpoint, see §Hardware checkpoint below).

---

## Overview

Three operations cover the Phase 6 image pipeline:

| Operation | Script | When to use |
|-----------|--------|-------------|
| Build | `scripts/build-image.sh` | Produce a new .img (arm64 Linux only) |
| Flash | `scripts/flash-sd.sh` | Write the .img to an SD card |
| Dev-deploy | `scripts/dev-deploy.sh` | Push `runtime/` to a running Pi; no reflash |

CI builds on tag or manual dispatch. Flash runs from any dev host (Mac or
Linux). Dev-deploy is the fast iteration path.

---

## Build

### Prerequisites

- **arm64 Linux host required.** The Mac cannot build — pi-gen uses loop
  devices and privileged mounts that Docker Desktop on macOS does not support.
  Use a GitHub arm64 CI runner (tag / workflow_dispatch) or a native arm64
  Linux machine. Docker (`build-docker.sh`) is the fallback if the native host
  is unavailable (see §Build fallback below).

- **Required packages** (Debian/Ubuntu):
  ```
  parted e2fsprogs cloud-guest-utils rsync ripgrep python3-yaml
  binfmt-support qemu-user-static dosfstools
  ```

- **Required env vars** (set before running):

  | Variable | Purpose | Default |
  |----------|---------|---------|
  | `AXCL_DEB` | Path to `axcl_host_aarch64_V3.10.2.deb` | required |
  | `ARLOWE_MODELS_DIR` | Directory holding downloaded model artifacts | searches `third_party/models/`, `/var/cache/arlowe-build/models/` |
  | `CARD_SIZE_GB` | Target card size (16 or 32) | 32 |
  | `OUTPUT_IMG` | Output image path | `build/arlowe.img` |

  See `third_party/axcl/INSTALL.md` and `third_party/models/INSTALL.md` for
  how to obtain and stage each dependency.

### Run the build

```bash
AXCL_DEB=/path/to/axcl_host_aarch64_V3.10.2.deb \
ARLOWE_MODELS_DIR=/path/to/models-cache \
CARD_SIZE_GB=32 \
bash scripts/build-image.sh
```

The build:
1. Verifies all pinned third-party deps (`verify-third-party.sh`).
2. Drives pi-gen to produce a model-free rootfs (stage-arlowe).
3. Measures rootfs and models tree with `du -sb`.
4. Assembles a 5-partition GPT image (boot FAT + slot A + slot B + owner-state
   + shared models).
5. Writes the boot config (ADR-0005 tryboot selector).
6. Writes the slot-B recovery stub.
7. Runs the sanitize gate (`check.sh --scan-dir`) against slot A before emitting.
8. Prints the final image size and partition table.

Output: `build/arlowe.img`.

### Build fallback

If the arm64 CI runner is unavailable (runner quota exhausted or GitHub
outage), build locally on a Pi 5 with Docker:

```bash
# On a Pi 5 running Raspberry Pi OS
sudo apt-get install -y docker.io
AXCL_DEB=/path/to/axcl_host_aarch64_V3.10.2.deb \
ARLOWE_MODELS_DIR=/path/to/models-cache \
bash pi-gen/build-docker.sh
# Then run the 5-partition assembly step:
bash scripts/build-image.sh
```

The native Pi build is slower than CI (~45–90 min) but produces an identical
image. See `pi-gen/README.md` for Docker build prerequisites.

### CI build (tag / workflow_dispatch)

The workflow `.github/workflows/build-image.yml` triggers on:
- `push: tags: ['v*']` — version release
- `workflow_dispatch` — manual trigger from the Actions tab

PRs do **not** trigger the image build. PR-level feedback comes from the
shellcheck job in `pr-checks.yml`.

The CI workflow:
- Uses `ubuntu-24.04-arm` (GitHub-hosted arm64 runner).
- Enables `use-qcow2: true` (via `usimd/pi-gen-action`) to avoid disk-space
  exhaustion on the hosted runner.
- Caches the models directory by `third_party/models/manifest.yml` hash.
- Uploads the final `.img` as an artifact (14-day retention).

---

## Flash

### Prerequisites

Flash works on **macOS or Linux**. The Mac can flash an `.img` downloaded from
CI even though it cannot build one.

Packages:
- `bmaptool` (optional, recommended — sparse write, 2–5× faster than `dd`)
- `dd` (always available as fallback)

### Run flash-sd.sh

```bash
# Linux
scripts/flash-sd.sh build/arlowe.img /dev/sdb
scripts/flash-sd.sh build/arlowe.img /dev/mmcblk0 --yes

# macOS
scripts/flash-sd.sh build/arlowe.img /dev/disk4 --yes
```

Safety checks applied before writing:
- Refuses to write to the system/boot disk.
- On Linux: verifies the target is flagged removable in sysfs.
- Requires explicit confirmation unless `--yes` is passed.
- On macOS: unmounts the disk via `diskutil` before writing; uses
  `/dev/rdisk<N>` for faster raw access.

Flash time is printed on completion. Record the measured value below.

### Measured flash time

TODO: record after the first successful hardware run (Phase 6 hardware
checkpoint).

Typical reference times:
- 32 GB image to SD with `dd`: ~10–20 minutes.
- 32 GB image to SD with `bmaptool`: ~2–5 minutes (sparse write, skips unwritten sectors).

---

## Dev-deploy

### When to use

Dev-deploy is the fast iteration loop for runtime changes. It rsyncs
`runtime/` to a running Pi and restarts the affected `arlowe-*` units over
SSH. Use it when you have a change to a Python file, CLI script, or systemd
unit in `runtime/` and do not need to reflash.

It does **not** update the OS image, installed packages, pi-gen stages, or
anything outside `runtime/`.

### Prerequisites

- SSH key auth to the target Pi.
- The target Pi must have `runtime/` deployed at `~/runtime/` (established by
  the initial flash).

### Run dev-deploy.sh

```bash
# Deploy to the default target (DEV_TARGET env var or arlowe-dev alias)
scripts/dev-deploy.sh

# Deploy to a specific host
scripts/dev-deploy.sh --target <pi-host>

# Restart only specific units
scripts/dev-deploy.sh --units arlowe-voice,arlowe-face

# Dry-run: show what would be rsynced and restarted without doing it
scripts/dev-deploy.sh --dry-run
```

Configuration via env vars:
- `DEV_TARGET`: default SSH host alias (overridden by `--target`).
- `REMOTE_USER`: SSH user (defaults to the local user).

### Unit restart order

The default restart order is:
1. `whisper-stt`
2. `qwen-api`
3. `qwen-tokenizer`
4. `arlowe-face`
5. `arlowe-dashboard`
6. `arlowe-voice` (restarted last — depends on stt and llm)

Units that are not running on the target Pi are skipped with a warning.

---

## Hardware checkpoint (deferred — owner present required)

On-hardware verification (SC1–SC4) requires a Pi 5 + AX accelerator + SD card
(16 GB viable, 32 GB recommended) and the owner present. This deferred
checkpoint absorbs the Phase 4 SC4 and Phase 5 on-Pi SC1–SC4 runs that were
also deferred.

Runbook: `docs/operations/phase-6-ab-recovery.md` §Hardware checkpoint.

After the hardware run, fill in:
- Flash time (above, in §Measured flash time).
- Measured partition sizes in `docs/operations/phase-6-partitions.md`.
- SC1–SC4 results in this file under a new §Hardware checkpoint results section.

---

## References

- Partition layout: `docs/operations/phase-6-partitions.md`
- A/B selector + recovery: `docs/operations/phase-6-ab-recovery.md`
- Reproducibility exceptions: `docs/operations/phase-6-repro-exceptions.md`
- ADR-0004: `docs/architecture/0004-shared-model-partition-sizing.md`
- ADR-0005: `docs/architecture/0005-ab-selector-tryboot-root-swap.md`
