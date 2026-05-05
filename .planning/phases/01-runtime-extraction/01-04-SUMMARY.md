---
phase: 01-runtime-extraction
plan: "04"
type: summary
status: complete
---

# Plan 04 Summary: STT + TTS Extraction

## STT extraction (EXTRACT-03)

- Source: `.dev-stash/arlowe-1/whisplay/stt_server.py` (87 LOC)
- Destination: `runtime/stt/stt_server.py` (81 LOC after whitespace normalization)
- File was clean — no `sys.path.insert`, no `/home/...` paths, no founder literals
- Added model-download comment at top per plan (pre-populate `/var/lib/arlowe/models/whisper/` in image build)
- Dependencies from arlowe-1 voice venv (`~/venvs/voice/bin/pip freeze`):
  - `faster-whisper==1.2.1`
  - `ctranslate2==4.6.3`
  - `tokenizers==0.22.2`
  - `huggingface_hub==1.3.5`
  - `onnxruntime==1.23.2`
- `runtime/stt/README.md`: documents tcp/8082 contract, `/health` + `/transcribe` endpoints, model loading, how to run on arlowe-1

## TTS extraction with cross-package coupling fix (EXTRACT-04 / research R4)

- Source: `.dev-stash/arlowe-1/whisplay/tts_sync.py` (429 LOC)
- Destination: `runtime/tts/tts_sync.py` (~360 LOC after sanitization)

**Key edits made:**

1. **R4 fix — removed `.env.local` traversal**: replaced `load_elevenlabs_config()` which read
   `~/iol-monorepo/packages/arlowe-dashboard/.env.local` with `_load_elevenlabs_key()` that reads
   from (in priority order):
   - `ELEVENLABS_API_KEY` env var
   - `/etc/arlowe/config.yml` key `tts.elevenlabs.api_key`
   - `None` (ElevenLabs disabled)

2. **Import fix**: `from audio_sync import ...` → `from face.audio_sync import AudioSyncAnalyzer, get_audio_duration`
   (canonical copy from plan 03b; `runtime/face/audio_sync.py` was verified present before this plan ran)

3. **`sys.path.insert` removed**: original file did not have one — `tts_sync.py` was clean on this point

4. **Piper paths in `main()`**: updated from `Path.home() / "models/piper/..."` to
   `/opt/arlowe/runtime/tts/bin/piper` and `/opt/arlowe/models/piper-voices/en_US-lessac-medium.onnx`

5. **ElevenLabs error message**: updated to reference `/etc/arlowe/config.yml` instead of `dashboard .env.local`

6. **`tts_config.json`**: `backend` changed from `"elevenlabs"` to `"piper"`;
   `elevenlabs_enabled: false` added; `auto_story_mode` set to `false`;
   `_elevenlabs_note` key added documenting opt-in requirement

## Piper manifest pins (SHA-256s)

All hashes captured via `ssh arlowe-1 'sha256sum ...'` on 2026-05-02:

| Asset | SHA-256 |
|---|---|
| `~/models/piper/piper` binary | `0c44a6360a21367b5d03b8656c3e274f4de715f6533245d8c1f17c242631912b` |
| `~/models/piper-voices/en_US-lessac-medium.onnx` | `5efe09e69902187827af646e1a6e9d269dee769f9877d17b16b1b46eeaaf019f` |
| `~/models/piper-voices/en_US-lessac-medium.onnx.json` | `efe19c417bed055f2d69908248c6ba650fa135bc868b0e6abb3da181dab690a0` |

Piper version: `1.2.0` (matches `piper --version` output). Upstream URL set to the aarch64 tarball
for v1.2.0. Note: the SHA-256 pins are for the extracted binary, not the tarball — the image build
must extract the tarball and verify the binary hash, not the tarball hash.

## PyYAML install status (M5)

**Present** — `ssh arlowe-1 '~/venvs/voice/bin/python -c "import yaml; print(yaml.__version__)"'`
returned `6.0.3`. Pinned in `runtime/tts/requirements.txt` as `PyYAML==6.0.3`.

## depends_on 03b satisfied

`runtime/face/audio_sync.py` was verified present (merged via PR #22) before this plan ran.
`from face.audio_sync import AudioSyncAnalyzer, get_audio_duration` resolves correctly when
`runtime/` is on `PYTHONPATH`.
