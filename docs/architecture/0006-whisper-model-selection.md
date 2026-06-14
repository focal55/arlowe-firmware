# ADR-0006: Whisper model selection — faster-whisper small.en

<!-- status: accepted -->
**Status:** Accepted
**Date:** 2026-06-13
**Phase:** 6 (Image build with A/B partitions)
**Closes:** Issue #106 (06-02 model manifest + verify gate)

## Context

The `whisper-stt.service` uses [faster-whisper](https://github.com/SYSTRAN/faster-whisper)
to run on-device speech-to-text. The model must be pinned to a single concrete
choice before the Phase 6 image build can populate the shared models partition.

Candidates on the CTranslate2/faster-whisper model hub:

| Model      | Size   | Notes |
|------------|--------|-------|
| `tiny.en`  | ~0.08 GB | Too lossy for natural-language commands; misses wake-word context words. |
| `base.en`  | ~0.15 GB | Current dev default in `runtime/stt/stt_server.py`; acceptable accuracy but visibly degrades on accented speech and compound sentences. |
| `small.en` | ~0.49 GB | ~10-15% WER improvement over base.en at ~2× inference time. Fits easily on the shared models partition. |
| `medium`   | ~1.53 GB | Marginal gain over small.en for English; +1 GB cost on the shared partition. Not justified for v1. |
| `large-v3` | ~3.1 GB  | Best accuracy, but 6× inference time vs. small.en; impractical for a voice-first interaction loop on Pi 5 CPU. |

The device pitch is **on-device quality** — that rules out tiny and base as the shipped default.
medium adds ~1 GB for marginal English gain; large-v3 is impractical on CPU.
`small.en` is the balance: meaningfully better than `base.en`, fits on 16 GB cards (single shared
model store under ADR-0004), and stays within the Pi 5 CPU inference budget for
conversational latency.

With the shared single models partition (ADR-0004) there is ONE copy of the model —
the prior "per-slot ×2" concern no longer applies.

The stt_server.py currently hardcodes `base.en`. The image build will pre-populate
the shared models partition with `small.en` and configure `MODEL_SIZE` via an
environment variable (`ARLOWE_WHISPER_MODEL`) so the unit file controls the choice
without touching Python source.

## Decision

**Ship `faster-whisper small.en` as the pinned Whisper model for v1.**

Install path on the shared models partition: `/opt/arlowe/models/whisper/small.en`
(CTranslate2 format — faster-whisper model directory, not a single `.bin` file).

## Overridability

This choice is overridable later via a `model.whisper_size` config knob in the
CONFIG-06 scope (not yet wired, deferred). If Phase 12 hardware accuracy testing
shows `medium` is necessary for the target accent/noise profile, upgrade then with
a superseding ADR entry and updated manifest pin.

The environment variable `ARLOWE_WHISPER_MODEL` (read by the unit file, defaulting
to `small.en`) is the mechanism for per-device overrides without reflashing.

## Consequences

**Positive:**
- Meaningfully better transcription accuracy than the dev default (`base.en`).
- Single copy (~0.49 GB) fits the 16 GB viable card with headroom to spare.
- CTranslate2 INT8 quantization keeps Pi 5 CPU inference time acceptable for conversational use.

**Negative / known gaps:**
- `runtime/stt/stt_server.py` currently hardcodes `base.en`; the image build (06-03) must
  set `ARLOWE_WHISPER_MODEL=small.en` in the unit environment to override it.
- Model SHA pin in `third_party/models/manifest.yml` is a TODO placeholder until
  the first real fetch from HuggingFace populates the hash (auth-gated for some paths;
  CTranslate2 converted model hash must be captured at fetch time).

## References

- Plan: `.planning/phases/06-image-build-with-a-b-partitions/06-02-PLAN.md`
- Shared models partition decision: `docs/architecture/0004-shared-models-partition.md` (ADR-0004)
- Model manifest: `third_party/models/manifest.yml`
- STT server: `runtime/stt/stt_server.py`
- HuggingFace faster-whisper models: `Systran/faster-whisper-small.en` (canonical SYSTRAN org)
