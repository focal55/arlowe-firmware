---
phase: 01-runtime-extraction
plan: 03b
type: execute
wave: 2
depends_on: ["01"]
files_modified:
  - runtime/face/sentiment_classifier.py
  - runtime/face/audio_sync.py
  - runtime/face/requirements.txt
  - runtime/face/README.md
  - .planning/phases/01-runtime-extraction/01-03b-SUMMARY.md
autonomous: true

requirements:
  - "EXTRACT-02 (part 2): sentiment_classifier.py + audio_sync.py extract to runtime/face/; requirements + README authored"

must_haves:
  truths:
    - "runtime/face/sentiment_classifier.py reads its config from /etc/arlowe/config.yml fallback path, not ~/.claude/workspace/whisplay-config.json"
    - "sentiment_classifier loads gracefully when /etc/arlowe/config.yml is absent (verified by import + classify call from inside runtime/)"
    - "audio_sync.py is colocated under runtime/face/ as the canonical copy (referenced by tts_sync.py via `from face.audio_sync import ...` in plan 04)"
    - "runtime/face/requirements.txt pins PyPI deps (Flask, requests, numpy, Pillow) to live arlowe-1 versions"
    - "runtime/face/README.md documents the tcp/8080 contract, sentiment fallback behaviour, and the WhisPlay driver dependency (linking to PROVENANCE.md)"
  artifacts:
    - path: "runtime/face/sentiment_classifier.py"
      provides: "Sentiment classification (NPU + heuristic fallback)"
      min_lines: 200
    - path: "runtime/face/audio_sync.py"
      provides: "Mouth animation sync helper (canonical copy; tts_sync.py imports from here)"
      min_lines: 200
    - path: "runtime/face/requirements.txt"
      provides: "Pinned PyPI deps"
      contains: "flask"
    - path: "runtime/face/README.md"
      provides: "Documents the tcp/8080 contract, WhisPlay driver dependency, sentiment fallback behaviour"
      min_lines: 30
  key_links:
    - from: "runtime/face/sentiment_classifier.py"
      to: "/etc/arlowe/config.yml (with fallback)"
      via: "reads CONFIG_PATH"
      pattern: "/etc/arlowe/config.yml|/var/lib/arlowe"
---

<objective>
Land the rest of EXTRACT-02: extract `sentiment_classifier.py` and `audio_sync.py` into `runtime/face/`, sanitize the founder Claude-workspace config-path coupling in sentiment_classifier, and author requirements.txt + README.md.

Purpose: Plan 03 handled the bulk source files (face.py, face_service.py); this plan handles the helper modules and packaging. Splitting the EXTRACT-02 work this way keeps each PR under the 600-line atomic-PR cap.

The audio_sync.py file in this plan is the canonical copy that plan 04's `tts_sync.py` imports from (via `from face.audio_sync import ...`). This is why plan 04 declares `depends_on: ["01", "03b"]` — `audio_sync.py` must exist before `tts_sync.py` is sanitized to import from it.

Output: `runtime/face/sentiment_classifier.py`, `runtime/face/audio_sync.py`, `runtime/face/requirements.txt`, `runtime/face/README.md`.
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
@.planning/phases/01-runtime-extraction/01-03-SUMMARY.md
</context>

<tasks>

<task type="auto">
  <name>Task 1: Copy sentiment_classifier.py + audio_sync.py and sanitize</name>
  <files>
    runtime/face/sentiment_classifier.py
    runtime/face/audio_sync.py
  </files>
  <action>
Assumes plan 01's `dev-pull-from-pi.sh --apply` has populated `.dev-stash/arlowe-1/whisplay/`.

Copy verbatim from `.dev-stash/arlowe-1/whisplay/` to `runtime/face/`:
- `sentiment_classifier.py` (~292 LOC)
- `audio_sync.py` (~243 LOC)

Then sanitize:

**`runtime/face/sentiment_classifier.py`**:
- L13 `QWEN_URL = "http://localhost:8001/v1/chat/completions"` — leave the URL but add a comment:
  ```python
  # localhost:8001 is the OpenAI-compat shim. See research notes / plan 13:
  # the path may be replumbed to localhost:8000 (ax-llm native) once the
  # qwen-openai resolution lands. Heuristic fallback handles the broken case.
  ```
- L16 `CONFIG_PATH = Path.home() / ".claude/workspace/whisplay-config.json"` — REPLACE with config-overlay aware lookup:
  ```python
  # Load order: /etc/arlowe/config.yml (post-pairing overlay, Phase 4),
  # falling back to /var/lib/arlowe/state/whisplay-config.json for dev.
  # During Phase 1 we accept the fallback path; Phase 4 wires the overlay.
  CONFIG_OVERLAY = Path("/etc/arlowe/config.yml")
  CONFIG_PATH = Path("/var/lib/arlowe/state/whisplay-config.json")
  ```
- Update any code that reads `CONFIG_PATH` to gracefully handle the file being absent (this is the Phase-1 "not-yet-paired" state). The classifier MUST NOT raise on missing config — it must fall back to the heuristic path.
- Confirm the heuristic fallback (`classify_sentiment_heuristic`) is still wired into the call path. (Per research, it already is — verify, don't add.)

**`runtime/face/audio_sync.py`**:
- Strip any `sys.path.insert(0, '/home/focal55/...')` lines.
- Strip any `/home/focal55` / `~/iol-monorepo` literal paths.
- No other sanitization needed — research notes the file is a leaf helper.

After edits, both files must still parse as valid Python.
  </action>
  <verify>
```bash
test -f runtime/face/sentiment_classifier.py && \
  test -f runtime/face/audio_sync.py && \
  python3 -c "import ast; [ast.parse(open(f).read()) for f in ['runtime/face/sentiment_classifier.py','runtime/face/audio_sync.py']]" && \
  ! grep -rn 'focal55\|iol-monorepo\|/home/focal55\|joe@focal55\|casa_ybarra\|\.claude/workspace' runtime/face/sentiment_classifier.py runtime/face/audio_sync.py && \
  grep -q '/etc/arlowe/config.yml\|/var/lib/arlowe' runtime/face/sentiment_classifier.py && \
  echo OK
```
  </verify>
  <done>Both files extracted, sanitized, parse cleanly. Sentiment classifier no longer reads ~/.claude/workspace.</done>
</task>

<task type="auto">
  <name>Task 2: Verify sentiment_classifier loads gracefully without /etc/arlowe/config.yml present</name>
  <files>(no files modified — runtime verification only)</files>
  <action>
M6 from the plan-checker review: confirm at runtime (not just by ast.parse) that `sentiment_classifier.py` does not raise on import or on first `classify` call when `/etc/arlowe/config.yml` is absent. This is the actual Phase 1 / not-yet-paired state.

Run from the project root:
```bash
# Confirm /etc/arlowe/config.yml is absent (it should be in Phase 1)
ls -la /etc/arlowe/config.yml 2>&1 || echo "absent (expected)"

# Run the import + classify smoke test
cd runtime && \
PYTHONPATH=. python3 -c "
from face.sentiment_classifier import Sentiment
s = Sentiment()
result = s.classify('hello world')
print('OK:', result)
"
```

Expected: prints `OK: <some sentiment label>` — no `FileNotFoundError`, no traceback, no exit-code 1. The classifier should fall back to the heuristic path silently.

If the smoke test raises:
1. Read the traceback to identify the unguarded read of `CONFIG_PATH` or `CONFIG_OVERLAY`.
2. Wrap the read in `try/except FileNotFoundError` (and any other expected absent-file errors) returning the heuristic default.
3. Re-run the smoke test until it prints `OK: ...`.

Note: this task does NOT modify the file unless a graceful-fallback bug is discovered. In the typical case where Task 1's edits are clean, this is a no-op verification.
  </action>
  <verify>
```bash
cd runtime && PYTHONPATH=. python3 -c "
from face.sentiment_classifier import Sentiment
s = Sentiment()
result = s.classify('hello')
assert result is not None
print('OK')
" 2>&1 | grep -q '^OK$'
```
  </verify>
  <done>Sentiment classifier imports + classifies without raising when /etc/arlowe/config.yml is absent. Heuristic fallback works. M6 closed.</done>
</task>

<task type="auto">
  <name>Task 3: Author runtime/face/requirements.txt and runtime/face/README.md</name>
  <files>
    runtime/face/requirements.txt
    runtime/face/README.md
  </files>
  <action>
**`runtime/face/requirements.txt`**: From the live `~/venvs/voice/bin/pip freeze` (face_service runs in the same venv per research), pin the deps actually imported by the face stack:
- `flask` (face_service is a Flask app — verify by reading the imports)
- `requests` (sentiment_classifier HTTP)
- `numpy` (face animation)
- `Pillow` (rendering)
- (anything else the imports show)

Pin with `==` to live versions. Header:
```
# runtime/face — Python deps for the face HTTP service + sentiment classifier
# Pinned from arlowe-1 ~/venvs/voice/ on $(date -u +%F)
# WhisPlay vendor driver is NOT a pip dep — see third_party/whisplay-driver/PROVENANCE.md
```

**`runtime/face/README.md`**: Cover:
- Module purpose (1 paragraph): face_service exposes tcp/8080; face.py renders to the Whisplay; sentiment_classifier picks expressions.
- Endpoints exposed (extract from face_service.py):
  | Method | Path | Purpose |
  |---|---|---|
  | (whatever face_service has) | | |
- WhisPlay driver dependency — link to `third_party/whisplay-driver/PROVENANCE.md`. State explicitly: face won't render without the driver installed (system-wide today, image-build later).
- Sentiment classifier behaviour:
  - Tries `localhost:8001/v1/chat/completions` (the OpenAI-compat shim)
  - On HTTP error, falls back to `classify_sentiment_heuristic`
  - On absent `/etc/arlowe/config.yml`, falls back gracefully (verified in this plan's Task 2)
  - Phase 1 smoke test passes either path
- How to run locally on arlowe-1:
  ```bash
  cd /path/to/runtime
  PYTHONPATH=. python3 face/face_service.py
  ```
- Known limitations:
  - Sentiment NPU path may be broken depending on plan 13's qwen-openai resolution
  - WhisPlay driver provenance was unresolved at start of Phase 1; resolved in plan 03's Task 2

30-80 lines, plain markdown, no emoji.
  </action>
  <verify>
```bash
test -f runtime/face/requirements.txt && \
  grep -q 'flask\|Flask' runtime/face/requirements.txt && \
  grep -q '==' runtime/face/requirements.txt && \
  test -f runtime/face/README.md && \
  test "$(wc -l < runtime/face/README.md)" -ge 30 && \
  grep -q '8080' runtime/face/README.md && \
  grep -q 'WhisPlay\|whisplay-driver' runtime/face/README.md && \
  echo OK
```
  </verify>
  <done>requirements.txt pins face deps; README documents tcp/8080 contract, sentiment fallback (incl. absent-config behaviour), WhisPlay dependency, and Phase 1 limitations.</done>
</task>

</tasks>

<verification>
Phase-level checks for this plan:

```bash
# Files exist and parse
python3 -c "import ast; [ast.parse(open(f).read()) for f in ['runtime/face/sentiment_classifier.py','runtime/face/audio_sync.py']]"

# No founder literals or .claude/workspace traversal
! grep -rn 'focal55\|iol-monorepo\|/home/focal55\|joe@focal55\|casa_ybarra\|\.claude/workspace' runtime/face/sentiment_classifier.py runtime/face/audio_sync.py

# Sentiment classifier loads gracefully (M6 hard gate)
cd runtime && PYTHONPATH=. python3 -c "from face.sentiment_classifier import Sentiment; Sentiment().classify('hello')"

# README + requirements landed
test -f runtime/face/requirements.txt && grep -q '==' runtime/face/requirements.txt
test -f runtime/face/README.md && [ "$(wc -l < runtime/face/README.md)" -ge 30 ]
```

PR-size: ~535 LOC of source files copied (sentiment_classifier ~292 + audio_sync ~243), ~10-30 lines of surgical edits, ~50-line README + small requirements ≈ 600 raw lines, well under cap given most are verbatim copies. Review-relevant lines (sanitization + new docs) are well under 200.
</verification>

<success_criteria>
- runtime/face/sentiment_classifier.py and runtime/face/audio_sync.py exist, parse cleanly
- Zero founder literals in those files
- Sentiment classifier loads + classifies without `/etc/arlowe/config.yml` present (M6 verified at runtime, not just ast.parse)
- requirements.txt pins versions; README documents the contract
- EXTRACT-02 complete (combined with plan 03)
</success_criteria>

<output>
After completion, create `.planning/phases/01-runtime-extraction/01-03b-SUMMARY.md` documenting:
- Files extracted and LOC
- Sanitization changes (.claude/workspace → /etc/arlowe + /var/lib/arlowe paths)
- M6 graceful-fallback verification result
- Open dependency on plan 04 (tts_sync imports `face.audio_sync`)
- EXTRACT-02 fully closed (this plan + plan 03 together)
</output>
