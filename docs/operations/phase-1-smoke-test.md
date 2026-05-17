# Phase 1 Smoke Test — Procedure and Run Log

> **Status:** prepared 2026-05-10 by Plan 13 prep work (`docs/state-and-smoke-test-runbook` PR). Observed-run section to be filled by Joe after Task 4 executes on arlowe-1.

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

Write these to `/tmp/arlowe-runtime-test/systemd-test/` on arlowe-1 (Task 3 of Plan 13 should template these into the runtime tree before rsync, or write them inline below).

**`arlowe-voice-test.service`**
```ini
[Unit]
Description=Arlowe voice orchestrator (test mode)
After=arlowe-face-test.service arlowe-dashboard-test.service

[Service]
Type=simple
Environment=PYTHONPATH=/tmp/arlowe-runtime-test
Environment=ARLOWE_WAKE_WORD_VERIFIER=/tmp/arlowe-test-state/wake-word/verifier.pkl
Environment=ARLOWE_LOGS_DIR=/tmp/arlowe-test-state/logs
Environment=ARLOWE_ALSA_DEVICE=plughw:2,0
ExecStart=%h/venvs/voice/bin/python /tmp/arlowe-runtime-test/voice/voice_client.py
Restart=no

[Install]
WantedBy=default.target
```

**`arlowe-face-test.service`**
```ini
[Unit]
Description=Arlowe face service (test mode)

[Service]
Type=simple
Environment=PYTHONPATH=/tmp/arlowe-runtime-test
Environment=ARLOWE_WHISPLAY_DRIVER_PATH=%h/Library/Whisplay/Driver
ExecStart=/usr/bin/python3 /tmp/arlowe-runtime-test/face/face_service.py
Restart=no

[Install]
WantedBy=default.target
```

**`arlowe-dashboard-test.service`**
```ini
[Unit]
Description=Arlowe dashboard (test mode, port 3001)

[Service]
Type=simple
Environment=PORT=3001
Environment=ARLOWE_CONFIG_PATH=/tmp/arlowe-test-state/config.yml
Environment=ARLOWE_LOGS_DIR=/tmp/arlowe-test-state/logs
Environment=ARLOWE_SYSTEMCTL_MODE=user
WorkingDirectory=/tmp/arlowe-runtime-test/dashboard
ExecStart=/usr/bin/pnpm dev
Restart=no

[Install]
WantedBy=default.target
```

Note: `whisper-stt` and `qwen-*` are NOT included. Those continue to run from the live stack. This is the M1 scope limit.

## Smoke-test commands

```bash
# Start in dependency order: face + dashboard first, then voice
ssh arlowe-1 'systemctl --user daemon-reload && \
              systemctl --user start arlowe-face-test arlowe-dashboard-test && \
              sleep 3 && \
              systemctl --user start arlowe-voice-test'

# Verify all three are active
ssh arlowe-1 'systemctl --user is-active arlowe-{face,dashboard,voice}-test'
# Expect: three "active" lines.

# Tail voice logs in a second terminal
ssh arlowe-1 'journalctl --user -u arlowe-voice-test -f'
# Expect: "ARLOWE VOICE CLIENT" banner, wake-word model load, mic listen.

# Walk to the Pi and speak clearly:
#   "Hey Arlowe, what's two plus two?"
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

# Confirm live units still active
ssh arlowe-1 'systemctl --user is-active arlowe-{voice,face,dashboard} 2>/dev/null || true; \
              systemctl is-active whisper-stt qwen-tokenizer qwen-api 2>/dev/null || true'
# Expect: live units still "active". If anything flipped to "failed", investigate before declaring tear-down clean.
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
