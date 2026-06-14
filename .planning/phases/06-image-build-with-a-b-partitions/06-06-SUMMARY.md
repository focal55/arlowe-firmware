---
phase: 06-image-build-with-a-b-partitions
plan: 06-06
type: summary
status: complete-pending-hardware-checkpoint
---

## What shipped

Task 1: CI + shellcheck
- `.github/workflows/build-image.yml` — arm64 image build on `push: tags: ['v*']` and `workflow_dispatch` only. Uses `ubuntu-24.04-arm`, `usimd/pi-gen-action` with `use-qcow2: true`, models + axcl deb caching, artifact upload (14-day retention). Does NOT trigger on PRs.
- `.github/workflows/pr-checks.yml` — shellcheck job added; runs shellcheck over `scripts/**/*.sh`, `scripts/lib/*.sh`, `pi-gen/stage-arlowe/**/*.sh`, `units/install-units.sh`, `runtime/cli/arlowe-ab`, `runtime/recovery/*.sh`. Existing jobs preserved.
- Pre-existing shellcheck issues in existing scripts resolved (SC2086, SC2088 remote tildes, SC2053 intentional glob, SC2059 color vars, SC2295, SC2329 trap-invoked function, SC2013, SC2012, SC2034 unused vars).
- `docs/operations/phase-6-repro-exceptions.md` — best-effort reproducibility posture; pinned inputs documented; residual exception list (ext4 internals, dpkg ordering, first-boot-regenerated material); no hash gate in v1; documented prerequisites for introducing a hash gate in a later phase.

Task 2: flash + deploy + runbook
- `scripts/flash-sd.sh` — writes a `.img` to a confirmed SD card. Safety: refuses system disk on Linux (sysfs removable check) and macOS (root disk detection). Confirmation prompt or `--yes`. Uses `bmaptool` if available (fast sparse write), falls back to `dd`. Prints flash time on completion. Runs on macOS and Linux. shellcheck-clean.
- `scripts/dev-deploy.sh` — rsyncs `runtime/` to a target Pi over SSH and restarts affected `arlowe-*` units. Mirrors `dev-pull-from-pi.sh` SSH/target conventions. `--dry-run`, `--target`, `--units` flags. Restart order: whisper-stt → qwen-api → qwen-tokenizer → arlowe-face → arlowe-dashboard → arlowe-voice. Missing units skipped with warning. shellcheck-clean.
- `docs/operations/phase-6-build-flash-deploy.md` — operator runbook: build (arm64 requirement, env vars, Docker fallback), flash (safety, bmaptool vs dd, flash-time TODO), dev-deploy (when to use, flags, restart order), hardware checkpoint cross-reference.

Task 3: hardware checkpoint (deferred)
- Deferred per Phase 1/3/4/5 precedent. Runbook in `docs/operations/phase-6-build-flash-deploy.md` §Hardware checkpoint. Covers SC1–SC4 (boot, partitions, A/B flip, dev-deploy) and absorbs the carried-over Phase 4 SC4 and Phase 5 on-Pi SC1–SC4.

## Coverage

- IMAGE-03 (reproducibility posture): `docs/operations/phase-6-repro-exceptions.md`
- IMAGE-05 (flash): `scripts/flash-sd.sh`
- IMAGE-06 (dev-deploy): `scripts/dev-deploy.sh`
- SC1/SC4 on-Pi run: deferred to hardware checkpoint

## Pending (hardware checkpoint)

- Flash time measurement (fill TODO in `docs/operations/phase-6-build-flash-deploy.md` and `docs/operations/phase-6-partitions.md`)
- Measured partition sizes after first real build
- SC1–SC4 results recorded in runbook
