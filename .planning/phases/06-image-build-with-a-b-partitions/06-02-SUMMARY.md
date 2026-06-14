---
phase: 06-image-build-with-a-b-partitions
plan: 02
status: complete
completed: 2026-06-13
pr: "#106"
---

# 06-02 Summary — SHA-pinned model + WhisPlay fetch/verify gate + Whisper model ADR

## What was built

### Task 1: Whisper model selection ADR + model manifest

- **`docs/architecture/0006-whisper-model-selection.md`** — ADR pinning `faster-whisper small.en`
  as the shipped Whisper model. Rationale: meaningfully better than `base.en` (dev default),
  ~0.49 GB fits 16 GB cards under the single shared models partition (ADR-0004), and stays
  within Pi 5 CPU inference budget. Overridable via `ARLOWE_WHISPER_MODEL` env var.

- **`third_party/models/manifest.yml`** — Strategy-C SHA-pinned manifest for all three model
  families (ONE copy each for the shared models partition):
  - `qwen2.5-7b-int4-ax650` → `/opt/arlowe/models/qwen2.5-7b-int4-ax650` (matches qwen-api.service)
  - `faster-whisper-small.en` → `/opt/arlowe/models/whisper/small.en` (ADR-0006 choice)
  - `piper-en_US-lessac-medium` → `/opt/arlowe/models/piper-voices/en_US-lessac-medium.onnx` (matches arlowe-voice.service)

- **`third_party/models/INSTALL.md`** — sourcing instructions for all three artifacts,
  search path order, and instructions for closing TODO SHA pins.

### Task 2: Extended verify gate + WhisPlay INSTALL.md

- **`scripts/verify-third-party.sh`** — extended to cover:
  - (existing) axcl .deb SHA-256 check
  - (existing) ax-llm submodule commit check
  - (new) Model artifact verification: locates each artifact via env var / repo-relative / cache,
    exits non-zero if missing, WARNS (does not hard-fail) if SHA pin is a TODO placeholder but
    prints actual hash so it can be closed
  - (new) WhisPlay driver presence check: `WhisPlay.py` + `LICENSE` via env/repo/cache; exits
    non-zero if missing
  - (new) WM8960 audio HAT redistribution rights non-blocking warning

- **`third_party/whisplay-driver/INSTALL.md`** — sourcing instructions for WhisPlay.py via
  PiSugar/Whisplay git clone, Apache 2.0 attribution requirements, WM8960 fetch-at-build note,
  and dev-unit shortcut (`ARLOWE_WHISPLAY_SRC` pointing at arlowe-1 existing install).

## SHA pin status (placeholders)

All three model SHA pins are **TODO placeholders**. They are marked `TODO_SHA256__*` in the
manifest, which causes `verify-third-party.sh` to WARN (not fail) and print the actual hash
when the artifact is present. Close these in issue #106 comments when 06-06 (on-hardware build)
first fetches the artifacts:

| Artifact | Placeholder key | How to close |
|----------|----------------|--------------|
| qwen2.5-7b-int4-ax650 | `TODO_SHA256__capture_at_first_fetch_from_axera_provisioning_kit` | Run verify-third-party.sh with artifact present; record printed hash |
| faster-whisper-small.en | `TODO_SHA256__capture_at_first_fetch_from_huggingface_Systran_faster-whisper-small.en` | Same — hash the model.bin file |
| piper en_US-lessac-medium.onnx | `TODO_SHA256__capture_at_first_fetch_from_huggingface_rhasspy_piper-voices` | Same — hash the .onnx file |

## Verification results

All plan verification checks passed:

```
test -f third_party/models/manifest.yml                     OK
grep -q "sha256" third_party/models/manifest.yml            OK
grep -q "qwen2.5-7b-int4-ax650" third_party/models/manifest.yml  OK
grep -q "piper" third_party/models/manifest.yml             OK
grep -q "whisper" third_party/models/manifest.yml           OK
test -f docs/architecture/0006-whisper-model-selection.md   OK
bash -n scripts/verify-third-party.sh                       OK
grep -q "models" scripts/verify-third-party.sh              OK
grep -qi "whisplay" scripts/verify-third-party.sh           OK
scripts/verify-third-party.sh --help                        OK
scripts/verify-third-party.sh (no artifacts) exits non-zero OK
```

shellcheck: not installed in dev environment (Mac); script uses standard POSIX-compatible
constructs only (no bashisms beyond `[[ ]]` and here-strings). Will run in CI on arm64 Linux.

## Follow-on actions for 06-06 (on-hardware build)

1. Fetch Qwen AX650 model from Axera provisioning kit; run `verify-third-party.sh` and record SHA.
2. `huggingface-cli download Systran/faster-whisper-small.en`; hash `model.bin`; record SHA.
3. `huggingface-cli download rhasspy/piper-voices --include "en/en_US/lessac/medium/*"`; hash `.onnx`; record SHA.
4. Update `third_party/models/manifest.yml` to close all three TODO pins.
5. Resolve WM8960 Waveshare redistribution rights (or confirm fetch-at-build is acceptable for distribution).
