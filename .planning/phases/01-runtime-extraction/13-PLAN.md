---
phase: 01-runtime-extraction
plan: 13
type: execute
wave: 6
depends_on: ["02", "03", "03b", "04", "05", "08b", "09", "10", "11", "12"]
files_modified:
  - runtime/llm/openai_wrapper.py  # OR a router.py edit, depending on chosen option
  - docs/architecture/0001-iol-router-extraction.md  # update with chosen option
  - docs/operations/phase-1-smoke-test.md
  - .planning/phases/01-runtime-extraction/01-13-SUMMARY.md
autonomous: false

requirements:
  - "Phase 1 success criterion 4 (qualified): voice orchestrator on the Pi 5 dev unit (arlowe-1) runs the wake → STT → LLM → TTS → face flow end-to-end at least once via parallel `-test` units that share the live qwen-* and whisper-stt services. Fully sanitized first-flash unit smoke is deferred to Phase 12."
  - "Resolves the qwen-openai.service degraded state surfaced by research §R1 / EXTRACT-05"

must_haves:
  truths:
    - "qwen-openai.service is in a deterministic state — either restored to working (option 1) OR replaced by direct routing to ax-llm :8000 (option 2) OR explicitly bypassed in Phase 1 with documented gap (option 3)"
    - "ADR-0001 §openai_wrapper resolution is updated to record the chosen option and the post-fix observable behaviour"
    - "docs/operations/phase-1-smoke-test.md captures a reproducible procedure: which host, which command, expected logs/journal output, AND honestly documents the limit that this smoke test reuses live services (whisper-stt + qwen-* are shared with the live stack — not a fully sanitized first-flash unit)"
    - "On arlowe-1, the new runtime/ tree successfully runs wake → STT → LLM → TTS → face end-to-end at least once, captured in the smoke-test doc"
    - "The smoke test does NOT clobber the live (working) services — it runs in parallel via separate unit names and is torn down regardless of test outcome (research R12)"
    - "If option-1 is chosen for openai_wrapper resolution, the OpenAI /v1/chat/completions request/response schema is fully specified before implementation begins (M2)"
  artifacts:
    - path: "docs/operations/phase-1-smoke-test.md"
      provides: "Reproducible smoke-test procedure + expected outputs + what was actually observed + explicit scope limit (Phase 12 does the fully-sanitized first-flash test)"
      min_lines: 80
    - path: "docs/architecture/0001-iol-router-extraction.md"
      provides: "Updated to record openai_wrapper resolution choice"
      contains: "Resolution"
  key_links:
    - from: "runtime/voice/voice_client.py"
      to: "ax-llm via either :8000 or :8001 (depending on chosen option)"
      via: "HTTP POST through llm.router"
      pattern: "localhost:800[01]"
    - from: "smoke test on arlowe-1"
      to: "tear-down state matches pre-test state"
      via: "test-mode unit names (e.g., arlowe-voice-test.service)"
      pattern: "test-mode|arlowe-voice-test"
---

<!--
  PLAN-OPERATIONAL NOTE (per checker M4):

  This plan is INTENTIONALLY non-autonomous. It is the human-driven smoke-test plan
  for Phase 1 and it requires Joe (the device owner) physically present at arlowe-1
  to speak the wake phrase and observe the face. It is NOT picked up by autonomous
  DEV agents in `/gsd:execute-phase` — when the executor reaches it, the workflow
  pauses at the first checkpoint and waits for Joe.

  The plan has 6 tasks (above the soft 5-task quality threshold). The size is
  acknowledged: the smoke test is one logical unit with two human checkpoints
  (a decision and a verify), and splitting it would obscure the cause-and-effect
  arc (resolution decision → execute → stage on Pi → run with human → write up).
  Splitting saves nothing; reading is harder.

  The plan also acknowledges (per M1 / Phase 1 success criterion 4) that the smoke
  test reuses the live whisper-stt and qwen-* services rather than spinning up a
  fully sanitized first-flash environment. That fully-sanitized test lives in
  Phase 12. ROADMAP.md's Phase 1 success criterion 4 is interpreted accordingly;
  this plan's must_haves and the smoke-test doc both record the limitation
  explicitly so it doesn't quietly become a hidden assumption.
-->

<objective>
Run the Phase 1 smoke test. This means:

1. **Resolve the openai_wrapper.py blocker** (research R1 / §EXTRACT-05) — pick option 1, 2, or 3 and execute. Update ADR-0001.
2. **Run the new `runtime/` tree on arlowe-1** under parallel unit names (arlowe-voice-test, etc.) — DO NOT clobber the live working units (research R12). Note: the smoke test reuses the live `whisper-stt` and `qwen-*` services rather than starting fresh sanitized copies. This is a deliberate tradeoff between test fidelity and operational safety; the fully sanitized test runs in Phase 12 (first-flash integration).
3. **Verify wake → STT → LLM → TTS → face works end-to-end** and capture the run in `docs/operations/phase-1-smoke-test.md`.
4. **Tear down test units** regardless of test outcome; arlowe-1 returns to its prior state.

Purpose: This is Phase 1's success criterion 4 (with the documented qualifier above). Without this plan, Phase 1 is "code refactored" but unverified. With it, Phase 1's runtime tree is provably runnable end-to-end on the dev unit.

Output: Phase 1 done at the level Phase 1 can validate; smoke-test doc written with explicit scope limits; ADR-0001 updated.

This plan has checkpoints because it requires running on real hardware against the user's dev unit and the user wants to be in the loop on the wrapper-resolution decision and observe the smoke-test outcome.
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
@.planning/phases/01-runtime-extraction/01-02-SUMMARY.md
@.planning/phases/01-runtime-extraction/01-03-SUMMARY.md
@.planning/phases/01-runtime-extraction/01-03b-SUMMARY.md
@.planning/phases/01-runtime-extraction/01-04-SUMMARY.md
@.planning/phases/01-runtime-extraction/01-05-SUMMARY.md
@.planning/phases/01-runtime-extraction/01-08-SUMMARY.md
@.planning/phases/01-runtime-extraction/01-08b-SUMMARY.md
@.planning/phases/01-runtime-extraction/01-09-SUMMARY.md
@.planning/phases/01-runtime-extraction/01-10-SUMMARY.md
@.planning/phases/01-runtime-extraction/01-11-SUMMARY.md
@.planning/phases/01-runtime-extraction/01-12-SUMMARY.md
@docs/architecture/0001-iol-router-extraction.md
@docs/architecture/0002-arlowe-scheduled-summary-stripped.md
</context>

<tasks>

<task type="checkpoint:decision" gate="blocking">
  <name>Task 1: openai_wrapper.py resolution decision</name>
  <decision>Pick the openai_wrapper.py resolution path (research R1 / ADR-0001).</decision>
  <context>
The local LLM HTTP path (port 8001) is currently dead on arlowe-1 because `qwen-openai.service` references `/home/focal55/models/Qwen2.5-1.5B-Instruct/openai_wrapper.py` which does not exist. The voice orchestrator falls through to cloud Claude on every query today. ADR-0001 documented three options. Pick one before the smoke test runs.

**Recommended: option-2.** It removes a moving part with the lowest LOC delta and is verified working today (`curl http://localhost:8000/v1/models` on arlowe-1 succeeds).

If option-1 is chosen, the executor MUST first specify the OpenAI `/v1/chat/completions` request/response schema concretely (per checker M2) before writing any wrapper code. The schema reference is below in the option-1 details.
  </context>
  <options>
    <option id="option-1">
      <name>Restore the wrapper from git history or write fresh</name>
      <pros>
        - Preserves the OpenAI-compat shim layer (some clients may depend on its specific request/response shape)
        - Smallest behavioural change to existing code
      </pros>
      <cons>
        - Requires git archeology (`git log --all --diff-filter=D -- '**/openai_wrapper.py'`) — file may not be recoverable
        - If writing fresh, ~50 LOC of new code that needs to be tested
        - Adds a moving part that's not strictly necessary
      </cons>
      <execution-rule>
        **Conditional behaviour to prevent inventing API shapes (M2)**:
        - First: run the recovery probe.
          ```bash
          ssh arlowe-1 'cd ~/iol-monorepo && git log --all --diff-filter=D --summary -- "**/openai_wrapper.py" 2>&1 | head -20'
          ssh arlowe-1 'cd ~/iol-monorepo && git log --all --diff-filter=D -p -- "**/openai_wrapper.py" 2>&1 | head -200'
          ```
        - If recovery succeeds: copy the recovered content, sanitize, done.
        - If recovery fails (file truly unrecoverable): **auto-fall to option-2**. Do NOT write a fresh shim from research notes — the request/response shape is too easy to get subtly wrong, and option-2 is verified working without a shim.
        - Rationale: option-1's value is preservation, not invention. If preservation is impossible, option-2 is strictly better.

        **OpenAI /v1/chat/completions schema (concrete, for reference)**:

        Request body (JSON):
        ```json
        {
          "model": "qwen2.5-7b-instruct",
          "messages": [
            {"role": "system", "content": "<system prompt>"},
            {"role": "user", "content": "<user message>"}
          ],
          "stream": false,
          "max_tokens": 512,
          "temperature": 0.7
        }
        ```

        Response body (JSON):
        ```json
        {
          "id": "chatcmpl-<id>",
          "object": "chat.completion",
          "created": 1714521600,
          "model": "qwen2.5-7b-instruct",
          "choices": [
            {
              "index": 0,
              "message": {"role": "assistant", "content": "<reply>"},
              "finish_reason": "stop"
            }
          ],
          "usage": {"prompt_tokens": 12, "completion_tokens": 4, "total_tokens": 16}
        }
        ```

        The shim's job is to translate this into ax-llm's native shape on :8000 and back. If translating, run a side-by-side `curl` against :8000 to confirm the native shape before coding.
      </execution-rule>
    </option>
    <option id="option-2">
      <name>Eliminate the wrapper — point router at ax-llm native :8000 directly (RECOMMENDED)</name>
      <pros>
        - Lowest LOC delta (one URL change in router.py)
        - Removes a moving part (one fewer service to keep alive)
        - ax-llm 2024+ supports the OpenAI surface natively (verified live: `curl http://localhost:8000/v1/models` returns ok)
        - qwen-openai.service can be removed from the systemd unit set entirely (Phase 11 cleanup)
      </pros>
      <cons>
        - Diverges from the current architecture (3 services → 2)
        - Need to verify the request/response shape of `:8000` matches what `voice_client.py` expects
      </cons>
    </option>
    <option id="option-3">
      <name>Skip in Phase 1 — accept cloud-only smoke test, restore local in a later phase</name>
      <pros>
        - Phase 1 ships fastest
        - Cloud path is already working on arlowe-1 (founder credentials present)
      </pros>
      <cons>
        - Smoke test doesn't actually validate the local-LLM path
        - The "no internet round-trip in default path" v1 promise is not exercised
        - Pushes the unknown into a later phase, where it becomes a blocker for image-build verification
      </cons>
    </option>
  </options>
  <resume-signal>Select: option-1, option-2, or option-3 (option-2 is recommended; option-1 falls back to option-2 automatically if git recovery fails)</resume-signal>
</task>

<task type="auto">
  <name>Task 2: Execute chosen option (Task 1 outcome)</name>
  <files>
    runtime/llm/router.py
    runtime/llm/openai_wrapper.py  # only if option-1 succeeds in recovery
    docs/architecture/0001-iol-router-extraction.md
  </files>
  <action>
Based on Task 1 selection:

**If option-1 (with the M2 conditional)**:
1. Run `ssh arlowe-1 'cd ~/iol-monorepo && git log --all --diff-filter=D -p -- "**/openai_wrapper.py"'` — try to recover from git history.
2. **If recovery succeeds**:
   a. Copy recovered content to `runtime/llm/openai_wrapper.py`.
   b. Sanitize: strip any `/home/focal55` paths; rewrite imports for the new package layout.
   c. Update `qwen-openai.service` (or its replacement under the runtime tree) to point at the new file.
   d. Verify by `curl localhost:8001/v1/chat/completions` returning a valid response with the schema shown in Task 1's option-1 execution-rule.
3. **If recovery fails**: per the option-1 execution-rule, **auto-fall to option-2**. Do not invent a shim from research notes. Update ADR-0001 to record "option-1 attempted, recovery failed, fell back to option-2 per plan-13 conditional rule."

**If option-2 (RECOMMENDED)**:
1. Edit `runtime/llm/router.py`: change `QWEN_URL = "http://localhost:8001/v1/chat/completions"` to `QWEN_URL = "http://localhost:8000/v1/chat/completions"`.
2. Verify ax-llm at :8000 accepts the request shape voice_client sends. If shape differs, adapt the router (NOT voice_client) to translate. Use the schema from Task 1's option-1 execution-rule as the reference for the OpenAI shape; compare against `curl http://localhost:8000/v1/chat/completions -d '...'` to learn ax-llm's native shape.
3. Mark `qwen-openai.service` for deprecation in a comment in router.py.
4. NO wrapper file written.

**If option-3**:
1. Edit `runtime/llm/router.py`: in the routing heuristic, force-route ALL queries to the cloud path during the smoke test. Use an env knob: `if os.environ.get("ARLOWE_FORCE_CLOUD") == "1": return query_cloud(...)`. Default off in production.
2. Document the gap explicitly.
3. Smoke test runs cloud-only.

**Update ADR-0001**:
Open `docs/architecture/0001-iol-router-extraction.md` and edit the "openai_wrapper.py — resolution" section. Record:
- Which option was chosen
- Why
- The post-fix observable behaviour (e.g., "voice query → POST :8000 → response in 1.2s")
- Any follow-up work (e.g., "Phase 11 removes qwen-openai.service from systemd unit set")
- Date of decision

The ADR section header changes from "(deferred to plan 13)" to "(resolved 2026-XX-XX in plan 13)".
  </action>
  <verify>
```bash
# Option-2 verification (most likely path)
grep -q 'localhost:8000\|localhost:8001' runtime/llm/router.py && \
  grep -qi 'resolved\|chosen\|option' docs/architecture/0001-iol-router-extraction.md && \
  python3 -c "import ast; ast.parse(open('runtime/llm/router.py').read())" && \
  echo OK
```
  </verify>
  <done>Chosen option implemented; ADR-0001 updated with the decision; router.py parses cleanly. If option-1 was selected and recovery failed, the auto-fall to option-2 is recorded.</done>
</task>

<task type="auto">
  <name>Task 3: Stage runtime/ tree on arlowe-1 under test-mode unit names + handle smoke-test prerequisites</name>
  <files>
    docs/operations/phase-1-smoke-test.md
  </files>
  <action>
Per research R12, the smoke test must NOT clobber the live working services on arlowe-1. The procedure:

**Smoke-test prerequisites (covers M5 / PyYAML installation)**:

Before staging, confirm the prerequisites discovered/declared during plans 04-12:

1. **PyYAML on arlowe-1's voice venv** (per plan 04 / M5). If plan 04 documented that PyYAML required installation, run it now:
   ```bash
   ssh arlowe-1 '~/venvs/voice/bin/python -c "import yaml; print(\"PyYAML\", yaml.__version__)"' \
     || ssh arlowe-1 '~/venvs/voice/bin/pip install PyYAML'
   ```
   Re-verify after install: `ssh arlowe-1 '~/venvs/voice/bin/python -c "import yaml"'` MUST succeed.

2. **Verify ax-llm + axcl pins are reachable** (per plans 09 + 12 — depends_on includes both):
   ```bash
   git -C third_party/ax-llm rev-parse HEAD       # confirms plan 09's submodule is initialized
   test -f third_party/axcl/manifest.yml          # confirms plan 09's manifest is in tree
   test -f docs/architecture/0002-arlowe-scheduled-summary-stripped.md  # confirms plan 12's ADR is in tree
   ```
   Per checker B2, plan 13's depends_on now includes 09 and 12 — these checks should never fail.

**Stage the runtime/ tree**:

1. **Push the new runtime/ tree to arlowe-1**:
   ```bash
   rsync -av --delete \
     --exclude='node_modules/' --exclude='.next/' --exclude='__pycache__/' \
     runtime/ arlowe-1:/tmp/arlowe-runtime-test/
   ```
   Path `/tmp/arlowe-runtime-test/` is intentionally outside `/opt/arlowe/` so it doesn't conflict with anything.

2. **Symlink the founder's verifier .pkl** into the test runtime's expected location (R6: never enters the repo, but the smoke test on arlowe-1 needs SOMETHING to verify):
   ```bash
   ssh arlowe-1 'mkdir -p /tmp/arlowe-test-state/wake-word && \
                 ln -sf $HOME/wake_word/hey_arlowe_verifier.pkl \
                        /tmp/arlowe-test-state/wake-word/verifier.pkl'
   ```

3. **Author parallel test-mode systemd `--user` units** under `/tmp/arlowe-runtime-test/systemd-test/`. These mirror the existing units but with `-test` suffixed and `ExecStart` pointing at the new tree:
   - `arlowe-voice-test.service` — runs `python3 /tmp/arlowe-runtime-test/voice/voice_client.py` with env vars set (`ARLOWE_WAKE_WORD_VERIFIER=/tmp/arlowe-test-state/wake-word/verifier.pkl`, `ARLOWE_LOGS_DIR=/tmp/arlowe-test-state/logs`, `PYTHONPATH=/tmp/arlowe-runtime-test`)
   - `arlowe-face-test.service` — runs face_service from new tree
   - `arlowe-dashboard-test.service` — runs dashboard from new tree on port 3001 (NOT 3000) to avoid clobber
   - **whisper-stt-test, qwen-\* are reused from the live stack.** This is the M1 limitation: the test does not validate fully sanitized STT/LLM. The fully-sanitized first-flash test happens in Phase 12. The smoke-test doc must call this out explicitly.

4. **Tear-down script**: write to a separate file so we can run it on test failure:
   ```bash
   # /tmp/arlowe-test-teardown.sh
   systemctl --user stop arlowe-voice-test arlowe-face-test arlowe-dashboard-test
   systemctl --user disable arlowe-voice-test arlowe-face-test arlowe-dashboard-test
   rm /tmp/arlowe-runtime-test -rf
   rm /tmp/arlowe-test-state -rf
   echo "Test environment torn down. Live state preserved."
   ```

5. **Begin authoring `docs/operations/phase-1-smoke-test.md`** with the staged commands. Sections (the M1 scope-limit section is non-negotiable):

   ```markdown
   # Phase 1 Smoke Test — Procedure and Run Log

   ## Scope and limits (READ FIRST)

   This smoke test verifies that the Phase 1 `runtime/` tree can drive a wake → STT → LLM → TTS → face round trip on the dev unit (arlowe-1.local). It is NOT a fully-sanitized first-flash integration test.

   Specifically:
   - The test runs on arlowe-1 alongside the live working services. The dev unit is the founder's daily driver, not a freshly-flashed Pi.
   - The test reuses the live `whisper-stt` service and the live `qwen-{tokenizer,api,openai}` services. Only the orchestrator, face, and dashboard run from the new `runtime/` tree.
   - The founder's `~/wake_word/hey_arlowe_verifier.pkl` is symlinked from outside the repo so the wake-word stage has something to verify against. The .pkl never enters the repo.

   The fully-sanitized first-flash test — factory-fresh Pi 5 + AX + Whisplay flashed from a clean image, paired as a fake owner, with no founder identity present anywhere on disk — happens in **Phase 12** per ROADMAP.md success criteria.

   Phase 1 success criterion 4 from ROADMAP.md ("voice orchestrator on a sanitized Pi 5 dev unit runs the wake → STT → LLM → TTS → face flow end-to-end at least once, manual smoke test, not yet CI-gated") is interpreted by this plan as: **the orchestrator + face + dashboard run from the new tree on the dev unit, end-to-end, while the live STT/LLM services service the request**. The fully-sanitized variant ships in Phase 12.

   ## Prerequisites
   ...

   ## Setup
   ...

   ## Smoke-test commands
   ...

   ## Expected outputs
   ...

   ## Tear-down
   ...

   ## Observed run
   (filled in by Task 5)
   ```

Do NOT yet start the test units in this task — that's Task 4 (under checkpoint).
  </action>
  <verify>
```bash
ssh arlowe-1 'test -d /tmp/arlowe-runtime-test && test -L /tmp/arlowe-test-state/wake-word/verifier.pkl' && \
  test -f docs/operations/phase-1-smoke-test.md && \
  grep -q 'arlowe-voice-test\|tear-down\|tear down' docs/operations/phase-1-smoke-test.md && \
  grep -qi 'scope and limits\|fully.sanitized\|phase 12' docs/operations/phase-1-smoke-test.md && \
  ssh arlowe-1 '~/venvs/voice/bin/python -c "import yaml"' >/dev/null 2>&1 && \
  echo OK
```
  </verify>
  <done>Test runtime staged on arlowe-1, founder verifier symlinked from outside the repo, test units authored, tear-down script ready, smoke-test doc started with the M1 scope-limits section, PyYAML verified installed on the voice venv (M5).</done>
</task>

<task type="checkpoint:human-verify" gate="blocking">
  <name>Task 4: Run the smoke test (operator-driven)</name>
  <what-built>
A new runtime/ tree is staged on arlowe-1.local at `/tmp/arlowe-runtime-test/`, with parallel `-test` systemd units that run alongside the existing live units (which keep working). Test units use `--user` mode and bind dashboard to port 3001 (not 3000) to avoid conflict. STT and LLM services are reused from the live stack — this is a hybrid setup and is documented as such in the smoke-test doc's "Scope and limits" section.
  </what-built>
  <how-to-verify>
On the Mac, in a Claude Code session connected to arlowe-1:

1. Start the test units:
   ```bash
   ssh arlowe-1 'systemctl --user daemon-reload && \
                 systemctl --user start arlowe-face-test arlowe-dashboard-test && \
                 sleep 3 && \
                 systemctl --user start arlowe-voice-test'
   ```

2. Verify they came up clean:
   ```bash
   ssh arlowe-1 'systemctl --user is-active arlowe-{face,dashboard,voice}-test'
   ```
   Expect: three `active` lines.

3. Tail logs in another terminal:
   ```bash
   ssh arlowe-1 'journalctl --user -u arlowe-voice-test -f'
   ```
   You should see "ARLOWE VOICE CLIENT" banner, wake-word model loading, mic listening.

4. Speak the wake phrase:
   - Walk to the Pi
   - Say clearly: **"Hey Arlowe, what's two plus two?"**

5. Observe:
   - Whisplay face flashes pink (wake), turns to "listening" face
   - 5s recording window completes
   - Logs show STT transcript ("what's two plus two", or close)
   - LLM call (option-2: hits :8000; option-3: hits cloud)
   - Logs show LLM response
   - Face turns "talking" blue, Piper speaks the answer with lip-sync
   - Face returns to idle

6. Open the test dashboard at `http://arlowe-1.local:3001/` from your Mac browser:
   - Verify homepage renders
   - Verify `/api/health` returns sane JSON
   - Verify `/api/voice` shows `arlowe-voice-test` as active

7. Hit `/api/logs` — verify it does NOT 500, and shows journalctl output.

8. **Capture observed behaviour** in `docs/operations/phase-1-smoke-test.md` — what worked, any oddities, response time roughly, the exact transcript.

9. **Tear down** regardless of outcome:
   ```bash
   ssh arlowe-1 'bash /tmp/arlowe-test-teardown.sh'
   ssh arlowe-1 'systemctl --user is-active arlowe-{voice,face,dashboard}'  # confirm live units still active
   ```

If anything fails: capture the failure in the smoke-test doc, tear down, and flag for diagnosis. Do NOT keep failing test units running on arlowe-1.
  </how-to-verify>
  <resume-signal>Type "passed", "passed-with-notes", or describe failures (the SUMMARY records whichever).</resume-signal>
</task>

<task type="auto">
  <name>Task 5: Finalize docs/operations/phase-1-smoke-test.md with observed run</name>
  <files>docs/operations/phase-1-smoke-test.md</files>
  <action>
Complete the smoke-test doc started in Task 3. Now that Task 4 ran, fill in the **Observed run** section:

```markdown
## Observed run — 2026-XX-XX

Performed by: Joe Ybarra
Host: arlowe-1.local
openai_wrapper resolution: option-X (per ADR-0001)

### Wake → STT → LLM → TTS → face

| Step | Observed | Notes |
|---|---|---|
| Wake phrase spoken | "Hey Arlowe, what's two plus two?" | |
| Pink wake flash | Yes | |
| Listening face | Yes, ~Xs | |
| STT transcript | (paste the actual transcript from logs) | |
| LLM route | local :8000 (option-2) / cloud (option-3) | |
| LLM response | (paste the actual response) | |
| Talking-blue face | Yes | |
| Piper speech with lip-sync | Yes | |
| Face returns to idle | Yes | |
| Round-trip time | ~Xs | |

### Tear-down verified

| Check | Result |
|---|---|
| Test units stopped | yes |
| Live units still active | yes |
| Test dirs cleaned (`/tmp/arlowe-runtime-test`, `/tmp/arlowe-test-state`) | yes |

### Anomalies / open issues

- (Anything weird; expected to be empty if option-2 worked)

### Phase 1 success criterion 4 — qualified result

ROADMAP.md success criterion 4 says:
> "The voice orchestrator on a sanitized Pi 5 dev unit runs the wake → STT → LLM → TTS → face flow end-to-end at least once (manual smoke test, not yet CI-gated)."

This plan interprets that as: orchestrator + face + dashboard from the new `runtime/` tree, on the dev unit, running end-to-end while the live STT/LLM services serve the request. The fully-sanitized first-flash variant (factory-fresh Pi, no founder identity on disk, all services from the new tree) ships in Phase 12.

**Result for the qualified Phase-1 reading:** PASSED [or PASSED-WITH-NOTES, or FAILED]
**Phase-12 deferred work:** fully-sanitized first-flash integration.
```

Also include the final tear-down script content + the staging commands (so this doc is self-contained for re-running the test).

80-200 lines. Plain markdown, no emoji.
  </action>
  <verify>
```bash
test -f docs/operations/phase-1-smoke-test.md && \
  test "$(wc -l < docs/operations/phase-1-smoke-test.md)" -ge 80 && \
  grep -qi 'observed run\|round-trip' docs/operations/phase-1-smoke-test.md && \
  grep -qi 'tear.down' docs/operations/phase-1-smoke-test.md && \
  grep -qi 'success criterion\|passed\|failed' docs/operations/phase-1-smoke-test.md && \
  grep -qi 'phase 12\|fully.sanitized' docs/operations/phase-1-smoke-test.md && \
  echo OK
```
  </verify>
  <done>Smoke-test doc captures the observed run, tear-down verified, success-criterion result recorded with explicit qualifier (Phase 12 owns the fully-sanitized variant). Phase 1 success criterion 4 is observably satisfied at the qualified-reading level.</done>
</task>

</tasks>

<verification>
Phase-level final checks for Phase 1 as a whole:

```bash
# All EXTRACT requirements landed
test -d runtime/voice && test -f runtime/voice/voice_client.py  # EXTRACT-01
test -f runtime/face/face_service.py  # EXTRACT-02 (plan 03)
test -f runtime/face/sentiment_classifier.py  # EXTRACT-02 (plan 03b)
test -f runtime/face/audio_sync.py  # EXTRACT-02 (plan 03b)
test -f runtime/stt/stt_server.py  # EXTRACT-03
test -f runtime/tts/tts_sync.py && test -f runtime/tts/manifest.yml  # EXTRACT-04
test -f runtime/llm/router.py && test -f runtime/llm/run_api.sh  # EXTRACT-05
test -f runtime/dashboard/package.json  # EXTRACT-06
test -f runtime/wake-word/train_verifier.py  # EXTRACT-07
test -f runtime/cli/boot-check  # EXTRACT-08
git -C third_party/ax-llm rev-parse HEAD  # EXTRACT-09
test -f third_party/axcl/manifest.yml  # EXTRACT-10
test -f docs/architecture/0001-iol-router-extraction.md  # EXTRACT-11
test -f docs/architecture/0002-arlowe-scheduled-summary-stripped.md  # EXTRACT-12

# Smoke test recorded
test -f docs/operations/phase-1-smoke-test.md
grep -qi 'PASSED\|FAILED' docs/operations/phase-1-smoke-test.md
grep -qi 'phase 12\|fully.sanitized' docs/operations/phase-1-smoke-test.md  # M1 scope-limit acknowledgement

# qwen-openai resolution recorded in ADR-0001
grep -qi 'resolved\|chosen' docs/architecture/0001-iol-router-extraction.md
```

PR-size: This plan adds the openai_wrapper resolution (~50 LOC at most for option-1 if recovered, 1 line for option-2) + the smoke-test doc (~150 LOC) + ADR-0001 update (~15 LOC). Well under 400 net.
</verification>

<success_criteria>
- openai_wrapper.py resolution chosen and implemented (Task 1 + 2), with M2's option-1 conditional rule honored
- ADR-0001 updated to record the resolution
- Smoke test runs on arlowe-1 with parallel `-test` units, no clobber of live state (Task 4)
- Wake → STT → LLM → TTS → face observed end-to-end at least once (Task 4)
- Tear-down complete; live units unaffected
- `docs/operations/phase-1-smoke-test.md` captures the run for repeatability AND explicitly documents the scope limit (hybrid live/test stack; fully-sanitized first-flash test deferred to Phase 12) — M1
- PyYAML installation on arlowe-1 voice venv verified (M5)
- Plan dependencies on plans 09 and 12 honored (B2)
- Plan dependency on plan 08b honored (post-split)
- **Phase 1 success criterion 4 satisfied (at the qualified-reading level documented in the smoke-test doc)**
</success_criteria>

<output>
After completion, create `.planning/phases/01-runtime-extraction/01-13-SUMMARY.md` documenting:
- openai_wrapper.py resolution chosen (and whether option-1 fell back to option-2 per the conditional rule)
- Smoke-test outcome (PASSED / PASSED-WITH-NOTES / FAILED)
- Round-trip time observed
- Tear-down verified
- Phase 1 = COMPLETE at the qualified-reading level (or, if failed, the specific failure mode + plan-13-revision pending)
- **Phase-12 deferred work**: fully-sanitized first-flash integration (factory-fresh hardware, no founder identity, all services from new tree)
</output>
