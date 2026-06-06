---
phase: 03-service-user-and-filesystem-layout
plan: 03
subsystem: infra
tags: [debian, udev, polkit, gpio, spi, axera, permissions, provision]

requires:
  - plan-03-01  # arlowe user + filesystem layout

provides:
  - udev rule: provision/udev/90-arlowe-axera.rules
      chowns /dev/axcl_host and /dev/ax_mmb_dev to root:arlowe 0660
      required by arlowe-face, arlowe-voice, arlowe-llm (NPU access)
  - udev rule: provision/udev/91-arlowe-gpio-spi.rules
      chowns /dev/gpiochip[0-9]* to root:gpio 0660 (covers gpiochip0 and gpiochip4)
      chowns /dev/gpiomem to root:gpio 0660
      chowns /dev/spidev* to root:spi 0660
      required by arlowe-face (WhisPlay LCD panel via SPI)
  - polkit rule: provision/polkit/50-arlowe-systemctl.rules
      grants `arlowe` user right to systemctl start/stop/restart/reload
      units matching: arlowe-* | qwen-* | whisper-stt.service
      action: org.freedesktop.systemd1.manage-units only
      does NOT grant daemon-reload, unit editing, or any other action
      required by: dashboard POST /api/voice (Phase 1), POST /api/config (Phase 4), pairing daemon (Phase 8)
  - installer: scripts/provision/install-arlowe-udev-polkit.sh
      idempotent; copies all three rule files + udevadm reload; picked up
      by run-tests.sh auto-discovery
  - diagnostic: scripts/provision/extract-axcl-udev-from-deb.sh
      inspects axcl_host_aarch64_V3.10.2.deb for conflicting udev rules;
      exits 2 gracefully when deb is absent (Strategy C: user-supplied)
  - assertion: tests/phase-3/assertions/04-udev-polkit-shape.sh
      SC4 shape check: file presence, mode 0644, polkit JS syntax, content patterns

axcl-deb-diagnostic-result:
  status: deb-not-present
  note: "axcl_host_aarch64_V3.10.2.deb is user-supplied (Strategy C). Deb was
         not available at plan-03-03 execution time. 90-arlowe-axera.rules ships
         with assumption of no conflict. Run extract-axcl-udev-from-deb.sh once
         the deb is placed at third_party/axcl/ to confirm. Plan 03-05 hardware
         verification on the device will catch any remaining conflict."

affects:
  - phase-3-04-cli-symlinks         # parallel wave; no shared files
  - phase-3-05-hardware-staging     # owns real-hardware verification of udev rule application
  - phase-4-config-overlay          # dashboard POST /api/config restart endpoint — polkit rule is in place
  - phase-5-audio-autodetect        # will verify which gpiochip the WhisPlay driver opens
  - phase-6-image-build             # provision/ is the pi-gen overlay source; no further changes needed here
  - phase-8-pairing                 # pairing daemon completion can now start arlowe-* via systemctl
  - phase-11-boot-check             # device-perms contract: Axera nodes root:arlowe 0660, GPIO root:gpio 0660

tech-stack:
  patterns: [udev KERNEL== match, polkit addRule JS, install -m 0644, udevadm control --reload]

key-files:
  created:
    - provision/udev/90-arlowe-axera.rules
    - provision/udev/91-arlowe-gpio-spi.rules
    - provision/polkit/50-arlowe-systemctl.rules
    - scripts/provision/install-arlowe-udev-polkit.sh
    - scripts/provision/extract-axcl-udev-from-deb.sh
    - tests/phase-3/assertions/04-udev-polkit-shape.sh
  modified:
    - .sanitize-allowlist

key-decisions:
  - "90-arlowe-axera.rules uses KERNEL== match (device node name) rather than SUBSYSTEM== because the axcl devices may not have a stable subsystem attribute; KERNEL== is unconditional and guaranteed to match"
  - "91-arlowe-gpio-spi.rules uses wildcard KERNEL==gpiochip[0-9]* to cover both gpiochip0 (Pi 4 and earlier) and gpiochip4 (Pi 5 RP1); plan 05 confirms which one WhisPlay actually opens"
  - "polkit rule grants by subject.user=='arlowe' (not by group) — simpler, auditable, matches how polkit is typically used for service accounts; no group check needed since only one account has this identity"
  - "polkit rule does not grant daemon-reload — units are root-owned and only OTA (sandboxed root) ever modifies them; granting daemon-reload to arlowe would be over-privileged"
  - "axcl deb diagnostic (extract-axcl-udev-from-deb.sh) exits 2 (not 1) for deb-not-present to distinguish missing-deb from actual errors"
  - "Node --check uses .js temp file copy to work around Node v12+ ESM rejecting .rules extension"
  - "04-udev-polkit-shape.sh added to .sanitize-allowlist because it contains focal55 in a grep pattern that verifies the polkit rule does NOT reference banned identities"

duration: ~60min
completed: 2026-06-06
---

# Phase 3 plan 03 summary

**Axera + GPIO/SPI udev rules + polkit systemctl rule + installer + SC4 assertion**

## Accomplishments

- Two udev rule files granting `arlowe` group access to Axera device nodes (`/dev/axcl_host`, `/dev/ax_mmb_dev`) and GPIO/SPI nodes (`/dev/gpiochip[0-9]*`, `/dev/gpiomem`, `/dev/spidev*`)
- Polkit JS rule allowing the `arlowe` user to `systemctl restart/start/stop/reload` units matching `arlowe-*`, `qwen-*`, `whisper-stt.service` — closes the dashboard `POST /api/voice` gap and pre-positions Phase 4 and Phase 8
- Idempotent installer (`install-arlowe-udev-polkit.sh`) picked up automatically by the Phase 3 Docker testbed auto-discovery loop
- Diagnostic helper (`extract-axcl-udev-from-deb.sh`) gracefully handles the user-supplied deb (Strategy C) case with exit code 2 and clear guidance
- SC4 assertion (`04-udev-polkit-shape.sh`) passes in Docker testbed; JS syntax validated via node temp-file workaround for Node ESM extension restrictions

## Deviations from Plan

**1. node --check .rules extension rejection** — Node v12+ ESM rejects `.rules` extension with `ERR_UNKNOWN_FILE_EXTENSION`. Assertion copies the rule to a `.js` temp file for `node --check`, then removes it. Behavior is identical; the JS syntax is validated against real content.

**2. axcl deb not available** — Strategy C (user-supplied) means the deb was not present during plan execution. `extract-axcl-udev-from-deb.sh` exits 2 as designed. `90-arlowe-axera.rules` ships with no-conflict assumption; plan 05 hardware verification is the backstop.

**3. `arlowe-1` and `focal55` literals in new test file** — `04-udev-polkit-shape.sh` uses `focal55` in a grep pattern verifying the polkit rule is clean. Added to `.sanitize-allowlist` with the same rationale as `01-user-shape.sh` (negative check, never ships in firmware image).

## Next Phase Readiness

Phase 4 dashboard config-restart endpoint can reference `org.freedesktop.systemd1.manage-units` — polkit rule is installed. Phase 5 audio autodetect should verify which gpiochip the WhisPlay driver opens and update research notes. Phase 6 image build picks up `provision/` as a pi-gen overlay directory with no further changes to this plan. Phase 8 pairing daemon can rely on the polkit rule to start `arlowe-*` units after pairing completes.

---
*Phase: 03-service-user-and-filesystem-layout | Completed: 2026-06-06*
