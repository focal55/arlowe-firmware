# Wake-Word Pipeline

This directory contains the wake-word training and verification scripts for "Hey Arlowe".

## Status

- **v1**: Bare `hey_jarvis` base model from openwakeword (a known proxy for the "Hey Arlowe" phrase
  shape) with an elevated activation threshold. No speaker-specific verifier ships in v1 (per
  WAKE-01: generic model trained on diverse voices).
- **v1 personalization (off by default)**: Owner can opt into recording samples and training a
  verifier overlay. Personalization toggle will be exposed in the dashboard (WAKE-03). Deferred to
  v1.1 (per WAKE-04 in REQUIREMENTS.md).
- **v2 (deferred)**: Personalization flow records owner samples, retrains a personalized model
  overlay, and swaps atomically. False-positive / false-negative rates surface in dashboard health.

## Scripts

| Script | Purpose | Used in |
|---|---|---|
| `auto_collect.py` | Auto-collect "wake" samples during normal use | Personalization (post-pairing) |
| `collect_samples.py` | Interactive mic capture for samples | Personalization (manual mode) |
| `train_verifier.py` | Train a sklearn verifier from samples | Personalization training step |
| `test_verifier.py` | Evaluate a trained verifier against live audio | Diagnostics |
| `quick_test.py` | One-shot wake-word test | Manual ops + smoke test |

## Generic-model swap path

For a clean Pi without a trained verifier:

1. The voice orchestrator (`runtime/voice/voice_client.py`) loads the openwakeword base model
   `hey_jarvis_v0.1`.
2. Set `VERIFIER_MODEL` to None or skip the verifier-stage gate (the model file simply will not
   exist at the default path).
3. Raise the base activation threshold (default 0.5 -> 0.7) to compensate for the lack of
   speaker-specific filtering.
4. Accept higher false-positive rate as the v1 trade-off.

Concretely, in `voice_client.py`:

```python
VERIFIER_MODEL = Path(os.environ.get("ARLOWE_WAKE_WORD_VERIFIER",
                                     "/var/lib/arlowe/wake-word/verifier.pkl"))
if not VERIFIER_MODEL.exists():
    VERIFIER_MODEL = None
    WAKE_THRESHOLD = 0.7
```

Plan 02 wired this via env override; the verifier-absent code path is the v1 generic-model
behaviour.

`quick_test.py` also handles the missing-verifier case gracefully: if the `.pkl` is absent it
runs in base-model-only mode at threshold 0.7.

## Personalization training procedure (post-v1)

When personalization ships:

1. Owner triggers from dashboard.
2. `auto_collect.py` records ~50 wake samples while the user goes about their day (passively gated
   by base-model trigger).
3. `collect_samples.py` runs interactively to fill the negative set with ambient noise.
4. `train_verifier.py` produces `/var/lib/arlowe/wake-word/verifier.pkl`.
5. Voice orchestrator picks it up on next start (no restart-on-change in v1; that is Phase 4
   territory).

## State on disk

| Path | Purpose | Notes |
|---|---|---|
| `/var/lib/arlowe/wake-word/positive/` | Wake samples (.wav) | Owner data; never leaves device |
| `/var/lib/arlowe/wake-word/negative/` | Negative samples (.wav) | Owner data; never leaves device |
| `/var/lib/arlowe/wake-word/verifier.pkl` | Trained verifier | Owner-bound; never leaves device |

All three paths default from `ARLOWE_WAKE_WORD_STATE` (base dir) and `ARLOWE_WAKE_WORD_VERIFIER`
(explicit verifier path). See "Env knobs" below.

## Why no founder data ships in this repo

The script-only extraction is enforced by `.gitignore` (plan 01 added `*.pkl`,
`runtime/wake-word/positive/`, and `runtime/wake-word/negative/`). Defense-in-depth: this plan
also runs `git log --all --diff-filter=A -- '*.pkl' '*.wav'` to confirm no commit ever added
biometric data anywhere in the repo's history.

The founder voice fingerprint is biometric data. Even on the founder's dev unit, the verifier
`.pkl` lives at the on-device state path (outside the repo) and is reachable only via the
`ARLOWE_WAKE_WORD_VERIFIER` env override during the smoke test.

See research file `.planning/phases/01-runtime-extraction/01-RESEARCH.md` sections R6 and
EXTRACT-07.

## Duplicate at whisplay package level (deliberately not extracted)

`~/iol-monorepo/packages/whisplay/wake_word/` exists on arlowe-1 alongside the canonical
`~/wake_word/`. Research Q5 confirmed that `voice_client.py` looks for the verifier under
`~/wake_word/` -- that is the canonical path. The whisplay-level copy (which has its own
`record_negative.py`, `record_positive.py`, `test_wake.py`) was an earlier split and is stale.
Only the canonical `~/wake_word/` scripts were extracted here.

## Env knobs

| Variable | Default | Purpose |
|---|---|---|
| `ARLOWE_VENV_SITE_PACKAGES` | unset | Extra `sys.path` entry for training scripts (set in dev or by image build at `/opt/arlowe/venv/lib/python3.X/site-packages`) |
| `ARLOWE_WAKE_WORD_STATE` | `/var/lib/arlowe/wake-word` | Base dir for samples and verifier |
| `ARLOWE_WAKE_WORD_VERIFIER` | `${ARLOWE_WAKE_WORD_STATE}/verifier.pkl` | Explicit verifier path |
| `ARLOWE_SPEAK_BIN` | `/usr/local/bin/speak` | Path to the speak CLI helper used by auto_collect and quick_test |
| `ARLOWE_ALSA_DEVICE` | `plughw:2,0` | ALSA capture (and playback) device for auto_collect |
