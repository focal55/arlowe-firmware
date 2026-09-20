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

## The wake decision: `runtime/voice/wake_gate.py`

The accept policy lives in one module, `runtime/voice/wake_gate.py`. It is stdlib-only on purpose
(no numpy, no sklearn, no openwakeword) so the thresholds are testable without the voice venv, and
so the shipping path has exactly one definition of each number. `voice_client.py` builds a
`WakeGate` at startup and routes every base-model activation through `gate.evaluate(...)`.

| Mode | Selected when | Base gate | Verifier gate |
|---|---|---|---|
| **generic** (shipped in v1) | no readable verifier `.pkl` | `> 0.7` | none |
| **personalized** (post-v1, opt-in) | verifier `.pkl` loads | `> 0.20` | `> 0.30` |

Generic is the factory state of every device: nothing writes the verifier until the owner opts into
personalization (WAKE-03 / WAKE-04). The base threshold is raised to 0.7 in that mode to compensate
for the missing speaker-specific filtering, and the higher false-positive rate is the accepted v1
trade-off. Feature extraction is invoked only in personalized mode and only after the base score
clears the pre-filter, so a generic device never pays for it.

A verifier file that exists but cannot be unpickled -- truncated, half-written, corrupt -- is
treated as absent: `load_verifier` logs to stderr and returns `None`, and the device runs generic.
A broken personalization file must not stop the unit booting.

The startup journal line names the active mode explicitly:

```
[2/4] Wake gate: generic model, base threshold 0.7 (no verifier at ... - device not personalized)
[2/4] Wake gate: personalized (verifier /var/lib/arlowe/wake-word/verifier.pkl)
```

Proof: `runtime/voice/tests/test_wake_gate.py`, which covers the absent, present, corrupt and
truncated cases and asserts that the feature callable is never invoked in generic mode. It runs
under a bare `python3` plus `pytest`:

```
PYTHONPATH=runtime python3 -m pytest runtime/voice/tests/test_wake_gate.py -q
```

> **Correction (Phase 7.1, 2026-09):** the version of this section before Phase 7.1 documented an
> `if not VERIFIER_MODEL.exists(): WAKE_THRESHOLD = 0.7` branch and asserted that an earlier plan
> had already wired it via env override. **No such branch existed in the code.** `voice_client.py`
> opened the verifier
> pickle unguarded, so `arlowe-voice` raised `FileNotFoundError` on every factory device and
> `Restart=on-failure` looped it forever. The behaviour described above was implemented in plan
> 07.1-02; this note stays here rather than quietly overwriting the false claim, because a document
> asserting a fix that was never made is the failure mode that cost this repo seven weeks on
> Phase 7.
>
> The same section also named the wrong environment variable. `voice_client.py` reads
> **`ARLOWE_VERIFIER_MODEL`**; the training and diagnostic scripts in this directory read
> `ARLOWE_WAKE_WORD_VERIFIER`. They are separate knobs and setting only one of them will not move
> the orchestrator's path. `docs/operations/phase-1-smoke-test.md` records this exact mix-up
> burning a debug cycle on the Phase 1 smoke test.

The diagnostic scripts in this directory do **not** import `wake_gate` and carry their own
hardcoded numbers: `quick_test.py` falls back to base-model-only at 0.7 / verifier 0.5, and
`test_verifier.py` sweeps at base 0.3 / verifier 0.6. They are bench tools, deliberately tunable
away from the shipping policy. Do not read their thresholds as the device's behaviour.

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

For the scripts in this directory, all three paths default from `ARLOWE_WAKE_WORD_STATE` (base dir)
and `ARLOWE_WAKE_WORD_VERIFIER` (explicit verifier path). The voice orchestrator resolves the
verifier from `ARLOWE_VERIFIER_MODEL` instead. See "Env knobs" below.

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

An older copy of the wake-word pipeline existed in the founder dev monorepo (pre-extraction);
the `runtime/wake-word/` tree is the canonical post-extraction location. Research Q5 confirmed
that `voice_client.py` looks for the verifier under `~/wake_word/` -- that is the canonical path.
The whisplay-level copy (which has its own `record_negative.py`, `record_positive.py`,
`test_wake.py`) was an earlier split and is stale. Only the canonical `~/wake_word/` scripts
were extracted here.

## Env knobs

| Variable | Default | Purpose |
|---|---|---|
| `ARLOWE_VENV_SITE_PACKAGES` | unset | Extra `sys.path` entry for training scripts (set in dev or by image build at `/opt/arlowe/venv/lib/python3.X/site-packages`) |
| `ARLOWE_WAKE_WORD_STATE` | `/var/lib/arlowe/wake-word` | Base dir for samples and verifier |
| `ARLOWE_WAKE_WORD_VERIFIER` | `${ARLOWE_WAKE_WORD_STATE}/verifier.pkl` | Explicit verifier path, read by the scripts **in this directory only** |
| `ARLOWE_VERIFIER_MODEL` | `/var/lib/arlowe/wake-word/verifier.pkl` | Explicit verifier path, read by `runtime/voice/voice_client.py`. Set by `units/arlowe-voice.service`. This is the one the shipping orchestrator honours |
| `ARLOWE_SPEAK_BIN` | `/usr/local/bin/speak` | Path to the speak CLI helper used by auto_collect and quick_test |
| `ARLOWE_ALSA_DEVICE` | `plughw:2,0` | ALSA capture (and playback) device for auto_collect |
