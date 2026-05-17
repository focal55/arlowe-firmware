# Phase 1 Smoke Test — Procedure and Run Log

> **Status:** prepared 2026-05-10; staged on arlowe-1 2026-05-16 by Plan 13 Task 3 (`plan-13/smoke-test` branch). `/tmp/arlowe-runtime-test/` populated, three `-test` user units installed (inactive after the Task 3 bug-fix iterations), founder verifier symlinked into `/tmp/arlowe-test-state/wake-word/verifier.pkl`, tear-down script at `/tmp/arlowe-test-teardown.sh`. Observed-run section to be filled by Joe after Task 4 executes.

## Task 3 bug-fix iteration (2026-05-16)

The first Task 4 attempt (issuing `systemctl --user start` for the three units) revealed two unit-file bugs that had to be patched before retry. Recording here so future re-runs of Plan 13 do not repeat them. Canonical, corrected unit-file source lives at `.planning/phases/01-runtime-extraction/test-units/` in the repo.

| Unit | Initial state | Root cause | Fix |
|---|---|---|---|
| `arlowe-dashboard-test` | active, serving `http://arlowe-1.local:3001/`, `/api/health` + `/api/voice` returning 200 | none | none |
| `arlowe-face-test` | failed with `ImportError: attempted relative import with no known parent package` | `face_service.py` uses `from .face import ArloweeFace, State` (Plan 03b restructured `runtime/face/` into a package). `ExecStart=/usr/bin/python3 .../face_service.py` invokes it as a top-level script with no package context. | Switch to module mode: `ExecStart=/usr/bin/python3 -m face.face_service`. `WorkingDirectory=/tmp/arlowe-runtime-test` and the existing `PYTHONPATH` make `face` resolvable as an implicit namespace package (no `__init__.py` needed under Python 3). |
| `arlowe-voice-test` | failed with `FileNotFoundError: '/var/lib/arlowe/wake-word/verifier.pkl'` | Unit set `Environment=ARLOWE_WAKE_WORD_VERIFIER=...` but `runtime/voice/voice_client.py` line 44-46 reads `ARLOWE_VERIFIER_MODEL`. The variable was set in the env but never read, so the fallback hardcoded path was used and crashed. | Rename the env line to `ARLOWE_VERIFIER_MODEL=/tmp/arlowe-test-state/wake-word/verifier.pkl`. Source untouched — the unit file had the wrong variable name. |

Both fixes are in the canonical unit files in `.planning/phases/01-runtime-extraction/test-units/`. To re-deploy after edits:

```bash
scp .planning/phases/01-runtime-extraction/test-units/*.service \
    arlowe-1:~/.config/systemd/user/
ssh arlowe-1 'systemctl --user daemon-reload && \
              systemctl --user reset-failed arlowe-face-test arlowe-voice-test 2>/dev/null || true'
```

After the fix, all three units come up `inactive` and the dashboard-test remains `active` (it was never stopped).

## Task 3 bug-fix iteration 2 (2026-05-17)

The second Task 4 attempt (after iteration 1's fixes) was run with the live `arlowe-voice` unit still active. Voice-test failed on mic contention (expected — caveat already in this doc) and face-test failed on a third bug. Direct invocation gave a clean traceback. Recording here so the third try doesn't repeat it.

| Unit | Failure | Root cause | Fix |
|---|---|---|---|
| `arlowe-face-test` | `ModuleNotFoundError: No module named 'WhisPlay'` | `runtime/face/face.py:19-25` honours `ARLOWE_WHISPLAY_DRIVER_PATH` env var, defaulting to `/opt/arlowe/third_party/whisplay-driver` (the Phase-6 vendored location, not yet populated on arlowe-1). The founder's driver lives at `/home/focal55/Library/Whisplay/Driver/WhisPlay.py`. The unit didn't set the env var so the import resolved nowhere. | Add `Environment=ARLOWE_WHISPLAY_DRIVER_PATH=/home/focal55/Library/Whisplay/Driver` to `arlowe-face-test.service`. Source untouched — banned-literal hack stays out of the runtime tree per Phase 2 sanitization. |
| `arlowe-voice-test` | mic contention with live `arlowe-voice` | Both units open the same ALSA capture device. Already covered by the "Mic contention caveat" below; not a unit-file bug. | Procedural: stop live voice before starting test voice. Restart live voice during tear-down. |

Verified post-fix on 2026-05-17: `ssh arlowe-1 'PYTHONPATH=/home/focal55/Library/Whisplay/Driver /usr/bin/python3 -c "import WhisPlay; print(WhisPlay.__file__)"'` returns `/home/focal55/Library/Whisplay/Driver/WhisPlay.py`. After redeploying the corrected unit file the WhisPlay import resolved cleanly — the next traceback hit a different problem (face-port + GPIO contention with live `arlowe-face`, see iteration 3 below) which proves the env-var fix works.

## Task 3 bug-fix iteration 3 (2026-05-17, surfaced during iteration-2 verify-start)

After iteration 2 deployed the WhisPlay env var, starting `arlowe-face-test` with the live `arlowe-face` unit still active surfaced a hardware/port contention identical in shape to the voice-test mic contention.

| Symptom | Root cause | Fix |
|---|---|---|
| `OSError: [Errno 98] Address already in use` on port 8080 | `runtime/face/face_service.py:179` hardcodes the control-server port to 8080. Live face (PID 63316) owns the port. | Procedural: stop live `arlowe-face` before starting test face. Restart during tear-down. Future: optional env-var override for the port (deferred — out of plan-13 scope; tracked as Phase 2 sanitization candidate or Phase 5 image-build cleanup). |
| `lgpio.error: 'GPIO not allocated'` during `WhisPlayBoard.__init__` | Live face holds the Whisplay SPI/GPIO pins (DC, RST, LED). Two processes cannot both claim them. | Procedural: same as port contention — stop live face first. |

Live `arlowe-face` was unaffected by the failed start (PID 63316 unchanged, 0 restarts, journal quiet). The contention is fail-fast on the test process, not a degradation of live. Joe's "live face MUST continue showing what it shows" guardrail held.

**Net of iterations 2 + 3:** the test-units themselves are now correct. Remaining Task-4 work is purely procedural — Joe must stop **both** live voice and live face before starting their test counterparts, and restart both during tear-down.

## Scope and limits (READ FIRST)

This smoke test verifies that the Phase 1 `runtime/` tree can drive a wake → STT → LLM → TTS → face round trip on the dev unit (`arlowe-1.local`). It is **NOT** a fully-sanitized first-flash integration test.

Specifically:

- The test runs on `arlowe-1` alongside the live working services. The dev unit is the founder's daily driver, not a freshly-flashed Pi.
- The test reuses the live `whisper-stt` service and the live `qwen-{tokenizer,api,openai}` services. Only the orchestrator (voice), face, and dashboard run from the new `runtime/` tree.
- The founder's `~/wake_word/hey_arlowe_verifier.pkl` is symlinked from outside the repo so the wake-word stage has something to verify against. The `.pkl` never enters the repo.

The fully-sanitized first-flash test — factory-fresh Pi 5 + AX + Whisplay flashed from a clean image, paired as a fake owner, with no founder identity present anywhere on disk — ships in **Phase 12** per `ROADMAP.md` success criteria.

Phase 1 success criterion 4 from `ROADMAP.md` ("voice orchestrator on a sanitized Pi 5 dev unit runs the wake → STT → LLM → TTS → face flow end-to-end at least once, manual smoke test, not yet CI-gated") is interpreted by this plan as: **the orchestrator + face + dashboard run from the new tree on the dev unit, end-to-end, while the live STT/LLM services serve the request.** The fully-sanitized variant ships in Phase 12.

## openai_wrapper.py resolution

ADR-0001 left this open at extraction time. Plan 13 Task 1 picks one of three paths:

| Option | Effort | Risk | Recommendation |
|---|---|---|---|
| 1 | Recover `openai_wrapper.py` from git history (or write fresh) | Medium — git archeology, ~50 LOC if writing fresh | Use only if recovery succeeds; per M2, do NOT write a fresh shim from research notes |
| **2** | **Point router at ax-llm native `:8000` directly; remove the wrapper** | **Low — one URL change in `router.py`** | **RECOMMENDED — verified live: `curl http://localhost:8000/v1/models` returns ok** |
| 3 | Skip in Phase 1, force-route to cloud for smoke test | Lowest immediate effort, but pushes the unknown into a later phase | Avoid; the "no internet round-trip in default path" v1 promise goes unexercised |

**Decision required from Joe before running Task 2.** Default if no override: option-2 per Plan 13's recommendation. The conditional auto-fallback rule (M2) says: if option-1 is attempted and git recovery fails, the executor MUST auto-fall to option-2 and record the fallback in ADR-0001 — do not invent a shim from research notes.

## Prerequisites

Run these on the Mac before staging the runtime to arlowe-1.

```bash
# Confirm ax-llm submodule is initialized
git -C third_party/ax-llm rev-parse HEAD

# Confirm axcl manifest is in tree
test -f third_party/axcl/manifest.yml

# Confirm ADR-0002 landed (Plan 12 dependency)
test -f docs/architecture/0002-arlowe-scheduled-summary-stripped.md

# Confirm PyYAML is installed in arlowe-1's voice venv (M5; Plan 04 dependency)
ssh arlowe-1 '~/venvs/voice/bin/python -c "import yaml; print(\"PyYAML\", yaml.__version__)"' \
  || ssh arlowe-1 '~/venvs/voice/bin/pip install PyYAML'

# Re-verify after install if it ran
ssh arlowe-1 '~/venvs/voice/bin/python -c "import yaml"'
```

All four commands must succeed before proceeding.

## Setup — stage runtime on arlowe-1

The test does NOT touch `/opt/arlowe/`. It stages to `/tmp/arlowe-runtime-test/` and uses `--user` systemd units suffixed `-test`.

```bash
# 1. Push the new runtime/ tree to arlowe-1 (path is intentionally outside /opt/arlowe/)
rsync -av --delete \
  --exclude='node_modules/' --exclude='.next/' --exclude='__pycache__/' \
  runtime/ arlowe-1:/tmp/arlowe-runtime-test/

# 2. Symlink the founder verifier .pkl into the test runtime's expected location
#    (.pkl never enters the repo; this symlink lives only on arlowe-1)
ssh arlowe-1 'mkdir -p /tmp/arlowe-test-state/wake-word && \
              ln -sf $HOME/wake_word/hey_arlowe_verifier.pkl \
                     /tmp/arlowe-test-state/wake-word/verifier.pkl'

# 3. Author parallel -test systemd --user units under /tmp/arlowe-runtime-test/systemd-test/
#    See "Test unit files" section below for the actual systemd contents.

# 4. Install + reload
ssh arlowe-1 'mkdir -p ~/.config/systemd/user && \
              cp /tmp/arlowe-runtime-test/systemd-test/*.service ~/.config/systemd/user/ && \
              systemctl --user daemon-reload'
```

## Test unit files

Canonical source for the three `-test` units lives at `.planning/phases/01-runtime-extraction/test-units/` in the repo. Deploy them with:

```bash
scp .planning/phases/01-runtime-extraction/test-units/*.service \
    arlowe-1:~/.config/systemd/user/
ssh arlowe-1 'systemctl --user daemon-reload'
```

The files at the time of writing (post Task-3 bug-fix iteration):

**`arlowe-voice-test.service`**
```ini
[Unit]
Description=Arlowe voice orchestrator (test mode, plan-13 smoke test)
After=arlowe-face-test.service arlowe-dashboard-test.service
Wants=arlowe-face-test.service arlowe-dashboard-test.service

[Service]
Type=simple
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONPATH=/tmp/arlowe-runtime-test:/home/focal55/venvs/voice/lib/python3.13/site-packages
Environment=ARLOWE_VERIFIER_MODEL=/tmp/arlowe-test-state/wake-word/verifier.pkl
Environment=ARLOWE_LOGS_DIR=/tmp/arlowe-test-state/logs
Environment=ARLOWE_STATE_DIR=/tmp/arlowe-test-state
ExecStart=/usr/bin/python3 /tmp/arlowe-runtime-test/voice/voice_client.py
Restart=no

[Install]
WantedBy=default.target
```

**`arlowe-face-test.service`**
```ini
[Unit]
Description=Arlowe face service (test mode, plan-13 smoke test)
After=network.target

[Service]
Type=simple
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONPATH=/tmp/arlowe-runtime-test:/home/focal55/venvs/voice/lib/python3.13/site-packages
Environment=ARLOWE_LOGS_DIR=/tmp/arlowe-test-state/logs
Environment=ARLOWE_STATE_DIR=/tmp/arlowe-test-state
Environment=ARLOWE_WHISPLAY_DRIVER_PATH=/home/focal55/Library/Whisplay/Driver
WorkingDirectory=/tmp/arlowe-runtime-test
ExecStart=/usr/bin/python3 -m face.face_service
Restart=no

[Install]
WantedBy=default.target
```

**`arlowe-dashboard-test.service`**
```ini
[Unit]
Description=Arlowe dashboard (test mode, port 3001, plan-13 smoke test)
After=network.target

[Service]
Type=simple
WorkingDirectory=/tmp/arlowe-runtime-test/dashboard
Environment=NODE_ENV=development
Environment=PORT=3001
Environment=ARLOWE_CONFIG_PATH=/tmp/arlowe-test-state/config.yml
Environment=ARLOWE_LOGS_DIR=/tmp/arlowe-test-state/logs
Environment=ARLOWE_SYSTEMCTL_MODE=user
ExecStart=/bin/bash -c 'cd /tmp/arlowe-runtime-test/dashboard && /home/focal55/.npm-global/bin/pnpm dev -p 3001 -H 0.0.0.0'
Restart=no

[Install]
WantedBy=default.target
```

Note: `whisper-stt` and `qwen-*` are NOT included. Those continue to run from the live stack. This is the M1 scope limit.

> **Mic contention caveat (discovered 2026-05-16 during Task 4 retry prep):** the live `arlowe-voice` service was active during the first Task 4 attempt. Both `arlowe-voice` and `arlowe-voice-test` try to open the same ALSA capture device, so running them concurrently is expected to fail (mic device busy or wake-word miss). The Task 4 procedure now explicitly pauses the live voice unit before starting the test unit and restarts it during tear-down.

> **Face contention caveat (discovered 2026-05-17 during iteration-2 verify-start):** identical-shape problem for face. Both `arlowe-face` and `arlowe-face-test` try to (a) bind port 8080 for the face control server and (b) acquire the same Whisplay SPI/GPIO pins. Running them concurrently fails fast on the test process (live face is unaffected). The Task 4 procedure pauses live `arlowe-face` before starting test face and restarts it during tear-down. Same procedural rule as voice.

## Smoke-test commands

```bash
# 0. Stop the live voice + face units to release the mic, Whisplay GPIO, and
#    face control port 8080. ONLY do this once Joe is physically at the Pi and
#    ready to run the test — the live units are his daily driver.
ssh arlowe-1 'systemctl --user stop arlowe-voice arlowe-face'

# 1. Start the test units in dependency order: face + dashboard first, then voice
ssh arlowe-1 'systemctl --user daemon-reload && \
              systemctl --user start arlowe-face-test arlowe-dashboard-test && \
              sleep 3 && \
              systemctl --user start arlowe-voice-test'

# 2. Verify all three are active
ssh arlowe-1 'systemctl --user is-active arlowe-{face,dashboard,voice}-test'
# Expect: three "active" lines.

# 3. Tail voice logs in a second terminal
ssh arlowe-1 'journalctl --user -u arlowe-voice-test -f'
# Expect: "ARLOWE VOICE CLIENT" banner, wake-word model load, mic listen.

# 4. Walk to the Pi and speak clearly:
#      "Hey Arlowe, what's two plus two?"
```

## Expected outputs

| Stage | Observable | Where to see it |
|---|---|---|
| Wake | Pink flash on Whisplay face | The Pi |
| Listening | Face transitions to "listening" expression | The Pi |
| 5s record window | Mic captures audio | journalctl voice |
| STT | Transcript appears (close to "what's two plus two") | journalctl voice |
| LLM call | Option-2: POST to `http://localhost:8000/api/chat` (ax-llm native; see ADR-0001 for the post-PR-52 endpoint refinement). Option-3: cloud Claude. | journalctl voice |
| LLM response | Reply text in logs | journalctl voice |
| Talking | Face transitions to "talking-blue" | The Pi |
| TTS | Piper synthesizes; lip-sync animates | The Pi (audio + face) |
| Idle | Face returns to idle | The Pi |

Round-trip target: under 5 seconds total wake-to-speech.

Dashboard check (open `http://arlowe-1.local:3001/` in Mac browser):

- Homepage renders without errors
- `/api/health` returns sane JSON
- `/api/voice` shows `arlowe-voice-test` as active (with `ARLOWE_SYSTEMCTL_MODE=user`)
- `/api/logs` does NOT 500; shows journalctl output

## Tear-down

**Run regardless of outcome.** The test must not leave anything behind that affects the live stack.

```bash
# Stop and disable test units
ssh arlowe-1 'systemctl --user stop arlowe-voice-test arlowe-face-test arlowe-dashboard-test 2>/dev/null; \
              systemctl --user disable arlowe-voice-test arlowe-face-test arlowe-dashboard-test 2>/dev/null; \
              rm -f ~/.config/systemd/user/arlowe-{voice,face,dashboard}-test.service; \
              systemctl --user daemon-reload'

# Remove staged tree and test state
ssh arlowe-1 'rm -rf /tmp/arlowe-runtime-test /tmp/arlowe-test-state'

# Restart the live voice + face units (both were stopped at step 0 to release
# mic, Whisplay GPIO, and port 8080)
ssh arlowe-1 'systemctl --user start arlowe-face arlowe-voice'

# Confirm live units active again
ssh arlowe-1 'systemctl --user is-active arlowe-{voice,face,dashboard} whisper-stt qwen-tokenizer qwen-api 2>/dev/null || true'
# Expect: live units "active". If anything is "failed" or "inactive", investigate before declaring tear-down clean.
```

## Observed run

> **Section to be filled in after Task 4 runs.** Template below.

```markdown
### Observed run — 2026-XX-XX

Performed by: Joe Ybarra
Host: arlowe-1.local
openai_wrapper resolution: option-X (per ADR-0001)

#### Wake → STT → LLM → TTS → face

| Step | Observed | Notes |
|---|---|---|
| Wake phrase spoken | "Hey Arlowe, what's two plus two?" | |
| Pink wake flash | ? | |
| Listening face | ? | |
| STT transcript | (paste from logs) | |
| LLM route | local :8000 (option-2) / cloud (option-3) | |
| LLM response | (paste from logs) | |
| Talking-blue face | ? | |
| Piper speech with lip-sync | ? | |
| Face returns to idle | ? | |
| Round-trip time | ~?s | |

#### Tear-down verified

| Check | Result |
|---|---|
| Test units stopped | ? |
| Live units still active | ? |
| Test dirs cleaned | ? |

#### Anomalies / open issues

- (anything weird; expected empty if option-2 worked)

#### Phase 1 success criterion 4 — qualified result

ROADMAP.md success criterion 4 reads: "The voice orchestrator on a sanitized Pi 5 dev unit runs the wake → STT → LLM → TTS → face flow end-to-end at least once (manual smoke test, not yet CI-gated)."

This plan interprets that as: orchestrator + face + dashboard from the new `runtime/` tree, on the dev unit, running end-to-end while the live STT/LLM services serve the request. The fully-sanitized first-flash variant ships in Phase 12.

**Result for the qualified Phase-1 reading:** PASSED / PASSED-WITH-NOTES / FAILED
**Phase-12 deferred work:** fully-sanitized first-flash integration.
```

## What unblocks after this lands

- Issue #15 closes (Phase 1 Plan 13 verifier ticket).
- `.planning/STATE.md` flips Phase 1 status to COMPLETE.
- Phase 2 (Sanitization gate) unblocks. Run `/gsd:discuss-phase 2` to start.
