---
phase: 06-image-build-with-a-b-partitions
plan: 03
status: complete
pr: pending
---

# Summary: pi-gen stage-arlowe chroot provisioning (model-free rootfs)

## What was built

A custom `pi-gen/stage-arlowe/` tree that assembles a single bootable, model-free
arlowe rootfs from Pi OS Lite arm64. Three sub-stages:

### 01-runtime
- **Host-side (`00-run.sh`):** stages the repo subdirs the chroot provisioning needs
  into `/tmp/arlowe-build/repo` inside the rootfs. Copies `scripts/provision/`,
  `units/`, `config/`, `runtime/`, `provision/`, `third_party/axcl/`,
  `third_party/whisplay-driver/`, and `scripts/verify-third-party.sh`. The axcl deb
  (user-supplied per Strategy C) is resolved from `AXCL_DEB` env or the manifest and
  staged with its chroot path written to `.axcl-deb-path`.
- **Chroot (`00-run-chroot.sh`):** runs the seven existing provisioning scripts in the
  order from `install-arlowe-on-arlowe1-staging.sh` with literal `arlowe` (no sed
  transforms). Populates `/opt/arlowe/runtime` from the staged repo; installs the axcl
  deb; vendors WhisPlay.py to `/opt/arlowe/third_party/whisplay-driver/`; conditionally
  runs the WM8960 installer (skips with a log note if bundle absent — rights
  unresolved); adds a read-only fstab entry for the shared models partition (PARTUUID
  placeholder for 06-04); cleans apt caches, `__pycache__`, machine-id, and SSH host
  keys for reproducibility.

### 02-models
- **Host-side (`00-run.sh`):** assembles verified model artifacts from
  `ARLOWE_MODELS_CACHE` into a SEPARATE standalone models tree at `ARLOWE_MODELS_STAGE`
  (default under `WORK_DIR`). Paths match unit environment variables exactly:
  `qwen2.5-7b-int4-ax650/` (QWEN_MODEL_DIR), `piper-voices/` (ARLOWE_PIPER_MODEL),
  `whisper/small.en/` (faster-whisper cache). Exports the tree path to a marker file
  for plan 06-04's `partition-image.sh`. Fails clearly if any artifact is absent.

### 03-firstboot
- **Service (`files/arlowe-firstboot.service`):** a `Type=oneshot` unit guarded by
  `ConditionPathExists=!/var/lib/arlowe/.firstboot-done`. Runs `boot-check
  --first-boot`, writes the sentinel. Logs `ready to pair` to journal. The seam for
  06-04's models partition grow-to-fill resize. Does NOT start a pairing daemon (Phase 8).
- **Chroot (`00-run-chroot.sh`):** installs the service and enables it via a wants
  symlink (systemctl enable is not available without systemd as PID 1 in the build chroot).

## Key design decisions followed

- **ADR-0004 shared models partition:** `/opt/arlowe/models` is an empty mount point in
  the rootfs; models live exclusively in the separate staging tree for 06-04 to place on
  the shared partition.
- **No sed transforms:** literal `arlowe` throughout — this is the production image.
- **No Phase 8 pull-forward:** first-boot hook arms "ready to pair" and stops. Pairing
  daemon is Phase 8.
- **PARTUUID placeholder:** fstab entry uses `ARLOWE-MODELS-PARTUUID-REPLACE-BY-06-04`
  as the token; plan 06-04's partition-image.sh does the substitution for both slots.

## Deferred to 06-04

- Real PARTUUID substitution in slot A and B fstabs.
- Grow-to-fill resize of the models partition (ExecStartPre stanza in arlowe-firstboot).
- Wiring `HF_HOME` in whisper-stt.service to `/opt/arlowe/models` so faster-whisper
  picks up the pre-populated cache.

## Verification

All plan checks passed:
- `bash -n` clean for all five shell scripts
- All seven provisioning steps present in the chroot script
- PARTUUID placeholder in fstab entry
- Models tree assembled at unit-expected sub-paths, no "chroot" word in models script
- WhisPlay vendored in chroot script; `runtime/face/README.md` updated
- First-boot oneshot with `ConditionPathExists` sentinel guard and `Type=oneshot`
