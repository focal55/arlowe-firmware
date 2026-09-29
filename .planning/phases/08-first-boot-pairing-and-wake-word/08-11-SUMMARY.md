---
phase: 08-first-boot-pairing-and-wake-word
plan: 11
subsystem: display
tags: [whisplay, pillow, qrcode, rgb565, pairing]
requires:
  - phase: 08-07
    provides: pair.errors.ErrorKind and MESSAGES, SSID/PSK shape
provides:
  - arlowe_display.to_rgb565 shared by face and pairing
  - pair.display Screen, render, lines, wifi_qr_payload, qr_matrix, qr_geometry, Display
affects: [08-13 pairing flow, 08-25 pairing daemon unit, 08-27a checkpoint build]
key-files:
  created: [runtime/lib/arlowe_display.py, runtime/pair/display.py, runtime/pair/tests/test_display.py]
  modified: [runtime/face/face.py, pi-gen/stage-arlowe/00-packages/00-packages-nr]
key-decisions:
  - "QR at level L: version 3, 29 modules, 5 px, 2-module quiet zone"
  - "Face golden is pinned to Pillow 9.4.0 and skips under any other Pillow"
duration: 40min
completed: 2026-09-29
---

# Phase 8 Plan 11: Pairing Screens Summary

**Whisplay pairing screens (waiting with a `WIFI:T:WPA;S:<ssid>;P:<psk>;;` QR, connecting, provisioning, paired, idle, each error kind) and one RGB565 conversion shared with the face. python3-qrcode is declared in the same change.**

## Task Commits

1. **Task 1: Golden digest and cases (RED)** - `a513525` (test)
2. **Task 2: Shared conversion, screens, package (GREEN)** - `97f20c9` (feat)
3. **Rule 1 fix: Screen.error shadowed its field** - `5ac6300` (fix)

## Verification

- Snapshot 20260915T000000Z arm64 has `python3-qrcode 7.4.2-2` (deps python3-png 0.20220715.0-1, python3-typing-extensions 4.4.0-1, python3-pillow provided by python3-pil 9.4.0). `fonts-dejavu-core 2.37-6` already has a pkg row.
- The face golden `519bd87e...` came from the pre-refactor loop under bookworm Pillow 9.4.0. amd64 and arm64 produce the same digest.
- pair-bookworm equivalent (debian:bookworm amd64, package set derived from the edited 00-packages-nr): `test_display.py` 26 passed with no skips. Full `runtime/pair/tests` + `tests/phase-8`: 71 passed.
- `tests/phase-07.1/run-import-check.sh` (arm64): OK. arlowe-face now walks `runtime/lib/arlowe_display.py`.
- Not verified: scanning the QR from the panel with a phone camera, and whether text sits clear of the panel's rounded corners. Both need hardware (08-27b).

## Deviations from Plan

1. **[Rule 1 - Bug] Dataclass field shadowed by its constructor.** A field and a classmethod were both named `error`, so the classmethod became the field's default. The field is now `failure`, and a regression assertion covers it. Commit `5ac6300`.
2. **Golden is version-gated.** Pillow's rasteriser output is only stable within one release, so the golden test skips when Pillow is not 9.4.0. A second test pins `to_rgb565` to the old loop on any Pillow version.
3. **Test hooks beyond the plan's exports:** `lines(screen)`, `qr_matrix`, `qr_geometry`, `wrap`, `font`, `QR_BORDER`, `QR_ERROR_CORRECTION`, `TEXT_WIDTH` and `BODY_SIZE`. The tests use them to check QR pixels and text without OCR.
4. **LED colours the plan left open:** connecting and provisioning are blue like waiting. Idle is dim blue `(0, 0, 40)`.

## Next Phase Readiness

- Merge-gated on 07.3-09 (#187). This plan adds pkg rows for python3-qrcode, python3-png and python3-typing-extensions.
- Side effect: python3-typing-extensions 4.4.0 now sits in system site-packages, which all three `--system-site-packages` venvs can see. pip in the llm venv already installs its own newer copy over it. A `--no-deps` venv package that needs a newer typing_extensions and does not declare it would now import 4.4.0 and misbehave, where before it would have failed at import.
- 08-13 API: `Display()` claims the board. Call `show(Screen.waiting(ssid, psk))`, `Screen.error(ErrorKind)`, `Screen.paired(url, ip)`, then `on_button(cb)`, then `close()` before starting the six units.
