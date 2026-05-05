# runtime/voice

Voice orchestrator for the Arlowe device. Implements the full wake-word → STT → LLM → TTS → face pipeline as a single long-running Python process.

## Process model

Runs as a single Python process under the `arlowe` system user (currently the developer user via `--user` systemd unit during development — see Known Limitations). Launched by `arlowe-voice.service`. No inbound network surface; all I/O is via pyaudio mic, ALSA playback, and outbound HTTP to sibling services.

## Inbound

- pyaudio microphone stream on `RECORD_DEVICE` (currently `plughw:2,0`, the WM8960 USB audio HAT at 16 kHz S16_LE mono)
- No inbound TCP port

## Outbound HTTP calls

| Target | URL | Used for |
|---|---|---|
| face service | `http://localhost:8080/state` | render face expression and background during each pipeline stage |
| STT server | `http://localhost:8082/transcribe` | transcribe wake-window audio via faster-whisper |
| LLM router | via `llm.router` (delegates internally to `localhost:8001` or `claude` CLI) | generate response text |
| dashboard | `http://localhost:3000` | rules engine fetches orchestration config; stub does not call this today |

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

## Known limitations

- `RECORD_DEVICE` / `PLAY_DEVICE` hardcoded to `plughw:2,0`. Config-driven audio device selection is Phase 5 scope.
- `fan_off()` / `fan_on()` shell out to `sudo tee /sys/class/hwmon/hwmon2/pwm1`. Works on the dev unit with passwordless sudo. Will break when migrated to a dedicated `arlowe` system user. Fix requires a polkit rule or `chgrp`/`chmod` on the hwmon PWM node at boot (Phase 4 scope).
- Cloud LLM path (`llm.router.query_cloud`) invokes the `claude` CLI, which authenticates via the device owner's `~/.claude/.credentials.json`. A customer unit cannot use this path until Phase 7 (device pairing and per-customer API key provisioning).
- The `--user` systemd unit runs as the developer user during development. Migration to a system-level unit under a dedicated `arlowe` user is Phase 4 / image-build scope.

## Architecture reference

See `docs/architecture/0001-iol-router-extraction.md` for the history of the LLM router rename and extraction.
