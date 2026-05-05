---
plan: 02
type: summary
status: complete
---

# Plan 02 Summary: Voice Orchestrator Extraction

## Files extracted and LOC

| File | LOC | Source |
|---|---|---|
| `runtime/voice/voice_client.py` | 543 | `~/iol-monorepo/packages/whisplay/voice_client.py` |
| `runtime/voice/voice_expression_controller.py` | 269 | `~/iol-monorepo/packages/whisplay/voice_expression_controller.py` |
| `runtime/voice/voice_expression_config.json` | 71 | `~/iol-monorepo/packages/whisplay/voice_expression_config.json` |
| `runtime/voice/voice_log.py` | 47 | `~/iol-monorepo/packages/whisplay/voice_log.py` |
| `runtime/voice/wake_test.py` | 51 | `~/iol-monorepo/packages/whisplay/wake_test.py` |
| `runtime/voice/rules_engine.py` | 34 | `~/iol-monorepo/packages/whisplay/rules_engine.py` |
| `runtime/voice/action_executor.py` | 49 | `~/iol-monorepo/packages/whisplay/action_executor.py` |
| `runtime/voice/requirements.txt` | 20 | authored |
| `runtime/voice/README.md` | 59 | authored |

## Sanitization changes applied

### voice_client.py
- Docstring: `Arlowe-1 Voice Client` → `Arlowe Voice Client`
- L15: deleted `sys.path.insert(0, '/home/focal55/venvs/voice/...')`, replaced with comment referencing `/opt/arlowe/venv/`
- L28: removed `sys.path.insert(0, os.path.dirname(...))` (sibling-module path hack)
- L29-37: rewired all imports to new package layout (see Imports section below)
- L40-42: `PIPER_PATH`, `PIPER_MODEL`, `VERIFIER_MODEL` rerouted to `/opt/arlowe/` and `/var/lib/arlowe/` paths
- L43-44: `RECORD_DEVICE` / `PLAY_DEVICE` left as `plughw:2,0` with TODO(phase-5) comment
- L60: `LOG_DIR` changed from source-tree-relative `./logs` to `/var/lib/arlowe/logs/voice`; `mkdir(parents=True, exist_ok=True)` added
- `fan_off()` / `fan_on()`: TODO(phase-4) comment added for sudo/polkit issue
- `iol_route(` call sites renamed to `llm_route(` (2 call sites)
- Banner string: `ARLOWE-1 VOICE CLIENT` → `ARLOWE VOICE CLIENT`

### voice_log.py
- Docstring updated to reference `/var/lib/arlowe/logs/voice/`
- `LOG_DIR` changed from source-tree-relative to `/var/lib/arlowe/logs/voice`

### wake_test.py
- Deleted `sys.path.insert(0, '/home/focal55/venvs/voice/...')`, replaced with comment

### voice_expression_controller.py
- No changes required (clean of founder literals)

## Imports rewired to new package layout

| Old import | New import |
|---|---|
| `from iol_router import route as iol_route, reset_local` | `from llm.router import route as llm_route, reset_local` |
| `from rules_engine import get_engine` | `from voice.rules_engine import get_engine` |
| `from voice_expression_controller import get_controller` | `from voice.voice_expression_controller import get_controller` |
| `from action_executor import ActionExecutor` | `from voice.action_executor import ActionExecutor` |
| `from tts_sync import TTSWithSync, TTSBackend` | `from tts.tts_sync import TTSWithSync, TTSBackend` |
| `from sentiment_classifier import Sentiment` | `from face.sentiment_classifier import Sentiment` |

## Open dependencies on other plans

- **Plan 03/03b (face)**: `from face.sentiment_classifier import Sentiment` — `runtime/face/sentiment_classifier.py` must exist for the smoke test to pass
- **Plan 04 (stt/tts)**: `from tts.tts_sync import TTSWithSync, TTSBackend` — `runtime/tts/tts_sync.py` must exist
- **Plan 05 (llm)**: `from llm.router import route as llm_route, reset_local` — `runtime/llm/router.py` must exist

All three imports are unresolvable until those plans complete. Phase 1 accepts stubs at import time; the smoke test in Plan 13 validates the full wiring.
