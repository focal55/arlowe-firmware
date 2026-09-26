# Model Artifacts — Install Instructions

Model files are **not committed to this repo** (redistribution rights and file size).
You must obtain each artifact and place it where the build expects it before running
`scripts/verify-third-party.sh` or the Phase 6 image build.

All three model families live on the **shared read-only models partition** mounted at
`/opt/arlowe/models` in both A and B slots (see `docs/architecture/0004-shared-models-partition.md`).

Every file is pinned by sha256 in `third_party/models/manifest.yml`, with the upstream
repo and revision it came from. Place **exactly** the files the manifest lists: the
image build verifies the staged models tree with `--exact` and fails on any file the
manifest does not name, because 02-models copies whole directories and an extra file
would otherwise ship unverified. `huggingface-cli download --local-dir` leaves a
`.cache/huggingface/` directory and repo files such as `README.md` behind, so download
to a scratch directory and copy the listed files, as below.

---

## Environment variable

Set `ARLOWE_MODELS_DIR` to override the default search root:

```bash
export ARLOWE_MODELS_DIR=/path/to/your/model/cache
```

The verify script checks paths in this order for each artifact.
The search path is derived from the manifest's `install_to` field by stripping
the `/opt/arlowe/models/` image prefix (so `install_to` and the staging path agree):

1. `$ARLOWE_MODELS_DIR/<install_to-subpath>`
2. `third_party/models/<install_to-subpath>`
3. `/var/cache/arlowe-build/models/<install_to-subpath>`

`scripts/build-image.sh` stages from `ARLOWE_MODELS_DIR` when it is set, and from
`${WORK_DIR}/arlowe-models-cache` when it is not. Set it, so the directory
`verify-third-party.sh` checks is the one that gets staged. The staged tree is
verified again either way.

The examples below use `M=/var/cache/arlowe-build/models`.

---

## 1. Qwen 2.5 7B int4 (AX650) — `qwen2.5-7b-int4-ax650`

**Target on image:** `/opt/arlowe/models/qwen2.5-7b-int4-ax650` (30 files)

**Source:** `AXERA-TECH/Qwen2.5-7B-Instruct`, directory `qwen2.5-7b-ctx-int4-ax650/`,
renamed on install. Public; no account needed. **Not** `AXERA-TECH/Qwen2.5-7B-Instruct-GPTQ-Int4`:
its files have the same names and none of the pinned digests.

**License:** redistribution rights TBD — see the manifest header.

```bash
huggingface-cli download AXERA-TECH/Qwen2.5-7B-Instruct \
    --revision 97ccbbde2f2282a24ff00bb5df8e5c9eb34033fb \
    --include "qwen2.5-7b-ctx-int4-ax650/*" --local-dir /tmp/qwen-dl
mkdir -p "$M/qwen2.5-7b-int4-ax650"
cp /tmp/qwen-dl/qwen2.5-7b-ctx-int4-ax650/*.axmodel \
   /tmp/qwen-dl/qwen2.5-7b-ctx-int4-ax650/model.embed_tokens.weight.bfloat16.bin \
   "$M/qwen2.5-7b-int4-ax650/"
```

---

## 2. Whisper STT — `faster-whisper-small.en`

**Target on image:** `/opt/arlowe/models/whisper/small.en` (4 files)

**License:** Apache 2.0 (Systran CTranslate2 conversion of OpenAI Whisper weights).
Freely redistributable with attribution.

**Model choice:** `small.en` — see `docs/architecture/0006-whisper-model-selection.md` (ADR-0006)
for rationale. This supersedes the `base.en` default in `runtime/stt/stt_server.py`.

```bash
huggingface-cli download Systran/faster-whisper-small.en \
    --revision d1d751a5f8271d482d14ca55d9e2deeebbae577f \
    config.json model.bin tokenizer.json vocabulary.txt --local-dir /tmp/whisper-dl
mkdir -p "$M/whisper/small.en"
cp /tmp/whisper-dl/{config.json,model.bin,tokenizer.json,vocabulary.txt} "$M/whisper/small.en/"
```

---

## 3. Piper TTS — `en_US-lessac-medium`

**Target on image:** `/opt/arlowe/models/piper-voices/` (2 files)
- `en_US-lessac-medium.onnx`
- `en_US-lessac-medium.onnx.json`

**License:** CC BY 4.0 — attribution required; commercial use permitted.
Cite: "Piper TTS en_US-lessac-medium voice by rhasspy/piper-voices contributors."

```bash
huggingface-cli download rhasspy/piper-voices \
    --revision c10ece1aade47bb51c153c893d14e5bf8e5b7117 \
    --include "en/en_US/lessac/medium/en_US-lessac-medium.onnx*" \
    --local-dir /tmp/piper-voices-dl
mkdir -p "$M/piper-voices"
cp /tmp/piper-voices-dl/en/en_US/lessac/medium/en_US-lessac-medium.onnx \
   /tmp/piper-voices-dl/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json \
   "$M/piper-voices/"
```

---

## Verification

```bash
ARLOWE_MODELS_DIR="$M" scripts/verify-third-party.sh
```

Each model reports every file and then a summary line:

```
         [models] OK   whisper/small.en/model.bin
         ...
[OK]   faster-whisper-small.en        every file sha256 matches
```

A mismatch names the file with the expected and actual digests. A missing model
directory prints the three places it was looked for.

To check a tree directly, for example the models partition on a device:

```bash
python3 scripts/lib/verify-models.py --manifest third_party/models/manifest.yml \
    --root /opt/arlowe/models --exact
```

**Known gap:** `runtime/stt/stt_server.py` currently hardcodes `base.en`; the image
build (06-03) must set `ARLOWE_WHISPER_MODEL=small.en` in the unit environment to
override it.
