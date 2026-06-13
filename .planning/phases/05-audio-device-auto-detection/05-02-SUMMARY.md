# 05-02 Summary: Python audio wiring

**Completed:** 2026-06-13
**PR:** feat/05-02-python-audio-wiring (Closes #89)

---

## Files changed

- `runtime/voice/voice_client.py`
- `runtime/tts/tts_sync.py`
- `runtime/wake-word/auto_collect.py`

---

## Device resolution strategy

### Env-var precedence (all three files)

```
ARLOWE_ALSA_DEVICE / ARLOWE_PLAY_DEVICE  (manual escape hatch, highest)
  > arlowe_audio.resolve_capture / resolve_playback  (auto-detect or override token)
  > "plughw:2,0"  (last-ditch literal; service stays up degraded)
```

Capture and playback are resolved independently in every file — they may be different physical cards.

### Config override tokens

All three files load `arlowe_config.load()["audio"]["capture_device"]` and `["playback_device"]` as override tokens for the resolver. The config load is guarded with `except Exception` so the modules import cleanly outside the deployed layout.

---

## Critical fix: pyaudio device-index alignment (voice_client.py)

`voice_client.py` had two independent capture surfaces:
1. `arecord` subprocess — used `RECORD_DEVICE` (ALSA plughw string).
2. pyaudio wake-word stream — grabbed "first PortAudio input by index", ignoring `RECORD_DEVICE`.

These could target different physical cards, causing the always-on wake-word mic to diverge from the STT-capture mic.

Fix: at wake-word stream init, `device_index` is now resolved via `arlowe_audio.portaudio_index_for_card(RECORD_DEVICE, pa)`. PortAudio uses a separate namespace from ALSA; the helper maps the resolved ALSA card to a PortAudio input index by name-substring match. If no match, the original "first input-capable device" loop runs as fallback with a stderr log line.

The resolved `device_index` is assigned once at its definition (~line 358) and reused by both `pa.open` call sites: the initial stream (~line 374) and the post-conversation re-open (~line 558). No second assignment or literal between the two opens.

---

## tts_sync.py

Constructor default changed from `play_device: str = "plughw:2,0"` to `play_device: str | None = None`. When `None`, the `__init__` body resolves via `arlowe_audio.resolve_playback` with a config-sourced override token, falling back to the literal. Imports are lazy (inside `__init__`) to avoid import-time config dependency in environments without the overlay. The `aplay -D {self.play_device}` call site is unchanged.

---

## auto_collect.py

Added `_PLAY_DEVICE` alongside the existing `_ALSA_DEVICE`. The `beep()` function previously used `_ALSA_DEVICE` for the `aplay` call, conflating capture and playback. It now uses `_PLAY_DEVICE`. Both are resolved via `arlowe_audio` with config override tokens and env-var escape hatches.

The `sys.path.insert` for `../lib` ensures `arlowe_audio` is importable when the script is run directly; the entire import block is wrapped in `except Exception` so the script still imports if run outside the deployed layout.

---

## Residual concern

If a device is hotplugged mid-recording (P5 in the research doc), the running session continues with the stale `RECORD_DEVICE` / `device_index` since resolution happens at module load and stream init. This is acceptable for now — the boot-check (05-06) is the formal failure surface, and hotplug-restart is tracked separately. The service will pick up the new device on next restart.
