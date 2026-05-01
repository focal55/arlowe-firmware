---
phase: 01-runtime-extraction
plan: 13
type: execute
wave: 5
depends_on: ["02", "03", "04", "05", "08", "10", "11"]
files_modified:
  - runtime/llm/openai_wrapper.py  # OR a router.py edit, depending on chosen option
  - docs/architecture/0001-iol-router-extraction.md  # update with chosen option
  - docs/operations/phase-1-smoke-test.md
  - .planning/phases/01-runtime-extraction/01-13-SUMMARY.md
autonomous: false

requirements:
  - "Phase 1 success criterion 4: voice orchestrator on a sanitized Pi 5 dev unit runs the wake → STT → LLM → TTS → face flow end-to-end at least once (manual smoke test, not yet CI-gated)"
  - "Resolves the qwen-openai.service degraded state surfaced by research §R1 / EXTRACT-05"

must_haves:
  truths:
    - "qwen-openai.service is in a deterministic state — either restored to working (option 1) OR replaced by direct routing to ax-llm :8000 (option 2) OR explicitly bypassed in Phase 1 with documented gap (option 3)"
    - "ADR-0001 §openai_wrapper resolution is updated to record the chosen option and the post-fix observable behaviour"
    - "docs/operations/phase-1-smoke-test.md captures a reproducible procedure: which host, which command, expected logs/journal output"
    - "On arlowe-1, the new runtime/ tree successfully runs wake → STT → LLM → TTS → face end-to-end at least once, captured in the smoke-test doc"
    - "The smoke test does NOT clobber the live (working) services — it runs in parallel via separate unit names and is torn down regardless of test outcome (research R12)"
  artifacts:
    - path: "docs/operations/phase-1-smoke-test.md"
      provides: "Reproducible smoke-test procedure + expected outputs + what was actually observed"
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

<objective>
Run the Phase 1 smoke test. This means:

1. **Resolve the openai_wrapper.py blocker** (research R1 / §EXTRACT-05) — pick option 1, 2, or 3 and execute. Update ADR-0001.
2. **Run the new `runtime/` tree on arlowe-1** under parallel unit names (arlowe-voice-test, etc.) — DO NOT clobber the live working units (research R12).
3. **Verify wake → STT → LLM → TTS → face works end-to-end** and capture the run in `docs/operations/phase-1-smoke-test.md`.
4. **Tear down test units** regardless of test outcome; arlowe-1 returns to its prior state.

Purpose: This is Phase 1's success criterion. Without this plan, Phase 1 is "code refactored" but unverified. With it, Phase 1 is provably done.

Output: Phase 1 done; smoke-test doc written; ADR-0001 updated.

This plan has a checkpoint because it requires running on real hardware against the user's dev unit and the user wants to be in the loop on the wrapper-resolution decision and observe the smoke-test outcome.
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
@.planning/phases/01-runtime-extraction/01-04-SUMMARY.md
@.planning/phases/01-runtime-extraction/01-05-SUMMARY.md
@.planning/phases/01-runtime-extraction/01-08-SUMMARY.md
@.planning/phases/01-runtime-extraction/01-10-SUMMARY.md
@.planning/phases/01-runtime-extraction/01-11-SUMMARY.md
@docs/architecture/0001-iol-router-extraction.md
</context>

<tasks>

<task type="checkpoint:decision" gate="blocking">
  <name>Task 1: openai_wrapper.py resolution decision</name>
  <decision>Pick the openai_wrapper.py resolution path (research R1 / ADR-0001).</decision>
  <context>
The local LLM HTTP path (port 8001) is currently dead on arlowe-1 because `qwen-openai.service` references `/home/focal55/models/Qwen2.5-1.5B-Instruct/openai_wrapper.py` which does not exist. The voice orchestrator falls through to cloud Claude on every query today. ADR-0001 documented three options. Pick one before the smoke test runs:
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
  <resume-signal>Select: option-1, option-2, or option-3 (option-2 is recommended)</resume-signal>
</task>

<task type="auto">
  <name>Task 2: Execute chosen option (Task 1 outcome)</name>
  <files>
    runtime/llm/router.py
    runtime/llm/openai_wrapper.py  # only if option-1
    docs/architecture/0001-iol-router-extraction.md
  </files>
  <action>
Based on Task 1 selection:

**If option-1**:
1. Run `ssh arlowe-1 'cd ~/iol-monorepo && git log --all --diff-filter=D --summary -- "**/openai_wrapper.py"'` — try to recover from git history.
2. If recovered, copy to `runtime/llm/openai_wrapper.py` and sanitize (paths, imports).
3. If not recoverable, write fresh ~50-LOC OpenAI-compat shim that translates `/v1/chat/completions` → ax-llm's native `/v1/chat/completions` on :8000. Reference research §EXTRACT-05 for the contract.
4. Update `qwen-openai.service` (or its replacement under the runtime tree) to point at the new file.
5. Verify by `curl localhost:8001/v1/chat/completions` returning a valid response.

**If option-2 (RECOMMENDED)**:
1. Edit `runtime/llm/router.py`: change `QWEN_URL = "http://localhost:8001/v1/chat/completions"` to `QWEN_URL = "http://localhost:8000/v1/chat/completions"`.
2. Verify ax-llm at :8000 accepts the request shape voice_client sends. If shape differs, adapt the router (NOT voice_client) to translate.
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
  <done>Chosen option implemented; ADR-0001 updated with the decision; router.py parses cleanly.</done>
</task>

<task type="auto">
  <name>Task 3: Stage runtime/ tree on arlowe-1 under test-mode unit names</name>
  <files>
    docs/operations/phase-1-smoke-test.md
  </files>
  <action>
Per research R12, the smoke test must NOT clobber the live working services on arlowe-1. The procedure:

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
   - whisper-stt-test, qwen-* are reused from the live stack (the local LLM stack is on the path that depends on Task 2's resolution; if option-2 chose :8000, the existing qwen-api at :8000 is what we hit)

4. **Tear-down script**: write to a separate file so we can run it on test failure:
   ```bash
   # /tmp/arlowe-test-teardown.sh
   systemctl --user stop arlowe-voice-test arlowe-face-test arlowe-dashboard-test
   systemctl --user disable arlowe-voice-test arlowe-face-test arlowe-dashboard-test
   rm /tmp/arlowe-runtime-test -rf
   rm /tmp/arlowe-test-state -rf
   echo "Test environment torn down. Live state preserved."
   ```

5. **Begin authoring `docs/operations/phase-1-smoke-test.md`** with the staged commands. Sections:
   - Prerequisites (which plans complete, arlowe-1 in nominal state, live services running)
   - Setup (rsync + symlink + units)
   - Smoke-test commands (Task 4 below)
   - Tear-down
   - Expected outputs (Task 5 below)

Do NOT yet start the test units in this task — that's Task 4 (under checkpoint).
  </action>
  <verify>
```bash
ssh arlowe-1 'test -d /tmp/arlowe-runtime-test && test -L /tmp/arlowe-test-state/wake-word/verifier.pkl' && \
  test -f docs/operations/phase-1-smoke-test.md && \
  grep -q 'arlowe-voice-test\|tear-down\|tear down' docs/operations/phase-1-smoke-test.md && \
  echo OK
```
  </verify>
  <done>Test runtime staged on arlowe-1, founder verifier symlinked from outside the repo, test units authored, tear-down script ready.</done>
</task>

<task type="checkpoint:human-verify" gate="blocking">
  <name>Task 4: Run the smoke test (operator-driven)</name>
  <what-built>
A new runtime/ tree is staged on arlowe-1.local at `/tmp/arlowe-runtime-test/`, with parallel `-test` systemd units that run alongside the existing live units (which keep working). Test units use `--user` mode and bind dashboard to port 3001 (not 3000) to avoid conflict.
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

### Phase 1 success criterion 4

> "The voice orchestrator on a sanitized Pi 5 dev unit runs the wake → STT → LLM → TTS → face flow end-to-end at least once (manual smoke test, not yet CI-gated)."

**Result:** PASSED [or PASSED-WITH-NOTES, or FAILED]
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
  echo OK
```
  </verify>
  <done>Smoke-test doc captures the observed run, tear-down verified, success-criterion result recorded. Phase 1 success criterion 4 is observably satisfied (or explicitly not, with rationale).</done>
</task>

</tasks>

<verification>
Phase-level final checks for Phase 1 as a whole:

```bash
# All EXTRACT requirements landed
test -d runtime/voice && test -f runtime/voice/voice_client.py  # EXTRACT-01
test -f runtime/face/face_service.py  # EXTRACT-02
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

# qwen-openai resolution recorded in ADR-0001
grep -qi 'resolved\|chosen' docs/architecture/0001-iol-router-extraction.md
```

PR-size: This plan adds the openai_wrapper resolution (~50 LOC at most for option-1, 1 line for option-2) + the smoke-test doc (~150 LOC) + ADR-0001 update (~15 LOC). Well under 400 net.
</verification>

<success_criteria>
- openai_wrapper.py resolution chosen and implemented (Task 1 + 2)
- ADR-0001 updated to record the resolution
- Smoke test runs on arlowe-1 with parallel `-test` units, no clobber of live state (Task 4)
- Wake → STT → LLM → TTS → face observed end-to-end at least once (Task 4)
- Tear-down complete; live units unaffected
- `docs/operations/phase-1-smoke-test.md` captures the run for repeatability
- **Phase 1 success criterion 4 satisfied**
</success_criteria>

<output>
After completion, create `.planning/phases/01-runtime-extraction/01-13-SUMMARY.md` documenting:
- openai_wrapper.py resolution chosen
- Smoke-test outcome (PASSED / PASSED-WITH-NOTES / FAILED)
- Round-trip time observed
- Tear-down verified
- Phase 1 = COMPLETE (or, if failed, the specific failure mode + plan-13-revision pending)
</output>
