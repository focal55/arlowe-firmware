# runtime/tts — Text-to-Speech with Face Lip-Sync

TTS playback module with real-time face animation. Supports two backends: Piper (local, default)
and ElevenLabs (opt-in cloud). Streams mouth-shape data to `face_service` at
`http://localhost:8080/mouth` during playback for lip-sync.

Cross-package coupling to the dashboard's env file was removed in plan 04.
ElevenLabs key now loads from env or `/etc/arlowe/config.yml` only.

## Backends

### Piper (default)

Local TTS. No internet required. ~200ms generation latency on Pi 5.

- Binary: `/opt/arlowe/runtime/tts/bin/piper` (see `manifest.yml` for asset pins)
- Voice: `/opt/arlowe/models/piper-voices/en_US-lessac-medium.onnx`
- Config: `/opt/arlowe/models/piper-voices/en_US-lessac-medium.onnx.json`

### ElevenLabs (opt-in cloud)

Disabled by default. ~1-2s generation latency. Requires an API key.

Configure via either:
1. `ELEVENLABS_API_KEY` environment variable
2. `/etc/arlowe/config.yml` overlay:
   ```yaml
   tts:
     elevenlabs:
       api_key: "sk-..."
       voice_id: "EXAVITQu4vr4xnSDxMaL"   # optional; Sarah is default
       model_id: "eleven_turbo_v2_5"        # optional
   ```

Set `backend: elevenlabs` in `tts_config.json` to enable, or pass `backend=TTSBackend.ELEVENLABS`
at call time. When ElevenLabs fails, the module falls back to Piper automatically.

## Lip-sync stream

During TTS playback, mouth-shape amplitudes are computed from the audio waveform and streamed
to `http://localhost:8080/mouth` at 30 Hz. The face service translates these to mouth-shape
commands for the Whisplay display. If the face service is unreachable, playback continues
uninterrupted (errors are swallowed).

## System binary dependencies

These are system-level binaries installed via pi-gen at image build time — not pip packages:

- `piper` — TTS synthesis (pinned in `manifest.yml`)
- `aplay` — ALSA playback
- `sox` — audio conversion (WAV resampling + MP3-to-WAV for ElevenLabs path)

## Setup

### Python dependencies

```bash
~/venvs/voice/bin/pip install -r runtime/tts/requirements.txt
```

### PyYAML

PyYAML is required for the `/etc/arlowe/config.yml` overlay loader.
Verified present in a Pi 5 dev unit's voice venv at version `6.0.3`.

If PyYAML is absent on a fresh venv:
```bash
ssh <your-dev-pi> '~/venvs/voice/bin/pip install PyYAML==6.0.3'
```

This install requirement is also noted in plan 13 (smoke-test prerequisites).

### Piper assets

Assets are not included in the repo. The image build fetches and verifies them using
`manifest.yml`. For the Phase 1 smoke test on a Pi 5 dev unit, the assets are already present
at `~/models/piper/piper` and `~/models/piper-voices/en_US-lessac-medium.onnx`.

## Running / testing on a Pi 5 dev unit

```python
from pathlib import Path
from runtime.tts.tts_sync import TTSWithSync, TTSBackend

tts = TTSWithSync(
    piper_path=Path("/opt/arlowe/runtime/tts/bin/piper"),
    piper_model=Path("/opt/arlowe/models/piper-voices/en_US-lessac-medium.onnx"),
)
tts.speak_quick("Hello, I am Arlowe.")
```

Or run the built-in test:
```bash
~/venvs/voice/bin/python runtime/tts/tts_sync.py
```

## Known limitations

- `PLAY_DEVICE` defaults to `plughw:2,0` (USB combo card on the dev unit used for Phase 1 testing). Phase 5 will make
  this config-driven via audio auto-detect.
- Cloud TTS path (ElevenLabs) requires an owner-provisioned key. Phase 4 and 7 wire this
  fully through first-boot pairing + customer-bound API key. On a sanitized customer unit
  without a key, Piper is the only functional backend.
