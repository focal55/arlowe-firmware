---
phase: 01-runtime-extraction
plan: 11
type: execute
wave: 2
depends_on: ["01"]
files_modified:
  - runtime/wake-word/auto_collect.py
  - runtime/wake-word/collect_samples.py
  - runtime/wake-word/quick_test.py
  - runtime/wake-word/test_verifier.py
  - runtime/wake-word/train_verifier.py
  - runtime/wake-word/requirements.txt
  - runtime/wake-word/README.md
  - .planning/phases/01-runtime-extraction/01-11-SUMMARY.md
autonomous: true

requirements:
  - "EXTRACT-07: Wake-word training pipeline (~/wake_word/) extracts to runtime/wake-word/; generic-model swap path documented"

must_haves:
  truths:
    - "runtime/wake-word/ contains the 5 training scripts (auto_collect, collect_samples, quick_test, test_verifier, train_verifier)"
    - "Zero .pkl files in runtime/wake-word/ (founder voice fingerprint must NOT enter the repo — research R6)"
    - "Zero .wav files in runtime/wake-word/ (founder voice samples must NOT enter the repo)"
    - "git history contains zero added `.pkl` or `.wav` files anywhere in the repo (defense-in-depth: gitignore caught the file-system check, history check confirms no past leak)"
    - "Zero `/home/focal55/...` references; venv path injection uses env override"
    - "README documents the generic-model swap path and the personalization-deferred-to-v1.1 status"
  artifacts:
    - path: "runtime/wake-word/auto_collect.py"
      provides: "Auto sample collection script"
    - path: "runtime/wake-word/collect_samples.py"
      provides: "Manual sample collection"
    - path: "runtime/wake-word/quick_test.py"
      provides: "Quick wake test"
    - path: "runtime/wake-word/test_verifier.py"
      provides: "Verifier evaluation"
    - path: "runtime/wake-word/train_verifier.py"
      provides: "Verifier training"
    - path: "runtime/wake-word/requirements.txt"
      provides: "Pinned PyPI deps"
    - path: "runtime/wake-word/README.md"
      provides: "Pipeline doc, generic-model swap path, personalization roadmap"
      min_lines: 50
  key_links:
    - from: "runtime/wake-word/train_verifier.py"
      to: "openwakeword (PyPI)"
      via: "import openwakeword"
      pattern: "openwakeword"
---

<objective>
Extract the wake-word training pipeline from `~/wake_word/` (founder home) into `runtime/wake-word/`. Per research §EXTRACT-07 / R6: copy the SCRIPTS only, NEVER copy `hey_arlowe_verifier.pkl` (founder biometric fingerprint) or any `.wav` file from `positive/` or `negative/`. Document the generic-model swap path (use bare `hey_jarvis` base model with elevated threshold until a generic verifier exists).

Purpose: Land EXTRACT-07. The smoke test in plan 13 still uses the founder's `.pkl` (symlinked from arlowe-1's home — does NOT enter the repo), since v1's generic model path is documented but not built. WAKE-01 (generic model in image) is Phase 8 territory.

Output: `runtime/wake-word/` populated with sanitized training scripts, no biometric data, README documenting paths forward.
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
  <name>Task 1: Copy wake-word scripts from Pi mirror, NEVER touch .pkl or .wav</name>
  <files>
    runtime/wake-word/auto_collect.py
    runtime/wake-word/collect_samples.py
    runtime/wake-word/quick_test.py
    runtime/wake-word/test_verifier.py
    runtime/wake-word/train_verifier.py
  </files>
  <action>
Plan 01's `dev-pull-from-pi.sh` already excludes `*.pkl`, `positive/`, and `negative/` from the wake_word mirror. So `.dev-stash/arlowe-1/wake_word/` should be safe to copy from.

Copy verbatim (no edits yet):
```bash
for f in auto_collect.py collect_samples.py quick_test.py test_verifier.py train_verifier.py; do
  cp .dev-stash/arlowe-1/wake_word/$f runtime/wake-word/$f
done
```

If `~/wake_word/README.md` exists in the mirror, do NOT copy it — we author a fresh, sanitized one in Task 4.

Belt-and-suspenders check that no biometric data slipped in (file-system + git-history):
```bash
# Filesystem check (already-tracked + untracked)
find runtime/wake-word/ -name '*.pkl' -o -name '*.wav' -o -name 'positive' -o -name 'negative'
# MUST return empty.

# Git-history check (defense-in-depth: confirm no prior commit added biometric data anywhere in repo)
git log --all --diff-filter=A -- '*.pkl' '*.wav'
# MUST return empty (no commits added .pkl or .wav files anywhere). If anything appears,
# investigate and either git-filter-repo it out or document why it's there before proceeding.
```

Also: research §Q5 noted there's a duplicate copy of wake-word scripts at `~/iol-monorepo/packages/whisplay/wake_word/`. The canonical is `~/wake_word/` (where voice_client.py looks for the verifier). For the duplicate at the whisplay package level — record in this plan's SUMMARY that we IGNORED it. If anyone ever wonders why it's not extracted, the answer is: the canonical lives at `~/wake_word/`.
  </action>
  <verify>
```bash
for f in auto_collect.py collect_samples.py quick_test.py test_verifier.py train_verifier.py; do
  test -f runtime/wake-word/$f || { echo "missing $f"; exit 1; }
  python3 -c "import ast; ast.parse(open('runtime/wake-word/$f').read())" || exit 1
done
# CRITICAL: no biometric data on disk
test -z "$(find runtime/wake-word/ -name '*.pkl' -o -name '*.wav' -o -type d -name 'positive' -o -type d -name 'negative')" && \
  # CRITICAL: no biometric data ever committed (Mn3 — git-history defense-in-depth)
  test -z "$(git log --all --diff-filter=A --name-only -- '*.pkl' '*.wav' 2>/dev/null)" && \
  echo OK
```
  </verify>
  <done>5 scripts copied, all parse as valid Python, zero .pkl/.wav files on disk, zero .pkl/.wav files ever committed (git-history sweep), zero positive/negative directories. R6 enforced at both filesystem and git-history layers.</done>
</task>

<task type="auto">
  <name>Task 2: Sanitize venv path injection in train_verifier.py and any other scripts</name>
  <files>
    runtime/wake-word/train_verifier.py
    runtime/wake-word/auto_collect.py
    runtime/wake-word/collect_samples.py
    runtime/wake-word/quick_test.py
    runtime/wake-word/test_verifier.py
  </files>
  <action>
Per research §EXTRACT-07, `train_verifier.py` has:
```python
sys.path.insert(0, '/home/focal55/venvs/voice/lib/python3.13/site-packages')
```

Replace in `train_verifier.py` (and any sibling that has the same pattern) with:
```python
import os, sys
_extra = os.environ.get("ARLOWE_VENV_SITE_PACKAGES")
if _extra and _extra not in sys.path:
    sys.path.insert(0, _extra)
```

This is a clean env-override pattern. The image build (Phase 6) sets `ARLOWE_VENV_SITE_PACKAGES=/opt/arlowe/venv/lib/python3.X/site-packages` if needed; Phase 1 dev on arlowe-1 sets it to the live venv.

Other sanitization across all 5 scripts:
1. Strip any other `/home/focal55/...` references — replace with `${ARLOWE_WAKE_WORD_DIR}/...` style or hardcoded `/var/lib/arlowe/wake-word/` paths for state files (`.pkl` lookups, sample directories).
2. Specifically: `train_verifier.py` and `test_verifier.py` likely reference `~/wake_word/positive/`, `~/wake_word/negative/`, and `~/wake_word/hey_arlowe_verifier.pkl`. Reroute:
   - `~/wake_word/positive/` → `${ARLOWE_WAKE_WORD_STATE:-/var/lib/arlowe/wake-word}/positive/`
   - `~/wake_word/negative/` → same prefix `/negative/`
   - `~/wake_word/hey_arlowe_verifier.pkl` → `${ARLOWE_WAKE_WORD_VERIFIER:-/var/lib/arlowe/wake-word/verifier.pkl}`
3. Confirm imports of `openwakeword` and `numpy` etc. stay clean (no path hacks).

After edits, every file must parse.
  </action>
  <verify>
```bash
! grep -rn 'focal55\|/home/focal55\|/home/focal55/venvs' runtime/wake-word/ && \
  for f in auto_collect.py collect_samples.py quick_test.py test_verifier.py train_verifier.py; do
    python3 -c "import ast; ast.parse(open('runtime/wake-word/$f').read())" || exit 1
  done && \
  grep -q 'ARLOWE_WAKE_WORD\|/var/lib/arlowe/wake-word' runtime/wake-word/train_verifier.py && \
  echo OK
```
  </verify>
  <done>All scripts sanitized; venv path is env-overridable; state paths point at /var/lib/arlowe/wake-word with env override.</done>
</task>

<task type="auto">
  <name>Task 3: Author runtime/wake-word/requirements.txt</name>
  <files>runtime/wake-word/requirements.txt</files>
  <action>
Pin PyPI deps that the 5 scripts need. Most likely:
- `openwakeword` (the bare base model + verifier framework)
- `numpy`
- `pyaudio` (mic capture in `collect_samples.py`)
- `scikit-learn` (verifier is a sklearn classifier per research)
- `joblib` (sklearn pickle helper)
- (anything else the imports show)

Pin from arlowe-1 voice venv:
```bash
ssh arlowe-1 '~/venvs/voice/bin/pip freeze | grep -iE "openwakeword|scikit-learn|joblib|pyaudio|numpy"'
```

Use `==` pins. Header:
```
# runtime/wake-word — training + testing deps
# Pinned from arlowe-1 ~/venvs/voice/
# Note: shared with runtime/voice — keep versions in sync if both import openwakeword.
```
  </action>
  <verify>
```bash
test -f runtime/wake-word/requirements.txt && \
  grep -q 'openwakeword==' runtime/wake-word/requirements.txt && \
  grep -q 'scikit-learn==' runtime/wake-word/requirements.txt && \
  echo OK
```
  </verify>
  <done>requirements.txt pins wake-word deps, version-aligned with the voice client to prevent drift.</done>
</task>

<task type="auto">
  <name>Task 4: Author runtime/wake-word/README.md (generic-model swap path)</name>
  <files>runtime/wake-word/README.md</files>
  <action>
Author `runtime/wake-word/README.md`:

```markdown
# Wake-Word Pipeline

This directory contains the wake-word training and verification scripts for "Hey Arlowe".

## Status

- **v1**: Bare `hey_jarvis` base model from openwakeword (a known proxy for the "Hey Arlowe" phrase shape) with an elevated activation threshold. NO speaker-specific verifier ships in v1 (per WAKE-01: generic model trained on diverse voices).
- **v1 personalization (off by default)**: Owner can opt into recording samples and training a verifier overlay in a future phase. Personalization toggle exposed in the dashboard (WAKE-03).
- **v2 (deferred)**: Personalization flow records owner samples, retrains a personalized model overlay, and swaps atomically. False-positive / false-negative rates surface in dashboard health.

## Scripts

| Script | Purpose | Used in |
|---|---|---|
| `auto_collect.py` | Auto-collect "wake" samples during normal use | Personalization (post-pairing) |
| `collect_samples.py` | Interactive mic capture for samples | Personalization (manual mode) |
| `train_verifier.py` | Train a sklearn verifier from samples | Personalization training step |
| `test_verifier.py` | Evaluate a trained verifier against held-out audio | Diagnostics |
| `quick_test.py` | One-shot wake-word test | Manual ops + smoke test |

## Generic-model swap path

For a clean Pi without a trained verifier:
1. The voice orchestrator (`runtime/voice/voice_client.py`) loads the openwakeword base model `hey_jarvis_v0.1`.
2. Set `VERIFIER_MODEL` to None or skip the verifier-stage gate.
3. Raise the base activation threshold (default 0.5 → 0.7) to compensate for the lack of speaker-specific filtering.
4. Accept higher false-positive rate as the v1 trade-off.

Concretely, in `voice_client.py`:
```python
VERIFIER_MODEL = Path(os.environ.get("ARLOWE_WAKE_WORD_VERIFIER", "/var/lib/arlowe/wake-word/verifier.pkl"))
if not VERIFIER_MODEL.exists():
    VERIFIER_MODEL = None
    WAKE_THRESHOLD = 0.7
```
(Plan 02 wired this via env override; the verifier-absent code path is the v1 generic-model behaviour.)

## Personalization training procedure (post-v1)

When personalization ships:
1. Owner triggers from dashboard.
2. `auto_collect.py` records ~50 wake samples while the user goes about their day (passively gated by base-model trigger).
3. `collect_samples.py` runs interactively to fill the negative set with ambient noise.
4. `train_verifier.py` produces `/var/lib/arlowe/wake-word/verifier.pkl`.
5. Voice orchestrator picks it up on next start (no restart logic in v1; restart-on-change is Phase 4 territory).

## State on disk

| Path | Purpose | Notes |
|---|---|---|
| `/var/lib/arlowe/wake-word/positive/` | Wake samples (.wav) | Owner data; never leaves device |
| `/var/lib/arlowe/wake-word/negative/` | Negative samples (.wav) | Owner data |
| `/var/lib/arlowe/wake-word/verifier.pkl` | Trained verifier | Owner-bound; never leaves device |

## Why no founder data ships in this repo

The script-only extraction is enforced by `.gitignore` (plan 01 added `*.pkl` + `runtime/wake-word/positive/` + `runtime/wake-word/negative/`). Defense-in-depth: this plan also runs `git log --all --diff-filter=A -- '*.pkl' '*.wav'` to confirm no commit ever added biometric data anywhere in the repo's history. Founder voice fingerprint is biometric data; even on the founder's dev unit, the verifier `.pkl` lives at `~/wake_word/...` (outside the repo) and is reachable only via `ARLOWE_WAKE_WORD_VERIFIER` env override during the smoke test.

See research file `.planning/phases/01-runtime-extraction/01-RESEARCH.md` §R6, §EXTRACT-07.

## Env knobs

- `ARLOWE_VENV_SITE_PACKAGES` — extra `sys.path` entry for training (set in dev; image build provides via /opt/arlowe/venv).
- `ARLOWE_WAKE_WORD_STATE` (default `/var/lib/arlowe/wake-word`) — base for samples + verifier.
- `ARLOWE_WAKE_WORD_VERIFIER` (default `/var/lib/arlowe/wake-word/verifier.pkl`) — explicit verifier path.
```

50-100 lines. Plain markdown, no emoji.
  </action>
  <verify>
```bash
test -f runtime/wake-word/README.md && \
  test "$(wc -l < runtime/wake-word/README.md)" -ge 50 && \
  grep -qi 'generic.model\|hey_jarvis' runtime/wake-word/README.md && \
  grep -qi 'biometric\|R6' runtime/wake-word/README.md && \
  grep -qi 'personalization' runtime/wake-word/README.md && \
  echo OK
```
  </verify>
  <done>README documents the pipeline, generic-model swap path, personalization deferral, and the no-founder-data principle (filesystem + git-history defense).</done>
</task>

</tasks>

<verification>
Phase-level checks:

```bash
# All 5 scripts exist + parse
for f in auto_collect.py collect_samples.py quick_test.py test_verifier.py train_verifier.py; do
  python3 -c "import ast; ast.parse(open('runtime/wake-word/$f').read())"
done

# CRITICAL: no biometric data anywhere on disk
! find runtime/wake-word/ -name '*.pkl' -o -name '*.wav' -o -type d -name 'positive' -o -type d -name 'negative' | grep -q .

# CRITICAL: no biometric data ever committed (Mn3 — defense-in-depth)
test -z "$(git log --all --diff-filter=A --name-only -- '*.pkl' '*.wav' 2>/dev/null)"

# No founder literals
! grep -rn 'focal55\|/home/focal55' runtime/wake-word/

# .gitignore enforces the rule (defense in depth — already added in plan 01)
grep -q '\*\.pkl' .gitignore
```
</verification>

<success_criteria>
- 5 scripts in runtime/wake-word/, parse cleanly
- Zero .pkl files, zero .wav files, zero positive/negative directories (R6 enforced at file system level)
- `git log --all --diff-filter=A -- '*.pkl' '*.wav'` returns empty (R6 enforced at git-history level — Mn3)
- Venv path uses env override
- requirements.txt pins shared deps
- README documents the generic-model path and personalization deferral
- EXTRACT-07 complete
</success_criteria>

<output>
After completion, create `.planning/phases/01-runtime-extraction/01-11-SUMMARY.md` documenting:
- Scripts extracted
- Sanitization edits per script
- R6 enforcement (no biometric data) verified at both filesystem and git-history layers (Mn3)
- Note that the duplicate `~/iol-monorepo/packages/whisplay/wake_word/` was deliberately not extracted (research Q5)
</output>
