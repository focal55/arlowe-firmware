# 05-07 Summary: Phase 5 hardware-verify runbook + SC2 wm8960 reframe

**Completed:** 2026-06-13
**PR:** docs/05-07-phase5-audio-runbook (Closes #94)
**Checkpoint:** DEFERRED — on-device run pending Phase 6/12 (per Phase 1/3/4 precedent)

---

## Disposition

**Autonomous deliverables completed (this plan):**

- `docs/operations/phase-5-audio.md` — runnable SC1–SC4 + hotplug + deferred-unknowns
  verification procedure. Ready to execute on a provisioned Pi.
- `.planning/ROADMAP.md` SC2 annotation — the hardware reframe footnote and the
  Phase 5 plan list were added in commit `03d8b01` (chore(planning): mark Phase 5
  planned). This plan cross-references that annotation from the runbook.

**On-device run: DEFERRED** (matching Phase 1 plan 13, Phase 3 plan 05-05, Phase 4
plan 04-04). arlowe-1 has no `/opt/arlowe` arlowe-user layout with Phase 5 runtime
installed. The deferred checkpoint resumes at the Phase 3-style staging harness,
Phase 6 image build, or Phase 12 first-flash.

---

## SC2 reframe disposition

The ROADMAP SC2 original text is preserved verbatim ("audio output falls back to
the 3.5mm jack"). A parenthetical annotation immediately follows, citing research
§6 and linking to `docs/operations/phase-5-audio.md`. The discrepancy is on the
record; it was not silently ignored.

The authoritative reframe in `docs/operations/phase-5-audio.md` section "SC2
reframe" states: the Pi 5 has no onboard 3.5mm jack; the real fallback chain is
USB out → Whisplay/WM8960 codec → HDMI; selection matches the `wm8960` substring.

---

## Hardware-confirm checklist (carried forward to Phase 6/12)

The following items from research Open Questions cannot be resolved without a
running Phase 5 provisioned Pi:

1. **Exact `sound` udev events + debounce anchor** — `udevadm monitor
   --subsystem-match=sound` while plugging; confirm `controlC[0-9]*` is the right
   anchor for `92-arlowe-audio.rules`.
2. **`arecord -l` under dashboard `PrivateDevices=yes`** — confirm the
   `/api/audio/devices` fs-read path returns correct data; confirm `arecord -l`
   is not needed (or confirm it fails and the fs path is the workaround).
3. **boot-check boot-time run-user and `/var/lib/arlowe/state` writability** —
   confirm `audio-selfcheck.json` is written after a real boot invocation.
4. **Production WM8960 soundcard name** — `cat /proc/asound/cards`; confirm
   `wm8960` substring match holds.
5. **`/dev/snd/by-id` contents** — informational; confirm absent (expected).
6. **PortAudio/ALSA name-match for the wake-word stream** — confirm
   `portaudio_index_for_card()` resolves correctly; record PortAudio device list
   if it does not.

---

## Outstanding SCs

All four SCs remain hardware-deferred:

- **SC1** (USB capture auto-select + unplug/replug): requires real USB plug events.
- **SC2** (USB out preferred, wm8960 fallback): requires real playback and
  wm8960 card present.
- **SC3** (override persists across reboot, honored over auto): the config-write
  half was validated autonomously in Phase 4; the runtime-honoring half (resolved
  device matches override on a live Pi) is deferred.
- **SC4** (sentinel in journal + JSON): the selfcheck logic is unit-tested; the
  real-audio RMS and tone-plays assertions and boot-time writability are deferred.

Resume signal: "deferred" (expected) or "verified <results>" on real hardware.
