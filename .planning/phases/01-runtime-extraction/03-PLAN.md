---
phase: 01-runtime-extraction
plan: 03
type: execute
wave: 2
depends_on: ["01"]
files_modified:
  - runtime/face/face_service.py
  - runtime/face/face.py
  - runtime/face/sentiment_classifier.py
  - runtime/face/audio_sync.py
  - runtime/face/requirements.txt
  - runtime/face/README.md
  - third_party/whisplay-driver/PROVENANCE.md
  - .planning/phases/01-runtime-extraction/01-03-SUMMARY.md
autonomous: true

requirements:
  - "EXTRACT-02: face_service.py, face.py, sentiment_classifier.py, audio_sync.py extract to runtime/face/; tcp/8080 face service preserved"

must_haves:
  truths:
    - "runtime/face/face_service.py exists and serves the tcp/8080 face control surface"
    - "runtime/face/face.py exists and the WhisPlayBoard import is documented as a third-party dependency"
    - "runtime/face/sentiment_classifier.py reads its config from /etc/arlowe/config.yml fallback path, not ~/.claude/workspace/whisplay-config.json"
    - "third_party/whisplay-driver/PROVENANCE.md records driver source, license investigation, and a decision about vendoring vs image-build dependency (research Q2 / R3)"
    - "audio_sync.py is colocated under runtime/face/ as the canonical copy (referenced by tts_sync.py via a relative import in plan 04)"
  artifacts:
    - path: "runtime/face/face_service.py"
      provides: "tcp/8080 face HTTP service (face state setter, mouth lip-sync stream)"
      min_lines: 150
    - path: "runtime/face/face.py"
      provides: "WhisPlay rendering primitives"
      min_lines: 500
      contains: "WhisPlayBoard"
    - path: "runtime/face/sentiment_classifier.py"
      provides: "Sentiment classification (NPU + heuristic fallback)"
      min_lines: 200
    - path: "runtime/face/audio_sync.py"
      provides: "Mouth animation sync helper"
      min_lines: 200
    - path: "runtime/face/requirements.txt"
      provides: "Pinned PyPI deps"
    - path: "runtime/face/README.md"
      provides: "Documents the tcp/8080 contract, WhisPlay driver dependency, sentiment fallback behaviour"
      min_lines: 30
    - path: "third_party/whisplay-driver/PROVENANCE.md"
      provides: "WhisPlay vendor SDK provenance + license investigation + vendoring decision"
      min_lines: 30
  key_links:
    - from: "runtime/face/face.py"
      to: "WhisPlayBoard vendor driver"
      via: "imports WhisPlayBoard at module load"
      pattern: "from WhisPlay import|import WhisPlay"
    - from: "runtime/face/sentiment_classifier.py"
      to: "/etc/arlowe/config.yml (with fallback)"
      via: "reads CONFIG_PATH"
      pattern: "/etc/arlowe/config.yml|/var/lib/arlowe"
---

<objective>
Extract the face stack (`face_service.py`, `face.py`, `sentiment_classifier.py`, `audio_sync.py`) from `~/iol-monorepo/packages/whisplay/` into `runtime/face/`. Sanitize hardcoded `~/.claude/workspace/` reads and `/home/focal55/...` paths. Resolve the WhisPlay vendor driver provenance (research Q2 / R3) — document source, license, and vendoring decision.

Purpose: Land EXTRACT-02. The face service is the visual half of the smoke test (talking-blue / pink-flash / idle). Sentiment classifier feeds the face — but its config-path coupling to the founder's Claude workspace must die.

Output: `runtime/face/` populated and sanitized; `third_party/whisplay-driver/PROVENANCE.md` resolves R3 (the single biggest non-runtime blocker for face rendering on a clean Pi).
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
  <name>Task 1: Copy face files from Pi mirror and place under runtime/face/</name>
  <files>
    runtime/face/face_service.py
    runtime/face/face.py
    runtime/face/sentiment_classifier.py
    runtime/face/audio_sync.py
  </files>
  <action>
Assumes plan 01's `scripts/dev-pull-from-pi.sh --apply` has already populated `.dev-stash/arlowe-1/whisplay/`. If not, run it.

Copy verbatim (no edits yet) from `.dev-stash/arlowe-1/whisplay/` to `runtime/face/`:
- `face_service.py` (~202 LOC)
- `face.py` (~667 LOC)
- `sentiment_classifier.py` (~292 LOC)
- `audio_sync.py` (~243 LOC)

Note: `audio_sync.py` is shared with `tts_sync.py` (plan 04). Per research, "single copy, not duplicated" — runtime/face/ is the canonical location and plan 04's tts_sync.py imports from `face.audio_sync`.
  </action>
  <verify>
```bash
test -f runtime/face/face_service.py && \
  test -f runtime/face/face.py && \
  test -f runtime/face/sentiment_classifier.py && \
  test -f runtime/face/audio_sync.py && \
  python3 -c "import ast; [ast.parse(open(f).read()) for f in ['runtime/face/face_service.py','runtime/face/face.py','runtime/face/sentiment_classifier.py','runtime/face/audio_sync.py']]" && \
  echo OK
```
  </verify>
  <done>All four files copied verbatim; each parses as valid Python.</done>
</task>

<task type="auto">
  <name>Task 2: Sanitize face stack — paths, config sources, WhisPlay driver loader</name>
  <files>
    runtime/face/face.py
    runtime/face/sentiment_classifier.py
    runtime/face/face_service.py
    runtime/face/audio_sync.py
  </files>
  <action>
Apply per-file sanitization (per research §EXTRACT-02):

**`runtime/face/face.py` (L18 area)**:
The line is currently:
```python
sys.path.insert(0, '/home/focal55/Library/Whisplay/Driver')
from WhisPlay import WhisPlayBoard
```
Replace with:
```python
# WhisPlay vendor SDK lookup — see third_party/whisplay-driver/PROVENANCE.md
# At runtime, the driver is expected at /opt/arlowe/third_party/whisplay-driver/.
# For dev on arlowe-1 we honour an env override.
import os
_WHISPLAY_DRIVER_PATH = os.environ.get(
    "ARLOWE_WHISPLAY_DRIVER_PATH",
    "/opt/arlowe/third_party/whisplay-driver",
)
if _WHISPLAY_DRIVER_PATH not in sys.path:
    sys.path.insert(0, _WHISPLAY_DRIVER_PATH)
from WhisPlay import WhisPlayBoard
```

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
- Update any code that reads `CONFIG_PATH` to gracefully handle the file being absent (this is the Phase-1 "not-yet-paired" state).
- Confirm the heuristic fallback (`classify_sentiment_heuristic`) is still wired into the call path. (Per research, it already is — verify, don't add.)

**`runtime/face/face_service.py`**:
- Search for any HTML title or banner string referencing `arlowe-1` (research notes there is one). Replace with cosmetic-neutral `"Arlowe Face"`.
- Search for any `/home/focal55` paths and replace with `/var/lib/arlowe/...` equivalents.
- Search for any imports of `face` (without package prefix) and rewrite to `from face.face import ...` or `from .face import ...` depending on package style chosen (pick one and apply consistently across the file).

**`runtime/face/audio_sync.py`**:
- Strip any `sys.path.insert(0, '/home/focal55/...')` lines.
- Strip any `/home/focal55` / `~/iol-monorepo` literal paths.
- No other sanitization needed — research notes the file is a leaf helper.

After edits, all four files must still parse as valid Python.
  </action>
  <verify>
```bash
# No founder literals
! grep -rn 'focal55\|iol-monorepo\|/home/focal55\|joe@focal55\|casa_ybarra\|arlowe-1' runtime/face/

# WhisPlay driver path is now env-overridable, points at /opt/arlowe by default
grep -q 'ARLOWE_WHISPLAY_DRIVER_PATH' runtime/face/face.py
grep -q '/opt/arlowe/third_party/whisplay-driver' runtime/face/face.py

# Sentiment config no longer reads ~/.claude
! grep -n '\.claude/workspace' runtime/face/sentiment_classifier.py
grep -q '/etc/arlowe/config.yml\|/var/lib/arlowe' runtime/face/sentiment_classifier.py

# Files still parse
python3 -c "import ast; [ast.parse(open(f).read()) for f in ['runtime/face/face.py','runtime/face/face_service.py','runtime/face/sentiment_classifier.py','runtime/face/audio_sync.py']]"

echo OK
```
  </verify>
  <done>Zero founder literals in runtime/face/. WhisPlay driver path is env-overridable. Sentiment classifier reads config-overlay-aware paths, not ~/.claude/workspace.</done>
</task>

<task type="auto">
  <name>Task 3: Resolve WhisPlay driver provenance and decision</name>
  <files>third_party/whisplay-driver/PROVENANCE.md</files>
  <action>
This task closes research Q2 / risk R3 — the WhisPlay vendor SDK provenance is currently unknown.

Investigation steps (run from a Mac terminal with arlowe-1 SSH):
```bash
ssh arlowe-1 'ls -la ~/Library/Whisplay/Driver/'
ssh arlowe-1 'cat ~/Library/Whisplay/Driver/install_wm8960_drive.sh 2>/dev/null | head -50'
ssh arlowe-1 'find ~/Library/Whisplay -name "*.md" -o -name "LICENSE*" -o -name "README*" 2>/dev/null'
ssh arlowe-1 'head -30 ~/Library/Whisplay/Driver/WhisPlay.py'
```
Plus a web search for "WhisPlay Pi 5 display board driver" / GitHub search for `WhisPlayBoard`.

Author `third_party/whisplay-driver/PROVENANCE.md` with these sections:
1. **Source** — vendor name, GitHub repo (if public), download URL, install script path on the Pi
2. **License** — captured license text or "license unknown — see decision below"
3. **Files needed** — concrete list (`WhisPlay.py`, any `.so` or kernel modules, the `install_wm8960_drive.sh` audio HAT installer)
4. **Vendoring decision** — pick one:
   - **(a) Vendor source under `third_party/whisplay-driver/`** if license permits
   - **(b) Image-build dependency** — driver is downloaded/installed via pi-gen at image build time, not committed
   - **(c) Block the smoke test on resolution** — record what's needed and from whom
5. **Phase 1 implication** — the smoke test on Joe's arlowe-1 already has the driver installed system-wide (via `~/Library/Whisplay/Driver/`); the smoke test passes regardless of the vendoring decision. The decision affects Phase 6 (image build), not Phase 1.
6. **Action items** — concrete TODOs (e.g., "email vendor for license", "PR to vendor a fork under MIT", "find an open-source replacement")

If license is unknown after investigation, recommend **(c) block** for image build but note Phase 1 smoke test is unaffected. Be honest in the doc.

Length target: 30-80 lines. Plain markdown, no emoji. Reference research file at `.planning/phases/01-runtime-extraction/01-RESEARCH.md` §R3.
  </action>
  <verify>
```bash
test -f third_party/whisplay-driver/PROVENANCE.md && \
  test "$(wc -l < third_party/whisplay-driver/PROVENANCE.md)" -ge 30 && \
  grep -qi 'license' third_party/whisplay-driver/PROVENANCE.md && \
  grep -qi 'decision' third_party/whisplay-driver/PROVENANCE.md && \
  grep -qi 'phase 1' third_party/whisplay-driver/PROVENANCE.md && \
  echo OK
```
  </verify>
  <done>PROVENANCE.md captures source, license investigation, vendoring decision (a/b/c), Phase 1 implication, and concrete next steps. Research R3 is no longer an unknown.</done>
</task>

<task type="auto">
  <name>Task 4: Author runtime/face/requirements.txt and runtime/face/README.md</name>
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
  - Phase 1 smoke test passes either path
- How to run locally on arlowe-1:
  ```bash
  cd /path/to/runtime
  PYTHONPATH=. python3 face/face_service.py
  ```
- Known limitations:
  - Sentiment NPU path may be broken depending on plan 13's qwen-openai resolution
  - WhisPlay driver provenance unresolved at start of Phase 1; resolved in this plan's Task 3

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
  <done>requirements.txt pins face deps; README documents tcp/8080 contract, sentiment fallback, WhisPlay dependency, and Phase 1 limitations.</done>
</task>

</tasks>

<verification>
Phase-level checks for this plan:

```bash
# Files exist and parse
python3 -c "import ast; [ast.parse(open(f).read()) for f in ['runtime/face/face_service.py','runtime/face/face.py','runtime/face/sentiment_classifier.py','runtime/face/audio_sync.py']]"

# No founder literals
! grep -rn 'focal55\|iol-monorepo\|/home/focal55\|joe@focal55\|casa_ybarra\|arlowe-1\|\.claude/workspace' runtime/face/

# WhisPlay driver loader is parameterized
grep -q 'ARLOWE_WHISPLAY_DRIVER_PATH' runtime/face/face.py

# PROVENANCE doc exists with the required sections
grep -qi 'license\|decision\|source' third_party/whisplay-driver/PROVENANCE.md
```

PR-size check: ~1400 LOC of source files copied (the bulk is mechanical), ~10-30 lines of surgical edits, ~50 line README + provenance doc + requirements. Net <600 lines is unlikely given face.py alone is 667 LOC. **PR-size note**: If the reviewer flags this as too large, the file copies don't count as "new logic" in code review — the diff for review purposes is the sanitization edits + the new docs. Confirm with reviewer convention; if hard cap is enforced, split this plan into 03a (copy + face.py sanitize) and 03b (sentiment + service + README + PROVENANCE).
</verification>

<success_criteria>
- All four face files exist in runtime/face/ and parse as valid Python
- Zero `focal55`, `iol-monorepo`, `casa_ybarra`, `arlowe-1`, `.claude/workspace` literals in runtime/face/
- WhisPlay driver path is env-overridable (defaults to `/opt/arlowe/third_party/whisplay-driver`)
- Sentiment classifier no longer reads from `~/.claude/workspace`
- `third_party/whisplay-driver/PROVENANCE.md` records source/license/vendoring decision (closes R3)
- requirements.txt pins versions; README documents the contract
</success_criteria>

<output>
After completion, create `.planning/phases/01-runtime-extraction/01-03-SUMMARY.md` documenting:
- Files extracted and LOC
- Sanitization changes per file
- WhisPlay driver provenance findings + decision
- Open dependencies on plan 02 (voice imports `face.sentiment_classifier`) and plan 04 (tts imports `face.audio_sync`)
</output>
