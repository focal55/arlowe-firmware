---
phase: 01-runtime-extraction
plan: 02
type: execute
wave: 2
depends_on: ["01"]
files_modified:
  - runtime/voice/voice_client.py
  - runtime/voice/voice_expression_controller.py
  - runtime/voice/voice_expression_config.json
  - runtime/voice/voice_log.py
  - runtime/voice/wake_test.py
  - runtime/voice/rules_engine.py
  - runtime/voice/action_executor.py
  - runtime/voice/requirements.txt
  - runtime/voice/README.md
  - .planning/phases/01-runtime-extraction/01-02-SUMMARY.md
autonomous: true

requirements:
  - "EXTRACT-01: voice_client.py extracts to runtime/voice/; retains wake → STT → LLM → TTS → face orchestration"

must_haves:
  truths:
    - "runtime/voice/voice_client.py exists and is the orchestrator referenced by EXTRACT-01"
    - "voice_client.py imports resolve cleanly within runtime/{voice,llm,tts,face}/ — no `~/iol-monorepo` paths"
    - "Hardcoded `/home/focal55/...` venv injection is removed; deps come from runtime/voice/requirements.txt"
    - "LOG_DIR points at /var/lib/arlowe/logs/ (not source-tree-relative)"
    - "PIPER_PATH and VERIFIER_MODEL paths reroute under /opt/arlowe/ or /var/lib/arlowe/"
  artifacts:
    - path: "runtime/voice/voice_client.py"
      provides: "Wake → STT → LLM → TTS → face orchestrator"
      min_lines: 400
      contains: "openwakeword"
    - path: "runtime/voice/voice_expression_controller.py"
      provides: "Voice expression FSM"
      min_lines: 200
    - path: "runtime/voice/voice_expression_config.json"
      provides: "Expression config data"
    - path: "runtime/voice/rules_engine.py"
      provides: "Rules-engine stub (returns [])"
    - path: "runtime/voice/action_executor.py"
      provides: "Action-executor stub (no-op)"
    - path: "runtime/voice/requirements.txt"
      provides: "Pinned PyPI deps (openwakeword, pyaudio, etc.)"
      contains: "openwakeword"
    - path: "runtime/voice/README.md"
      provides: "Documents the wake → STT → LLM → TTS → face contract and ports"
      min_lines: 30
  key_links:
    - from: "runtime/voice/voice_client.py"
      to: "runtime/llm/router.py"
      via: "from llm.router import route, reset_local"
      pattern: "from llm.router|from runtime.llm"
    - from: "runtime/voice/voice_client.py"
      to: "runtime/tts/tts_sync.py"
      via: "from tts.tts_sync import TTSWithSync, TTSBackend"
      pattern: "from tts|from runtime.tts"
    - from: "runtime/voice/voice_client.py"
      to: "runtime/face/sentiment_classifier.py"
      via: "from face.sentiment_classifier import Sentiment"
      pattern: "from face|from runtime.face"
---

<objective>
Extract the voice orchestrator (`voice_client.py`) and its tightly-coupled support modules (expression controller, log helper, wake test, plus the existing stubs `rules_engine.py` and `action_executor.py`) from `~/iol-monorepo/packages/whisplay/` (live on `arlowe-1.local`) into `runtime/voice/`. Sanitize hardcoded `/home/focal55/...` paths. Author `requirements.txt` and `README.md`.

Purpose: Land EXTRACT-01. The orchestrator is the heart of the wake → STT → LLM → TTS → face pipeline; the smoke test in plan 13 cannot run until this exists.

Output: `runtime/voice/` populated with sanitized source files, deps pinned, contract documented.

Note: `voice_client.py` imports from `llm.router`, `tts.tts_sync`, `face.sentiment_classifier`. Those modules are populated by plans 03/03b (face), 04 (stt+tts), and 05 (llm). For Phase 1, the modules can be stubs at import time — the real wiring is verified in plan 13's smoke test.

**Note on the system-prompt sanitization:** The "no `Joe` literal in the system prompt" requirement is owned by plan 05 (the system prompt lives in `run_api.sh`, which plan 05 owns). It is intentionally NOT a must_have for this plan.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/REQUIREMENTS.md
@.planning/phases/01-runtime-extraction/01-RESEARCH.md
@.planning/phases/01-runtime-extraction/01-01-SUMMARY.md
</context>

<tasks>

<task type="auto">
  <name>Task 1: Pull whisplay tree from arlowe-1 and place voice files</name>
  <files>
    runtime/voice/voice_client.py
    runtime/voice/voice_expression_controller.py
    runtime/voice/voice_expression_config.json
    runtime/voice/voice_log.py
    runtime/voice/wake_test.py
    runtime/voice/rules_engine.py
    runtime/voice/action_executor.py
  </files>
  <action>
Run `scripts/dev-pull-from-pi.sh --apply` (created by plan 01) to mirror `~/iol-monorepo/packages/whisplay/` into `.dev-stash/arlowe-1/whisplay/`.

Then copy these files VERBATIM (no edits yet) into `runtime/voice/`:
- `voice_client.py` (~540 LOC; the orchestrator)
- `voice_expression_controller.py` (~269 LOC)
- `voice_expression_config.json`
- `voice_log.py` (~46 LOC)
- `wake_test.py` (~50 LOC; debug utility)
- `rules_engine.py` (research notes it's a stub returning `[]`; copy as-is)
- `action_executor.py` (research notes it's a no-op stub; copy as-is)

Do NOT copy: `tts_sync.py` (goes to runtime/tts/, plan 04), `audio_sync.py` (goes to runtime/face/, plan 03b owns the canonical copy), `face_service.py` / `face.py` (plan 03), `sentiment_classifier.py` (plan 03b), `iol_router.py` (plan 05), `stt_server.py` (plan 04).

Sanitization happens in Task 2; this task is a pure copy.
  </action>
  <verify>
```bash
test -f runtime/voice/voice_client.py && \
  test -f runtime/voice/voice_expression_controller.py && \
  test -f runtime/voice/voice_expression_config.json && \
  test -f runtime/voice/voice_log.py && \
  test -f runtime/voice/wake_test.py && \
  test -f runtime/voice/rules_engine.py && \
  test -f runtime/voice/action_executor.py && \
  python3 -c "import ast; ast.parse(open('runtime/voice/voice_client.py').read())" && \
  echo OK
```
  </verify>
  <done>All seven files copied verbatim from the Pi mirror; voice_client.py parses as valid Python.</done>
</task>

<task type="auto">
  <name>Task 2: Sanitize voice_client.py hardcoded literals and import paths</name>
  <files>
    runtime/voice/voice_client.py
    runtime/voice/voice_expression_controller.py
    runtime/voice/voice_log.py
    runtime/voice/wake_test.py
  </files>
  <action>
Edit `runtime/voice/voice_client.py` to apply these specific changes (per research §EXTRACT-01):

1. **Delete L18** (the venv hack):
   ```python
   sys.path.insert(0, '/home/focal55/venvs/voice/lib/python3.13/site-packages')
   ```
   Replace with a comment: `# Dependencies provided by /opt/arlowe/venv/ at runtime; see requirements.txt`

2. **L40-42**: Replace
   ```python
   PIPER_PATH = Path.home() / "models/piper/piper"
   PIPER_MODEL = ...  # whatever the line shows
   VERIFIER_MODEL = Path.home() / "wake_word/hey_arlowe_verifier.pkl"
   ```
   With:
   ```python
   PIPER_PATH = Path("/opt/arlowe/runtime/tts/bin/piper")
   PIPER_MODEL = Path("/opt/arlowe/models/piper-voices/en_US-lessac-medium.onnx")
   VERIFIER_MODEL = Path("/var/lib/arlowe/wake-word/verifier.pkl")
   ```

3. **L43-44**: Leave `RECORD_DEVICE = "plughw:2,0"` and `PLAY_DEVICE = "plughw:2,0"` AS-IS. Audio auto-detection is Phase 5 scope. Add a comment immediately above:
   ```python
   # TODO(phase-5): Replace plughw:2,0 with config-driven audio device selection.
   ```

4. **L52**: Replace
   ```python
   LOG_DIR = Path(__file__).resolve().parent / "logs"
   ```
   With:
   ```python
   LOG_DIR = Path("/var/lib/arlowe/logs/voice")
   LOG_DIR.mkdir(parents=True, exist_ok=True)
   ```

5. **Imports** — change relative imports so they resolve from a `runtime/` parent package. Edit:
   ```python
   from iol_router import route as iol_route, reset_local
   from rules_engine import get_engine
   from voice_expression_controller import get_controller
   from action_executor import ActionExecutor
   from tts_sync import TTSWithSync, TTSBackend
   from sentiment_classifier import Sentiment
   ```
   To:
   ```python
   from llm.router import route as llm_route, reset_local
   from voice.rules_engine import get_engine
   from voice.voice_expression_controller import get_controller
   from voice.action_executor import ActionExecutor
   from tts.tts_sync import TTSWithSync, TTSBackend
   from face.sentiment_classifier import Sentiment
   ```
   Also rename any `iol_route(` call sites to `llm_route(`.

6. **Banner string** (search for `ARLOWE-1`): replace `"ARLOWE-1 VOICE CLIENT"` (or similar) with `"ARLOWE VOICE CLIENT"`. Hostname-coupled cosmetic strings die.

7. Apply analogous sanitization to `voice_expression_controller.py`, `voice_log.py`, `wake_test.py`:
   - Delete any `sys.path.insert(0, '/home/focal55/...')` lines.
   - Re-route any `Path.home() / "whisplay/logs"` to `Path("/var/lib/arlowe/logs/voice")`.
   - Update imports of sibling modules to use the new package paths (`from voice.voice_expression_controller`, etc.).

Do NOT modify the `subprocess.run(f"echo 0 | sudo tee {FAN_PWM}", ...)` calls — research R9 documents this as Phase 4+ tech debt. Add a TODO comment:
```python
# TODO(phase-4): sudo from voice service breaks under dedicated arlowe user; needs polkit rule or chgrp on hwmon PWM at boot.
```

Use the Edit tool with surgical replacements; don't rewrite the file. Each replacement should be a 2-5 line change.
  </action>
  <verify>
```bash
# No /home/focal55 anywhere
! grep -r 'focal55' runtime/voice/ && \
# No iol-monorepo path traversal
  ! grep -r 'iol-monorepo' runtime/voice/ && \
# Old `iol_router` import name is gone
  ! grep -rn 'from iol_router' runtime/voice/ && \
# New import names are present
  grep -q 'from llm.router' runtime/voice/voice_client.py && \
# LOG_DIR points at /var/lib/arlowe
  grep -q '/var/lib/arlowe/logs' runtime/voice/voice_client.py && \
# File still parses
  python3 -c "import ast; ast.parse(open('runtime/voice/voice_client.py').read())" && \
  echo OK
```
  </verify>
  <done>No `focal55`, `iol-monorepo`, `iol_router` literals remain in `runtime/voice/`. New import paths resolve from a `runtime/` package root. File parses cleanly.</done>
</task>

<task type="auto">
  <name>Task 3: Author runtime/voice/requirements.txt and runtime/voice/README.md</name>
  <files>
    runtime/voice/requirements.txt
    runtime/voice/README.md
  </files>
  <action>
**`runtime/voice/requirements.txt`**: Capture the voice client's PyPI deps. SSH to arlowe-1 and seed from the live venv:
```bash
ssh arlowe-1 '~/venvs/voice/bin/pip freeze' > /tmp/voice-pip-freeze.txt
```
From that, extract the deps actually imported by voice_client.py / voice_expression_controller.py / voice_log.py / wake_test.py. Specifically (verified by research §EXTRACT-01):
- `openwakeword`
- `pyaudio`
- `numpy` (transitive but explicit)
- `requests` (HTTP to face/STT/LLM)
- (anything else the imports reveal)

Pin to the exact versions from the live `pip freeze`. Write one dep per line with `==` version pins. Add a header comment:
```
# runtime/voice — Python deps for the voice orchestrator
# Pinned from arlowe-1 ~/venvs/voice/ on $(date -u +%F)
# Update procedure: regenerate from pip freeze on the dev unit; bump in a follow-up PR.
```

**`runtime/voice/README.md`**: Document the wake → STT → LLM → TTS → face contract. Concretely include:
- Module purpose (1 paragraph)
- Process model: this is one Python process running as the `arlowe` system user (eventually; today it's `--user` under focal55 — note this).
- Inbound: pyaudio mic on `RECORD_DEVICE` (today `plughw:2,0`)
- Outbound HTTP calls:
  | Target | URL | Used for |
  |---|---|---|
  | face | `http://localhost:8080` | render face state, lip-sync mouth stream |
  | STT | `http://localhost:8082/transcribe` | transcribe wake-window audio |
  | LLM | via `llm.router` (delegates internally) | generate response |
  | dashboard | `http://localhost:3000` | (rules engine fetches; stub doesn't actually use today) |
- How to run locally on arlowe-1 (for the smoke test in plan 13):
  ```bash
  cd /path/to/runtime
  PYTHONPATH=. python3 voice/voice_client.py
  ```
- Known limitations:
  - `RECORD_DEVICE`/`PLAY_DEVICE` hardcoded to `plughw:2,0` (Phase 5 fix)
  - `subprocess.run(... sudo tee FAN_PWM ...)` requires passwordless sudo (Phase 4 fix)
  - Cloud LLM path (via `llm.router`) requires founder Claude credentials today (Phase 7 fix)
- Reference to ADR-0001 (`docs/architecture/0001-iol-router-extraction.md`) for the rename history.

Aim for 30-80 lines. Plain markdown, no emoji.
  </action>
  <verify>
```bash
test -f runtime/voice/requirements.txt && \
  grep -q 'openwakeword' runtime/voice/requirements.txt && \
  grep -q '==' runtime/voice/requirements.txt && \
  test -f runtime/voice/README.md && \
  test "$(wc -l < runtime/voice/README.md)" -ge 30 && \
  grep -q 'wake' runtime/voice/README.md && \
  grep -q '8082' runtime/voice/README.md && \
  echo OK
```
  </verify>
  <done>requirements.txt pins voice deps; README documents the orchestrator contract (process model, inbound/outbound, ports, known limitations).</done>
</task>

</tasks>

<verification>
Phase-level checks for this plan:

```bash
# Files exist and parse
python3 -c "import ast; ast.parse(open('runtime/voice/voice_client.py').read())"
python3 -c "import ast; ast.parse(open('runtime/voice/voice_expression_controller.py').read())"

# No founder literals
! grep -rn 'focal55\|iol-monorepo\|iol_router\|/home/focal55\|joe@focal55\|casa_ybarra' runtime/voice/

# Imports point at the new package layout
grep -q 'from llm.router' runtime/voice/voice_client.py
grep -q 'from tts\.' runtime/voice/voice_client.py
grep -q 'from face\.' runtime/voice/voice_client.py

# LOG_DIR points at /var/lib/arlowe
grep -q '/var/lib/arlowe/logs' runtime/voice/voice_client.py

# requirements pinned
grep -E 'openwakeword==.*' runtime/voice/requirements.txt
```

PR-size check: should land under 600 net lines (mostly file copies + ~30 surgical edits + ~50 line README + ~10 line requirements).
</verification>

<success_criteria>
- All seven voice files exist in runtime/voice/ and parse as valid Python (or JSON for the config)
- Zero `focal55`, `iol-monorepo`, `iol_router`, `/home/focal55`, `casa_ybarra` literals in runtime/voice/
- Imports resolve via `llm.router`, `tts.tts_sync`, `face.sentiment_classifier`
- requirements.txt pins versions from live arlowe-1 venv
- README documents the orchestrator contract
- One PR, <600 net lines
</success_criteria>

<output>
After completion, create `.planning/phases/01-runtime-extraction/01-02-SUMMARY.md` documenting:
- Files extracted and their LOC
- Sanitization changes applied (specific line ranges)
- Imports rewired to new package layout
- Open dependencies on plans 03/03b (face), 04 (tts), 05 (llm) for the smoke test to pass
</output>
