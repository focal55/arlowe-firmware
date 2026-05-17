# Plan 13 test-mode systemd unit files

Canonical, reviewable source for the three `-test` user units the Phase 1 smoke
test stages onto `arlowe-1.local`. These files live in the repo so re-running
the test in a future session does not require re-deriving them.

## Install (on arlowe-1)

```bash
scp .planning/phases/01-runtime-extraction/test-units/*.service \
    arlowe-1:~/.config/systemd/user/
ssh arlowe-1 'systemctl --user daemon-reload'
```

Tear-down (done by `/tmp/arlowe-test-teardown.sh` after the smoke test) removes
the units from `~/.config/systemd/user/`.

## Bugs found and fixed during Task 4 iteration 1 (2026-05-16)

The first attempt at Task 4 (issuing `systemctl --user start`) failed two of
three units. Fixed here:

### arlowe-face-test.service

`face_service.py` uses relative imports (`from .face import ArloweeFace, State`
on line 14) since Plan 03b restructured `runtime/face/` into a package. The
script-mode invocation `/usr/bin/python3 face_service.py` fails with
`ImportError: attempted relative import with no known parent package`.

Fix: switch `ExecStart` to module mode — `/usr/bin/python3 -m face.face_service`.
`WorkingDirectory=/tmp/arlowe-runtime-test` and the existing `PYTHONPATH` make
`face` resolvable as an implicit namespace package (no `__init__.py` required
under Python 3).

### arlowe-voice-test.service

The unit set `ARLOWE_WAKE_WORD_VERIFIER=...` but `runtime/voice/voice_client.py`
line 44-46 actually reads `ARLOWE_VERIFIER_MODEL`. The unit started, the env
var existed but was never read, so `voice_client.py` fell back to the hardcoded
`/var/lib/arlowe/wake-word/verifier.pkl` (which does not exist on the test
state dir) and crashed at startup with `FileNotFoundError`.

Fix: rename the env line to `ARLOWE_VERIFIER_MODEL=...` so it matches the
source. Source remains untouched — the unit file had the wrong variable name.

### arlowe-dashboard-test.service

No bugs. Came up clean, served `http://arlowe-1.local:3001/` with `/api/health`
and `/api/voice` returning 200. Included here for completeness so all three
canonical units live in one place.

## Notes

- `whisper-stt` and `qwen-*` are NOT in this set. They are reused from the live
  stack. See `docs/operations/phase-1-smoke-test.md` "Scope and limits" for the
  M1 rationale.
- The voice-test unit specifies `After=` + `Wants=` for face and dashboard, so
  starting voice last brings the others up automatically if they aren't already
  running. The smoke-test commands in the doc still start them explicitly in
  dependency order for clarity in the operator log.
