# runtime/voice

Voice orchestrator for the Arlowe device. Implements the full wake-word → STT → LLM → TTS → face pipeline as a single long-running Python process.

## Process model

Runs as a single Python process under the `arlowe` system user (currently the developer user via `--user` systemd unit during development — see Known Limitations). Launched by `arlowe-voice.service`. No inbound network surface; all I/O is via pyaudio mic, ALSA playback, and outbound HTTP to sibling services.

## Inbound

- pyaudio microphone stream on `RECORD_DEVICE` (currently `plughw:2,0`, the WM8960 USB audio HAT at 16 kHz S16_LE mono)
- No inbound TCP port

## Outbound HTTP calls

| Target | URL (default; env override) | Used for |
|---|---|---|
| face service | `http://localhost:8080/state` (`ARLOWE_FACE_URL`) | render face expression and background during each pipeline stage |
| STT server | `http://localhost:8082/transcribe` (`ARLOWE_STT_URL`) | transcribe wake-window audio via faster-whisper |
| LLM router | via `llm.router` (delegates internally to `localhost:8000` or `claude` CLI) | generate response text |
| dashboard | `http://localhost:3000` (`ARLOWE_DASHBOARD_URL`) | rules engine fetches orchestration config; stub does not call this today |

## How to run locally on arlowe-1

Requires the face service, STT server, and LLM router to be running first.

```bash
cd /path/to/arlowe-firmware/runtime
PYTHONPATH=. python3 voice/voice_client.py
```

The process streams diagnostic output to stdout. Structured voice logs go to `/var/lib/arlowe/logs/voice/voice_YYYY-MM-DD.log`.

## Key files

| File | Purpose |
|---|---|
| `voice_client.py` | Wake → STT → LLM → TTS → face orchestrator (main entry point) |
| `voice_expression_controller.py` | FSM that maps voice events to face expressions with optional auto-return to idle |
| `voice_expression_config.json` | Configurable mapping: event name → expression + background + duration |
| `voice_log.py` | Log viewer and rotation helper utility |
| `wake_test.py` | Debug utility: listens for wake word and prints scores without full pipeline |
| `rules_engine.py` | Stub: evaluates orchestration rules against voice input (currently returns `[]`) |
| `action_executor.py` | Stub: executes rule-triggered actions like set_expression and play_tts |

## Dependencies

See `requirements.txt`. Run from `/opt/arlowe/venv/` at image time or from the dev venv during development.

## Environment overrides

All filesystem paths and sibling-service URLs are configurable via environment variables. Defaults match the product layout (`/opt/arlowe/...`, `/var/lib/arlowe/...`).

| Variable | Default | Purpose |
|---|---|---|
| `ARLOWE_PIPER_PATH` | `/opt/arlowe/runtime/tts/bin/piper` | Piper TTS binary |
| `ARLOWE_PIPER_MODEL` | `/opt/arlowe/models/piper-voices/en_US-lessac-medium.onnx` | Piper voice model |
| `ARLOWE_VERIFIER_MODEL` | `/var/lib/arlowe/wake-word/verifier.pkl` | Wake-word verifier `.pkl` |
| `ARLOWE_ALSA_DEVICE` | `plughw:2,0` | ALSA record + play device |
| `ARLOWE_FACE_URL` | `http://localhost:8080` | Face service base URL |
| `ARLOWE_STT_URL` | `http://localhost:8082/transcribe` | STT endpoint |
| `ARLOWE_DASHBOARD_URL` | `http://localhost:3000` | Dashboard base URL |
| `ARLOWE_LOGS_DIR` | `/var/lib/arlowe/logs` | Base logs dir (`voice/` subdir created here) |

Set these via the systemd unit's `Environment=` lines on dev/test units, or globally in the image build for production.

## Known limitations

- `RECORD_DEVICE` / `PLAY_DEVICE` hardcoded to `plughw:2,0`. Config-driven audio device selection is Phase 5 scope.
- `fan_off()` / `fan_on()` shell out to `sudo tee /sys/class/hwmon/hwmon2/pwm1`. Works on the dev unit with passwordless sudo. Will break when migrated to a dedicated `arlowe` system user. Fix requires a polkit rule or `chgrp`/`chmod` on the hwmon PWM node at boot (Phase 4 scope).
- Cloud LLM path (`llm.router.query_cloud`) invokes the `claude` CLI, which authenticates via the device owner's `~/.claude/.credentials.json`. A customer unit cannot use this path until Phase 7 (device pairing and per-customer API key provisioning).
- The `--user` systemd unit runs as the developer user during development. Migration to a system-level unit under a dedicated `arlowe` user is Phase 4 / image-build scope.

## Architecture reference

See `docs/architecture/0001-iol-router-extraction.md` for the history of the LLM router rename and extraction.
