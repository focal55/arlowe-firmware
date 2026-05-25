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

## Bugs found and fixed during Task 4 iteration 2 (2026-05-17)

The second Task 4 attempt (after iteration-1 fixes) revealed a third unit-file
bug on face-test. Iteration-2 also confirmed (by elimination) that voice-test
was failing on mic contention, not a unit-file bug.

### arlowe-face-test.service (env-var fix)

`runtime/face/face.py:19-25` honours `ARLOWE_WHISPLAY_DRIVER_PATH` and defaults
to `/opt/arlowe/third_party/whisplay-driver` — the Phase-6 vendored location
that does not yet exist on `arlowe-1`. The founder's WhisPlay driver actually
lives at `/home/focal55/Library/Whisplay/Driver/WhisPlay.py` (single file). The
old `sys.path.insert(0, '/home/focal55/Library/Whisplay/Driver')` hack was
deliberately removed in Plan 03b as a banned-literal target for Phase 2.

The unit file did not set the env var, so the import resolved nowhere and
crashed with `ModuleNotFoundError: No module named 'WhisPlay'`.

Fix: add `Environment=ARLOWE_WHISPLAY_DRIVER_PATH=/home/focal55/Library/Whisplay/Driver`
to the unit. Source untouched — the banned literal stays out of `runtime/`.

### arlowe-voice-test.service

No unit-file bug. The failure was mic contention with the live `arlowe-voice`
unit, which had been left running during the first retry. See
`docs/operations/phase-1-smoke-test.md` "Mic contention caveat" — the Task 4
procedure now explicitly stops live voice before starting test voice.

## Hardware contention surfaced during iteration-2 verify-start (2026-05-17)

After the env-var fix above, starting `arlowe-face-test` while the live
`arlowe-face` unit was still running surfaced an identical-shape problem to
voice-test's mic contention:

1. `OSError: [Errno 98] Address already in use` — `face_service.py:179`
   hardcodes the HTTP control-server port to 8080. Live face owns it.
2. `lgpio.error: 'GPIO not allocated'` — both processes try to claim the
   Whisplay SPI/GPIO pins (DC, RST, LED).

This is not a unit-file bug — it's parallel-hardware-resource contention. The
Task 4 procedure now stops **both** live voice and live face before starting
their test counterparts (and restarts both during tear-down). Live face was
unaffected by the failed test start (PID unchanged, 0 restarts, journal quiet).

A future hardening: the face control-server port could honour an env-var
override so a parallel test could bind 8081 instead of 8080. Out of plan-13
scope (tracked as a Phase 2 sanitization / Phase 5 image-build candidate).

## Notes

- `whisper-stt` and `qwen-*` are NOT in this set. They are reused from the live
  stack. See `docs/operations/phase-1-smoke-test.md` "Scope and limits" for the
  M1 rationale.
- The voice-test unit specifies `After=` + `Wants=` for face and dashboard, so
  starting voice last brings the others up automatically if they aren't already
  running. The smoke-test commands in the doc still start them explicitly in
  dependency order for clarity in the operator log.
