# runtime/stt — Speech-to-Text Server

faster-whisper HTTP server listening on `tcp/8082`. The voice pipeline posts raw WAV audio
to `/transcribe` and receives a JSON transcript. This is the only STT component; it runs as
a long-lived process with the model held in memory.

## Endpoints

### `GET /health`

Returns the server status and loaded model name.

```
200 OK
{"status": "ok", "model": "base.en"}
```

### `POST /transcribe`

Body: raw WAV bytes (Content-Length required).

```
200 OK
{"text": "hello world", "language": "en", "duration": 1.42}

500 Internal Server Error
{"error": "<exception message>"}
```

The endpoint writes the body to a temp file, runs faster-whisper, and deletes the temp file
before responding. VAD filtering is on (`min_silence_duration_ms=500`).

## Model

`base.en` — English-only Whisper base model. Downloaded on first run by faster-whisper to
`~/.cache/huggingface/`. In the image build, pre-populate `/var/lib/arlowe/models/whisper/`
to skip the runtime download.

## Running on a Pi 5 dev unit

```bash
# Activate the voice venv and start the server
~/venvs/voice/bin/python runtime/stt/stt_server.py

# Or via the systemd unit (see systemd-whisplay/ stash for whisper-stt.service)
systemctl --user start whisper-stt
```

Verify liveness:
```bash
curl http://localhost:8082/health
# {"status": "ok", "model": "base.en"}
```

## Dependencies

See `requirements.txt`. Install into the voice venv:

```bash
~/venvs/voice/bin/pip install -r runtime/stt/requirements.txt
```

## Known behaviour

- Model loads synchronously at startup (~3 seconds on Pi 5 with int8 compute type).
- `beam_size=1` keeps latency low at a small accuracy trade-off.
- Server is single-threaded; concurrent transcription requests queue behind each other.
