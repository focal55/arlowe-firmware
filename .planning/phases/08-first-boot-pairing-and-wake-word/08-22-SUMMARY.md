---
phase: 08-first-boot-pairing-and-wake-word
plan: 22
subsystem: face
tags: [whisplay, gpio, factory-reset, state-machine]
requires: [08-11, 08-18]
provides:
  - "face.reset_gesture.ResetGesture: press(t)/release(t)/tick(t) -> Intent(overlay_text, countdown, led, trigger)"
  - "arlowe-face starts arlowe-factory-reset@button.service on hold 10 s, release, press within 5 s"
affects: [08-27b]
tech-stack:
  added: []
  patterns: ["GPIO callbacks enqueue timestamped events; the render loop drains and ticks"]
key-files:
  created:
    - runtime/face/reset_gesture.py
    - tests/phase-8/test_reset_gesture.py
  modified:
    - runtime/face/face.py
decisions:
  - "Overlay replaces the whole face with a dark-red card and white DejaVuSans 22 px text, word-wrapped"
  - "A press after the confirm window expires starts a new hold rather than resetting"
metrics:
  duration: ~30min
  completed: 2026-09-29
---

# Phase 8 Plan 22: Whisplay button reset Summary

The face service owns the button on a paired unit and now runs the ADR-0013 gesture: countdown drawn from 3 s held (`ceil(10 - held)`), LED red and "Release, then press to confirm" at 10 s, then a press within 5 s of the release runs `systemctl start --no-block arlowe-factory-reset@button.service` once and logs "factory reset requested (button)". An early release, a missed window or a short press returns the face and its state LED colour.

## Tasks

| Task | Name | Commit |
| ---- | ---- | ------ |
| 1 | Cases (RED) | c367490 |
| 2 | Gesture and face wiring (GREEN) | 1b5501d |

## Interface

- `ArloweeFace(clock=time.monotonic, run=subprocess.run)`; both default to the real thing. `poll_button()` is called once per frame from `run()`; `overlay_text` holds the current overlay (None when idle).
- `set_state()` records the state colour and does not repaint the LED while the gesture holds it red; cancel restores the latest state colour.
- The overlay font honours `ARLOWE_FONT_PATH` (default DejaVuSans, as `pair.display`).

## Verification

- Mac: `pytest tests/phase-8/test_reset_gesture.py` 9 passed, 1 failed (the overlay render needs DejaVuSans, absent on macOS).
- `debian:bookworm` with the 00-packages-nr Python/font set (the `pair-bookworm` recipe, Pillow 9.4.0): `test_reset_gesture.py` + `test_display.py` 37 passed, face golden not skipped and unchanged; full `runtime/pair/tests tests/phase-8` 153 passed.
- `tests/phase-07.1/run-import-check.sh`: OK; arlowe-face walks `runtime/face/reset_gesture.py`.
- `runtime/face/tests`: 2 passed. `scripts/sanitize/check.sh`: clean.
- Not verified: button timing and polkit start on hardware (08-27b).

## Deviations from Plan

1. [Rule 2] The trigger logs a non-zero `systemctl` exit ("factory reset start failed: exit N") so a polkit denial is visible in the journal.
2. [Rule 1] `set_state()` from the HTTP thread would have repainted the red LED mid-gesture; it now defers to the gesture's LED.
3. Tests drive the real driver callbacks (`on_button_press`/`on_button_release` recorded by the fake `WhisPlay`) and inject clock and runner through the constructor; 10 cases rather than 9 (added a release-after-10 s-without-tick case and a cancel-restores-colour face case).
4. Size: 345 net lines of code and tests against the plan's 260, from the overlay word-wrap and the two extra cases.
