---
plan: 03b
status: complete
date: 2026-05-02
---

# Plan 03b Summary: sentiment_classifier + audio_sync extraction

## Files extracted

| File | LOC | Source |
|------|-----|--------|
| `runtime/face/sentiment_classifier.py` | 309 | `.dev-stash/arlowe-1/whisplay/sentiment_classifier.py` (292 LOC source) |
| `runtime/face/audio_sync.py` | 243 | `.dev-stash/arlowe-1/whisplay/audio_sync.py` (244 LOC source, verbatim) |
| `runtime/face/requirements.txt` | 17 | authored (pinned from arlowe-1 live venv + system Python) |
| `runtime/face/README.md` | 81 | authored |

## Sanitization changes

**`sentiment_classifier.py`**:
- Removed: `CONFIG_PATH = Path.home() / ".claude/workspace/whisplay-config.json"`
- Added: `CONFIG_OVERLAY = Path("/etc/arlowe/config.yml")` and `CONFIG_PATH = Path("/var/lib/arlowe/state/whisplay-config.json")`
- Updated `load_config()` to iterate over both paths (overlay first, dev fallback second), returning `DEFAULT_MAPPING` if neither exists
- Updated `save_config()` to guard against unwritable filesystem during Phase 1
- Added comment on `QWEN_URL` explaining the localhost:8001 / plan 13 dependency

**`audio_sync.py`**:
- No founder literals present in source; no sanitization required
- Block character in `print_callback` replaced with `#` (no-emoji policy)

## M6 graceful fallback verification (runtime, not just ast.parse)

Confirmed with `/etc/arlowe/config.yml` absent on dev Mac:

```
from face.sentiment_classifier import classify_sentiment, Sentiment
result = classify_sentiment('hello world', use_npu=False)
# Output: Heuristic: neutral (0.50)
# result[0] == Sentiment.NEUTRAL -- no FileNotFoundError, no traceback
```

M6 closed. Heuristic path is fully wired; NPU path degrades gracefully on timeout/error.

## Dep pinning notes

Flask and Pillow are in the system Python on arlowe-1 (not in `~/venvs/voice/`).
`sentiment_classifier.py` uses stdlib `urllib` (not `requests`); `face_service.py` uses
stdlib `http.server` (not Flask). Both are included in `requirements.txt` per plan spec
for future expansion; the pins reflect live system Python versions.

| Package | Version | Source |
|---------|---------|--------|
| Flask | 3.1.1 | arlowe-1 system Python |
| requests | 2.32.3 | arlowe-1 system Python |
| numpy | 2.3.5 | arlowe-1 `~/venvs/voice/` |
| Pillow | 11.1.0 | arlowe-1 system Python |

## Open dependency: plan 04

`tts_sync.py` (plan 04) imports `from face.audio_sync import AudioSyncAnalyzer`.
`runtime/face/audio_sync.py` is now the canonical copy. Plan 04 can proceed.

## EXTRACT-02 status

- Plan 03: `face.py`, `face_service.py` -- complete
- Plan 03b: `sentiment_classifier.py`, `audio_sync.py`, `requirements.txt`, `README.md` -- complete

EXTRACT-02 fully closed.
