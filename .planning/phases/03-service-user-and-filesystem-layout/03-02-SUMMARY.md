---
phase: 03-service-user-and-filesystem-layout
plan: 02
subsystem: infra
tags: [systemd, hardening, sandbox, units, docker, security-score]

requires:
  - 03-01

provides:
  - arlowe-face.service: User=arlowe Group=arlowe PrivateDevices=no SupplementaryGroups=gpio spi video DeviceAllow /dev/spidev0.0 /dev/spidev0.1 /dev/gpiomem /dev/gpiochip0 /dev/gpiochip4 /dev/fb0 ReadWritePaths=/var/lib/arlowe/state /var/lib/arlowe/logs/face threshold=4.5
  - arlowe-voice.service: User=arlowe Group=arlowe PrivateDevices=no SupplementaryGroups=audio dialout DeviceAllow /dev/snd/* RemoveIPC=no RestrictRealtime=no ReadWritePaths=/var/lib/arlowe/state /var/lib/arlowe/logs /var/lib/arlowe/conversations threshold=4.5
  - arlowe-dashboard.service: User=arlowe Group=arlowe PrivateDevices=yes NEXT_PRIVATE_CACHE_DIR=/var/lib/arlowe/dashboard/cache ReadWritePaths=/var/lib/arlowe/dashboard /var/lib/arlowe/logs/dashboard threshold=3.5
  - qwen-tokenizer.service: User=arlowe Group=arlowe PrivateDevices=yes full-baseline ReadWritePaths=/var/lib/arlowe/logs/llm threshold=3.5
  - qwen-api.service: User=arlowe Group=arlowe PrivateDevices=no DeviceAllow /dev/axcl_host /dev/ax_mmb_dev axcl PATH override ReadWritePaths=/var/lib/arlowe/logs/llm threshold=4.5
  - whisper-stt.service: User=arlowe Group=arlowe PrivateDevices=yes full-baseline ReadWritePaths=/var/lib/arlowe/logs/stt threshold=3.5
  - units/install-units.sh: idempotent — copies all six to /etc/systemd/system/, daemon-reload skipped when systemd not PID 1
  - SC3 assertion: tests/phase-3/assertions/03-unit-syntax.sh — verify + security thresholds + special-case + sanitization gate

security-thresholds:
  hardware-touching: 4.5  # face, voice, qwen-api (research §11 aspirational: 4.0)
  network-only: 3.5       # dashboard, qwen-tokenizer, whisper-stt (aspirational: 3.0)

fixmes-flagged:
  - "F1(face): port 8080 hardcoded in face_service.py — Phase 4 config overlay owns fix"
  - "F4(voice): voice_client.py shells out to 'sudo tee' for fan control — breaks under NoNewPrivileges; Phase 4 cleanup via udev hwmon chgrp or removal"
  - "Phase 4(dashboard): /etc/arlowe/config.yml write path needs privileged helper (polkit or setuid); intentionally absent from ReadWritePaths"

affects:
  - phase-3-03-udev-polkit
  - phase-3-04-cli-symlinks
  - phase-3-05-hardware-staging
  - phase-4-config-overlay
  - phase-5-audio-autodetect
  - phase-6-image-build
  - phase-9-ota
  - phase-11-boot-health

tech-stack:
  added: [systemd unit hardening, systemd-analyze verify, systemd-analyze security]
  patterns: [PrivateDevices=no+DeviceAllow for hardware, PrivateDevices=yes for network-only, ReadWritePaths per-unit, RemoveIPC=no for ALSA shmem]

key-files:
  created:
    - units/arlowe-face.service
    - units/arlowe-voice.service
    - units/arlowe-dashboard.service
    - units/qwen-tokenizer.service
    - units/qwen-api.service
    - units/whisper-stt.service
    - units/install-units.sh
    - tests/phase-3/assertions/03-unit-syntax.sh
  modified:
    - scripts/sanitize/check.sh  # defer git rev-parse until needed; --scan-dir+--units-only now works without git

key-decisions:
  - "RemoveIPC=no on arlowe-voice: preserves POSIX shmem for pyaudio/ALSA (research §12.7)"
  - "Both /dev/gpiochip0 and /dev/gpiochip4 in arlowe-face: covers Pi 5 main+RP1 chips until plan 05 confirms"
  - "ProtectKernelModules omitted from qwen-api: ax-llm may load kernel modules at startup"
  - "install-units.sh skips daemon-reload when systemd is not PID 1: testbed-safe without breaking real install"
  - "check.sh defers git rev-parse: --scan-dir+--units-only now runs inside Docker without git installed"
  - "SystemCallFilter=~@privileged only (not @resources) on arlowe-voice: Python subprocess compat (research §10)"

duration: ~1.5h
completed: 2026-06-06
---

# Phase 3 plan 02 summary

**Six sandboxed system-level service units + install helper + SC3 assertion**

## Accomplishments

- Six `.service` files under `units/`, all `User=arlowe Group=arlowe`, system-level (no `--user`)
- Hardening baseline applied to all: `NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=strict`, `ProtectHome`, kernel protections, `RestrictNamespaces`, `LockPersonality`, syscall filter
- Hardware-touching units (face, voice, qwen-api): `PrivateDevices=no` + tight `DeviceAllow=` entries
- Network-only units (dashboard, qwen-tokenizer, whisper-stt): `PrivateDevices=yes`, full baseline
- `units/install-units.sh`: idempotent, skips `daemon-reload` when systemd not PID 1 (testbed-safe)
- `tests/phase-3/assertions/03-unit-syntax.sh`: SC3 assertion covering verify, security thresholds, User= check, sanitization gate, special-case requirements
- Docker testbed SC1 + SC2 + SC3 all green; Phase 2 sanitization gate clean repo-wide
- FIXMEs flagged for Phase 4: face port-8080, voice sudo-tee fan control, dashboard config.yml write path

## Deviations from Plan

**1. check.sh required a fix for Docker testbed.** `check.sh` called `git rev-parse` unconditionally; `--scan-dir --units-only` mode fails inside the testbed where git is not installed. Fixed by deferring `git rev-parse` until needed (only when SCAN_DIR is empty). Minimal 5-line change.

**2. systemd-analyze security returns N/A in testbed.** The Docker container runs with `--entrypoint /bin/bash` (no systemd bus); `systemd-analyze security` cannot get the exposure score. Assertion handles gracefully as "skip" — score gates are real gates on hardware. `systemd-analyze verify` runs clean (missing executables are expected warnings, not errors).

## Next Phase Readiness

Plans 03-03 (udev/polkit) and 03-04 (CLI symlinks) can start immediately. Plan 03-05 (hardware staging) can now run the full SC1–SC4 suite against arlowe-staging user on arlowe-1, including hardware-loop validation of security scores. Phase 4 must implement the privileged-helper write path for `/etc/arlowe/config.yml`.

---
*Phase: 03-service-user-and-filesystem-layout | Completed: 2026-06-06*
