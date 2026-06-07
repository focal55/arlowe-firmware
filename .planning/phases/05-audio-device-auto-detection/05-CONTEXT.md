# Phase 5: Audio device auto-detection - Context

**Gathered:** 2026-06-07
**Status:** Ready for planning

<domain>
## Phase Boundary

Eliminate the hardcoded `plughw:2,0`. At boot the runtime enumerates audio devices, auto-selects a sensible capture source (first compatible 16 kHz S16_LE per SC1) and output (USB-preferred, 3.5mm-jack fallback per SC2). The owner can override the selection from the dashboard; overrides persist in `/etc/arlowe/config.yml` (Phase 4 overlay), survive reboot, and win over auto-detection. A boot-check capture+playback sentinel surfaces audio failures via the journal (and the Phase 11 dashboard health view, consumed later).

Requirements: AUDIO-01, AUDIO-02, AUDIO-03, AUDIO-04.

Fixed by ROADMAP success criteria (not re-litigated here):
- Capture = first compatible 16 kHz S16_LE source, auto-picked; unplug/replug → next boot picks it up (SC1).
- Output = USB preferred when present, 3.5mm jack fallback when absent (SC2).
- Owner override persists in `/etc/arlowe/config.yml`, survives reboot, honored over auto-detect (SC3).
- Boot-check verifies a capture + playback sentinel, surfaces failures on dashboard health (Phase 11) + journal (SC4).

Out of scope (other phases): the dashboard *health view* surface itself (Phase 11), pairing/first-boot flows (Phase 8), image packaging of any new deps (Phase 6).
</domain>

<decisions>
## Implementation Decisions

### Capture selection & fallback
- **No USB capture device present → fall back to the onboard/HAT codec mic** (e.g. WM8960). The device stays functional-degraded rather than going deaf; "no mic at all" is then the genuine failure case.
- **Compatibility is forgiving: open via `plughw` and let ALSA resample/convert** as needed. Mirrors the old `plughw:2,0` behavior — nearly any USB mic qualifies rather than requiring native 16 kHz S16_LE. (Trade-off accepted: hidden resampling cost over device rejection.)
- **Tie-break when multiple compatible mics are present → Claude's discretion.** Recommended: lowest ALSA card index for determinism, with the duplicate-device case made explicit in the dashboard picker.

### Output selection & fallback
- Chain is USB-preferred → 3.5mm jack (locked by SC2).
- **Whether the onboard HAT/codec speaker also sits in the chain → Claude's discretion.** Researcher should confirm the actual hardware output topology (does the Whisplay/WM8960 expose a speaker path distinct from the 3.5mm jack?) before deciding; if it exists and is wired, append it as last-resort.

### Re-detection & override behavior
- **Auto-detection runs at boot AND on live hotplug (udev plug/unplug)** — the running services reconfigure when a device appears/disappears, not just at next boot. (Goes beyond SC1's boot-only wording; SC1 remains the minimum bar.)
- **Owner override device absent at boot → silently fall back to auto-detect** so the device keeps working. The override is honored whenever its device is present.
- **Auto-detected picks are ephemeral — never persisted.** `/etc/arlowe/config.yml` holds *only* owner overrides; absence of an override means "auto." No stale auto-pick state to reconcile.
- **Device-identity scheme for stored overrides → Claude's discretion.** Recommended: a stable USB identifier (card name / serial / `/dev/snd/by-id`) resolved to the current ALSA index at boot/hotplug, NOT a bare `plughw:N` — a bare index defeats the whole point of this phase since indices shuffle. Planner/researcher should confirm the by-id path is available on this hardware.

### Loopback / sentinel verification (entirely Claude's discretion)
Joe deferred all four sub-decisions. Recommended defaults for the planner (override if research says otherwise):
- **Test depth:** "move audio, no acoustic coupling" — capture records a short buffer and confirms it's non-silent; playback emits a tone; checked independently. Avoids the flakiness of requiring the mic to physically hear the speaker.
- **On failure:** retry a few times (devices may settle after USB enumeration), then start the service anyway and report. Prefer a functional-degraded device over a hard block.
- **When:** once at boot as part of post-boot validation (boot-check).
- **Surfacing:** emit a clean journal entry + structured status/exit code now, shaped so the Phase 11 dashboard health view can consume it. Face/dashboard indication deferred to Phase 11.

### Dashboard override UX
- **Picker = dropdown of currently-detected devices** (owner selects from what's enumerated; no raw ALSA string field in v1).
- **Labels = friendly card names** (human-readable). If duplicate names are possible, disambiguation is an implementation detail (tie into the device-identity scheme).
- **After save → persist to overlay and auto-restart the affected service** so the change takes effect, then confirm. Reuses Phase 4's atomic-write + knob→unit-restart pattern (04-03).
- **No devices detected → empty state with guidance** ("No audio devices detected — plug in a USB mic/speaker").

### Claude's Discretion (summary)
- Mic tie-break ordering; whether HAT speaker is in the output chain.
- Stored-override device-identity scheme (recommended: stable USB id, not bare index).
- All loopback/sentinel specifics (depth, failure handling, timing, surfacing) per recommended defaults above.
</decisions>

<specifics>
## Specific Ideas

- The whole phase exists to kill `plughw:2,0` brittleness — so any design that re-introduces a hardcoded or index-only device reference is wrong by construction. Stable device identity is the spirit even where it's marked "Claude's discretion."
- Override-save UX should feel like the persona knob from Phase 4 (04-03/04-04): atomic write, validate, restart affected unit, take effect on next interaction.
- Forgiving capture matching (`plughw` + onboard fallback) reflects a preference for "device keeps working, degraded" over "device refuses to run."
</specifics>

<deferred>
## Deferred Ideas

- Dashboard *health view* rendering of audio status — Phase 11 (this phase only emits the structured journal/status it will consume).
- Raw ALSA-string manual entry in the dashboard picker — not in v1; revisit if dropdown-only proves limiting.
- Full acoustic loopback (play-tone-hear-it-back) as a stronger integration check — could be folded into the Phase 12 first-flash hardware gate.
- F1 (face_service.py hardcoded port 8080 env override) — adjacent pending todo, NOT part of this phase's audio scope; address separately.
</deferred>

---

*Phase: 05-audio-device-auto-detection*
*Context gathered: 2026-06-07*
