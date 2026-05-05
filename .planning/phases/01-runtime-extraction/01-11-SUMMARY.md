# Plan 11 Summary -- Wake-Word Training Pipeline Extraction

**Plan:** 11
**Phase:** 01-runtime-extraction
**Completed:** 2026-05-02

## Scripts extracted

All 5 scripts from canonical source ~/wake_word/ (via .dev-stash/arlowe-1/wake_word/):

| Script | Source LOC | Sanitization needed |
|---|---|---|
| auto_collect.py | 91 | /home/focal55/bin/speak -> env override; hardcoded plughw:2,0 -> env |
| collect_samples.py | 186 | SAMPLE_DIR-relative positive/negative dirs -> ARLOWE_WAKE_WORD_STATE env |
| quick_test.py | 79 | venv path hack; /home/focal55/bin/speak -> env; hardcoded verifier -> env; added graceful no-verifier path |
| test_verifier.py | 114 | venv path hack; hardcoded SAMPLE_DIR/hey_arlowe_verifier.pkl -> env |
| train_verifier.py | 75 | venv path hack; SAMPLE_DIR-relative positive/negative/output -> env |

## Sanitization edits per script

### All scripts with venv path hack (train_verifier.py, test_verifier.py, quick_test.py)

Before:
  sys.path.insert(0, '/home/focal55/venvs/voice/lib/python3.13/site-packages')

After:
  _extra = os.environ.get("ARLOWE_VENV_SITE_PACKAGES")
  if _extra and _extra not in sys.path:
      sys.path.insert(0, _extra)

### State paths (all 5 scripts)

All SAMPLE_DIR-relative paths to positive/, negative/, and hey_arlowe_verifier.pkl replaced with:
  _STATE_DIR = os.environ.get("ARLOWE_WAKE_WORD_STATE", "/var/lib/arlowe/wake-word")
  VERIFIER_MODEL = os.environ.get("ARLOWE_WAKE_WORD_VERIFIER", os.path.join(_STATE_DIR, "verifier.pkl"))

### speak helper (auto_collect.py, quick_test.py)

Before: subprocess.run(["/home/focal55/bin/speak", text], ...)
After:  ARLOWE_SPEAK_BIN env var defaulting to /usr/local/bin/speak; guarded with os.path.exists check.

### ALSA device (auto_collect.py)

Before: hardcoded plughw:2,0
After:  ARLOWE_ALSA_DEVICE env var defaulting to plughw:2,0

### quick_test.py -- added graceful no-verifier code path

Original assumed verifier always present and crashed on missing file. Sanitized version detects
missing verifier on startup and falls back to base-model-only mode at threshold 0.7 (the
generic-model path from the README).

## R6 enforcement -- biometric data excluded (Mn3)

### Filesystem layer

.gitignore (added in plan 01) already excludes: *.pkl, runtime/wake-word/positive/,
runtime/wake-word/negative/, runtime/wake-word/*.pkl. Verified via find command -- empty.

### Git-history layer (defense-in-depth)

git log --all --diff-filter=A --name-only -- '*.pkl' '*.wav' -- empty (no commit has ever added
biometric data).

### rsync excludes (source layer)

scripts/dev-pull-from-pi.sh already has --exclude='*.pkl' --exclude='positive/' --exclude='negative/'
on the wake_word/ rsync target. Dry-run confirmed excludes are active.

## Canonical source decision

Research Q5 identified a duplicate at ~/iol-monorepo/packages/whisplay/wake_word/ with an older
split (record_negative.py, record_positive.py, test_wake.py). Only the canonical ~/wake_word/ was
extracted -- the path where voice_client.py resolves the verifier. The whisplay-level copy is stale
and was not extracted.

## Artifacts produced

- runtime/wake-word/auto_collect.py
- runtime/wake-word/collect_samples.py
- runtime/wake-word/quick_test.py
- runtime/wake-word/test_verifier.py
- runtime/wake-word/train_verifier.py
- runtime/wake-word/requirements.txt (pinned from arlowe-1 ~/venvs/voice/)
- runtime/wake-word/README.md (>50 lines; documents generic-model swap path, personalization deferral, R6 enforcement)
