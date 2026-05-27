# runtime/face

Face HTTP service and sentiment classifier for Arlowe.

`face_service.py` exposes a TCP/8080 HTTP control interface. `face.py` renders
animated facial expressions to the WhisPlay display hardware. `sentiment_classifier.py`
maps incoming text to a face state, with an NPU path (Qwen via localhost:8001) and a
heuristic fallback that operates without any external service. `audio_sync.py` provides
real-time amplitude analysis for lip-sync during TTS playback; `tts_sync.py` (plan 04)
imports from this module via `from face.audio_sync import AudioSyncAnalyzer`.

## Endpoints (tcp/8080)

| Method  | Path                       | Purpose                                                          |
|---------|----------------------------|------------------------------------------------------------------|
| GET     | `/`                        | HTML control panel (browser UI)                                  |
| GET     | `/status`                  | JSON: current state, running flag, source indicator              |
| POST    | `/state`                   | Set face state; body: `{"state": "<name>", "bg": "...", "source": "..."}` |
| POST    | `/mouth`                   | Real-time mouth position for TTS lip-sync; body: `{"open": 0.0}` |
| POST    | `/discord`                 | Discord activity events; body: `{"activity": "message|thinking|idle"}` |
| POST    | `/bg`                      | Set background mode; body: `{"mode": "<name>"}`                  |
| POST    | `/voice-expression/reload` | Signal config reload (config re-read on next use)                |
| OPTIONS | `*`                        | CORS preflight                                                   |

Valid state names: `idle`, `thinking`, `listening`, `talking`, `sleeping`, `happy`,
`sad`, `excited`, `confused`.

## WhisPlay driver dependency

`face.py` imports `WhisPlayBoard` from the WhisPlay vendor SDK. The face service
will not render to the display without this driver installed system-wide.

See `third_party/whisplay-driver/PROVENANCE.md` for driver source, license, and
installation instructions. The driver is a vendor-supplied Python module that ships
with the WhisPlay display hardware -- it is not available via pip.

On a dev Pi today the driver typically lives at `~/Library/Whisplay/Driver/WhisPlay.py`
(system-wide install). Image-build (Phase 11) will bake it into `/opt/arlowe/`.

## Sentiment classifier behaviour

1. On incoming text, `sentiment_classifier.py` first tries `localhost:8001/v1/chat/completions`
   (the Qwen OpenAI-compat shim). As of Phase 1, this endpoint is broken in the Phase 1 baseline
   (see research notes / plan 13 for the qwen-openai resolution). The NPU path times
   out and falls through to the heuristic.

2. On HTTP error or timeout, `classify_sentiment_heuristic()` runs a keyword-count
   fallback that returns `POSITIVE`, `NEGATIVE`, or `NEUTRAL` without any network call.
   The face service degrades gracefully -- expression selection still works.

3. Config load order: `/etc/arlowe/config.yml` (Phase 4 pairing overlay), then
   `/var/lib/arlowe/state/whisplay-config.json` (dev fallback). If neither exists
   (Phase 1 / not-yet-paired state), `DEFAULT_MAPPING` is used silently -- no error,
   no exception.

Phase 1 smoke test passes via the heuristic path. The NPU path is not required for
the Phase 1 success criterion.

## Running locally on a Pi 5 dev unit

```bash
cd /path/to/runtime
PYTHONPATH=. python3 face/face_service.py
```

The WhisPlay driver must be importable. If it is installed system-wide (`/usr/lib/python3/...`
or via `sys.path` as the vendor ships it), no extra `PYTHONPATH` manipulation is needed.

## Known limitations

- **NPU sentiment path broken (Phase 1)**: `qwen-openai.service` is in a restart loop
  on the current dev unit. Sentiment always falls through to the heuristic. Tracked in
  plan 13 (qwen-openai resolution). Heuristic path is sufficient for Phase 1.

- **WhisPlay driver provenance unresolved at Phase 1 start**: Driver source and license
  were unknown at the start of Phase 1. Resolved in plan 03's Task 2. See
  `third_party/whisplay-driver/PROVENANCE.md`.

- **Config overlay not wired (Phase 1)**: `/etc/arlowe/config.yml` is the Phase 4
  pairing overlay. During Phase 1 it does not exist; the classifier falls back to
  `DEFAULT_MAPPING`. This is expected and documented.
