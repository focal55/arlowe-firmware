# Plan 03 Summary: face.py + face_service.py extraction

**Completed:** 2026-05-02
**Branch:** feat/plan-03-face-extract
**PR:** closes #3

---

## Files extracted

| File | LOC | Source |
|---|---|---|
| `runtime/face/face.py` | 636 | `.dev-stash/arlowe-1/whisplay/face.py` (667 LOC stash) |
| `runtime/face/face_service.py` | 199 | `.dev-stash/arlowe-1/whisplay/face_service.py` (203 LOC stash) |
| `third_party/whisplay-driver/PROVENANCE.md` | 94 | Authored (new) |

---

## Sanitization changes

### `runtime/face/face.py`

- **L15-16 (driver loader):** replaced hardcoded `sys.path.insert(0, '/home/focal55/Library/Whisplay/Driver')` with an env-overridable loader block:
  ```python
  _WHISPLAY_DRIVER_PATH = os.environ.get(
      "ARLOWE_WHISPLAY_DRIVER_PATH",
      "/opt/arlowe/third_party/whisplay-driver",
  )
  if _WHISPLAY_DRIVER_PATH not in sys.path:
      sys.path.insert(0, _WHISPLAY_DRIVER_PATH)
  ```
- **L609 (`run` method banner):** removed `Arlowe-1` from the startup print string — changed to `"Arlowe face starting"`.
- **Comments:** removed emoji references and `arlowe-1` device-name literal from inline comments.
- No other `/home/focal55` literals were present in `face.py`.

### `runtime/face/face_service.py`

- **L14 (import):** rewrote `from face import ArloweeFace, State` to `from .face import ArloweeFace, State` (relative import, consistent with package layout).
- **HTML title (L138):** changed `<title>Arlowe-1 Face Control</title>` to `<title>Arlowe Face Control</title>`.
- **HTML h1 (L152):** removed `🏠` emoji from the heading.
- No `/home/focal55` literals were present in `face_service.py`.

---

## WhisPlay driver provenance findings

Research Q2 / R3 is **resolved**:

- **Vendor:** PiSugar (pisugar.com)
- **GitHub:** https://github.com/PiSugar/Whisplay
- **License:** Apache License, Version 2.0 (permissive; redistribution allowed with attribution)
- **Python import needed:** `WhisPlay.py` only (`RPi.GPIO` and `spidev` via pip)
- **Audio HAT:** Waveshare WM8960 driver, bundled in the Whisplay repo, installed as a kernel module via `install_wm8960_drive.sh` — not a Python import

**Vendoring decision:** Option (a) — vendor `WhisPlay.py` under `third_party/whisplay-driver/`. Apache 2.0 permits this. The actual `WhisPlay.py` copy + `LICENSE` + attribution `README.md` are a Phase 6 (image build) follow-on task, not a Phase 1 blocker. See `third_party/whisplay-driver/PROVENANCE.md` for full detail.

**Phase 1 smoke test:** unaffected. The driver is already installed on arlowe-1 at `~/Library/Whisplay/Driver/`. Set `ARLOWE_WHISPLAY_DRIVER_PATH` to that path for dev use.

---

## Open dependency on plan 03b

Plan 03 covers the face rendering primitives (`face.py`, `face_service.py`). Plan 03b lands:
- `runtime/face/sentiment_classifier.py`
- `runtime/face/audio_sync.py`
- `runtime/face/requirements.txt`
- `runtime/face/README.md`

Both `sentiment_classifier.py` and `audio_sync.py` are already present in the `.dev-stash` and will be sanitized (primarily: `QWEN_URL` localhost endpoint and `~/.claude/workspace/whisplay-config.json` config path). Plan 03b is independent of plan 03 and can land in any order.
