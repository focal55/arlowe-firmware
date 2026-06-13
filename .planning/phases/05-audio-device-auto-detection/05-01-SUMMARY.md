# 05-01 Summary: arlowe_audio module

**Completed:** 2026-06-13
**PR:** feat/05-01-arlowe-audio (Closes #88)

---

## Public API

### `enumerate_cards(proc_root="/proc/asound") -> list[dict]`

Parses `/proc/asound/cards` and per-card `id`/`usbid`/`pcm*c`/`pcm*p` files.
Returns a list of dicts with keys:
- `index` (int) — ALSA card index (ephemeral; use only to build plughw:N,0)
- `id` (str) — stable card-id token from `/proc/asound/card<N>/id`
- `longname` (str) — human-readable name from the `cards` listing
- `is_usb`, `is_wm8960`, `is_hdmi` (bool) — card type flags
- `has_capture`, `has_playback` (bool) — capability flags

`proc_root` is injectable so tests use fixture trees without real hardware.

### `resolve_capture(override_token, cards=None, proc_root="/proc/asound") -> str | None`

Resolve the capture (mic) device string. Returns `plughw:N,0` or `None`.

Priority:
1. `override_token` resolves to a present card with capture capability
2. Auto-pick: first USB capture card (lowest index)
3. Auto-pick: first wm8960 capture card (lowest index)
4. `None` — genuine no-mic failure

### `resolve_playback(override_token, cards=None, proc_root="/proc/asound") -> str | None`

Resolve the playback (speaker) device string. Returns `plughw:N,0` or `None`.

Priority:
1. `override_token` resolves to a present card with playback capability
2. Auto-pick: first USB playback card (lowest index)
3. Auto-pick: wm8960 codec (Whisplay HAT)
4. Auto-pick: HDMI (last resort)
5. `None` — no playback card

### `portaudio_index_for_card(card_id_or_plughw, pa) -> int | None`

Maps an ALSA card to a PortAudio input device index by name substring match.
Handles the wake-word path (pyaudio) divergence from the arecord/aplay path.
`pyaudio` is imported lazily — module imports cleanly in CI without it.

---

## Card-id token convention

- **Stored value**: raw ALSA card-id string from `/proc/asound/card<N>/id`
  (e.g. `"Device"`, `"wm8960soundcard"`). Stable across reboots and re-plugs.
- **Sentinel**: `"auto"` or absent/`None` = auto-detect, no stored override.
- **Config keys**: `audio.capture_device` / `audio.playback_device` in
  `/etc/arlowe/config.yml` (Phase 4 schema; both default `"auto"`).
- **At runtime**: stored token -> live `plughw:N,0` resolved fresh on each call
  by scanning `/proc/asound`. If the token's card is absent -> silent fallback
  to auto-pick.

---

## Fixture layout

```
runtime/lib/tests/fixtures/proc_asound/
  usb_plus_wm8960/   card0=wm8960 (cap+play), card1=USB (cap+play), card2=vc4-hdmi (play)
  wm8960_only/       card0=wm8960 (cap+play), card1+2=vc4-hdmi (play only)
  no_capture/        card0+1=vc4-hdmi (play only) -- genuine no-mic case
  two_usb_capture/   card0=USB-A, card1=USB-B -- tie-break (lowest index) test
```

---

## Downstream dependencies

05-02, 05-03, 05-05 import or invoke this module. The contract:
- `enumerate_cards` / `resolve_capture` / `resolve_playback` are the stable entry points.
- CLI: `python3 -m arlowe_audio --resolve-capture`, `--resolve-playback`, `--list`.
- No side effects; no config writes; no service restarts.
