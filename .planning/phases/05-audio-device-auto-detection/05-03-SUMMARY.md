# 05-03 Summary: bash CLI audio device wiring

**Completed:** 2026-06-13
**PR:** feat/05-03-cli-audio-wiring (Closes #90)

---

## What changed

Three operator CLI helpers in `runtime/cli/` now resolve their ALSA device at
invocation via the `arlowe_audio` CLI (05-01), instead of hardcoding `plughw:2,0`.

- `record` — capture from resolved device (`--resolve-capture`)
- `stt` — capture from resolved device (`--resolve-capture`)
- `speak` — playback to resolved device (`--resolve-playback`)

---

## Env-var contract

| Variable            | Used by        | Purpose                                          |
|---------------------|----------------|--------------------------------------------------|
| `ARLOWE_ALSA_DEVICE`| record, stt    | Override capture device; skips resolver entirely |
| `ARLOWE_PLAY_DEVICE`| speak          | Override playback device; skips resolver entirely|
| `ARLOWE_LIB`        | all three      | Path to runtime/lib; defaults to /opt/arlowe/runtime/lib |

Capture and playback env vars are kept distinct (no shared variable), consistent
with the split in 05-02.

---

## Resolution pattern

Each script uses the same three-tier pattern:

```bash
ARLOWE_LIB="${ARLOWE_LIB:-/opt/arlowe/runtime/lib}"
CAPTURE_DEV="${ARLOWE_ALSA_DEVICE:-$(PYTHONPATH="$ARLOWE_LIB" python3 -m arlowe_audio --resolve-capture 2>/dev/null)}"
CAPTURE_DEV="${CAPTURE_DEV:-plughw:2,0}"
```

Priority:
1. Explicit env override (`ARLOWE_ALSA_DEVICE` / `ARLOWE_PLAY_DEVICE`)
2. `arlowe_audio` CLI resolution (reads `/proc/asound`, honors `/etc/arlowe/config.yml` override)
3. Literal `plughw:2,0` fallback — degrades gracefully rather than failing hard

---

## PYTHONPATH shim

The bash scripts reach the lib via `PYTHONPATH="$ARLOWE_LIB"` in the command
substitution. This avoids installing `arlowe_audio` as a system package and
mirrors how the Python services are invoked. `ARLOWE_LIB` defaults to
`/opt/arlowe/runtime/lib` (the production install path from 04-02).

---

## Preserved flags

Each script's existing format flags are untouched:
- `record`: `-c 2` (stereo)
- `stt`: `-c 1` (mono)

The channel difference is pre-existing and intentional; 05-03 only touches the
device argument.
