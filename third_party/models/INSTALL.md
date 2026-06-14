# Model Artifacts — Install Instructions

Model files are **not committed to this repo** (redistribution rights and file size).
You must obtain each artifact and place it where the build expects it before running
`scripts/verify-third-party.sh` or the Phase 6 image build.

All three model families live on the **shared read-only models partition** mounted at
`/opt/arlowe/models` in both A and B slots (see `docs/architecture/0004-shared-models-partition.md`).
The SHA pins in `third_party/models/manifest.yml` are currently TODO placeholders — record
real hashes in the issue #106 PR comment when 06-06 first fetches the artifacts.

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

---

## 1. Qwen 2.5 7B int4 (AX650) — `qwen2.5-7b-int4-ax650`

**Target on image:** `/opt/arlowe/models/qwen2.5-7b-int4-ax650`

**License:** Auth-gated; redistribution rights TBD — obtain from Axera Semiconductor.

**How to obtain:**

1. Contact Axera Semiconductor or use the provisioning kit that came with your
   AX8850 evaluation board / M.2 module.
2. The Axera-optimized AX650 deployment variant is distinct from the base
   HuggingFace Qwen2.5-7B weights. Do not substitute the base weights.
3. Confirm the directory digest matches the pin in `manifest.yml` before
   proceeding. The gate computes: `find -type f | sort | xargs sha256sum | sha256sum`.
   The pin is currently a TODO placeholder — capture and record the real digest at
   first fetch (the gate prints it when the pin is a placeholder).

**Where to place it:**

```bash
# Option A: set the env var (recommended for CI)
export ARLOWE_MODELS_DIR=/var/cache/arlowe-build/models
cp -r /path/to/qwen2.5-7b-int4-ax650/ $ARLOWE_MODELS_DIR/qwen2.5-7b-int4-ax650/

# Option B: repo-relative (never commit these files)
cp -r /path/to/qwen2.5-7b-int4-ax650/ third_party/models/qwen2.5-7b-int4-ax650/

# Option C: default cache location
sudo cp -r /path/to/qwen2.5-7b-int4-ax650/ /var/cache/arlowe-build/models/qwen2.5-7b-int4-ax650/
```

---

## 2. Whisper STT — `faster-whisper-small.en`

**Target on image:** `/opt/arlowe/models/whisper/small.en`

**License:** Apache 2.0 (Systran CTranslate2 conversion of OpenAI Whisper weights).
Freely redistributable with attribution.

**Model choice:** `small.en` — see `docs/architecture/0006-whisper-model-selection.md` (ADR-0006)
for rationale. This supersedes the `base.en` default in `runtime/stt/stt_server.py`.

**How to obtain:**

```bash
# Requires: pip install huggingface_hub
huggingface-cli download Systran/faster-whisper-small.en \
    --local-dir /var/cache/arlowe-build/models/whisper/small.en
```

Or via git-lfs:

```bash
git clone https://huggingface.co/Systran/faster-whisper-small.en \
    /var/cache/arlowe-build/models/whisper/small.en
```

After download, capture the directory digest for the manifest.
The gate uses a deterministic directory digest for directory artifacts
(`find -type f | sort | xargs sha256sum | sha256sum`):

```bash
find /var/cache/arlowe-build/models/whisper/small.en -type f \
  | LC_ALL=C sort | xargs sha256sum | sha256sum | awk '{print $1}'
```

**Where to place it** (`install_to` subpath: `whisper/small.en`):

```bash
/var/cache/arlowe-build/models/whisper/small.en/   (directory with model files)
# or
third_party/models/whisper/small.en/               (repo-relative, not committed)
```

---

## 3. Piper TTS — `en_US-lessac-medium`

**Target on image:**
- `/opt/arlowe/models/piper-voices/en_US-lessac-medium.onnx`
- `/opt/arlowe/models/piper-voices/en_US-lessac-medium.onnx.json`

**License:** CC BY 4.0 — attribution required; commercial use permitted.
Cite: "Piper TTS en_US-lessac-medium voice by rhasspy/piper-voices contributors."

**How to obtain:**

```bash
# Requires: pip install huggingface_hub
huggingface-cli download rhasspy/piper-voices \
    --include "en/en_US/lessac/medium/*" \
    --local-dir /tmp/piper-voices-dl

# The downloaded files are nested; flatten to the expected location:
mkdir -p /var/cache/arlowe-build/models/piper-voices
cp /tmp/piper-voices-dl/en/en_US/lessac/medium/en_US-lessac-medium.onnx \
   /var/cache/arlowe-build/models/piper-voices/
cp /tmp/piper-voices-dl/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json \
   /var/cache/arlowe-build/models/piper-voices/
```

After placing, capture the SHA:

```bash
sha256sum /var/cache/arlowe-build/models/piper-voices/en_US-lessac-medium.onnx
```

**Where to place it:**

```bash
/var/cache/arlowe-build/models/piper-voices/en_US-lessac-medium.onnx
/var/cache/arlowe-build/models/piper-voices/en_US-lessac-medium.onnx.json
# or
third_party/models/piper-voices/en_US-lessac-medium.onnx
third_party/models/piper-voices/en_US-lessac-medium.onnx.json
```

---

## Verification

After placing all artifacts, run the gate:

```bash
scripts/verify-third-party.sh
```

Expected output when SHA pins are still placeholders (TODO) and artifacts are present:

```
[WARN]  qwen2.5-7b-int4-ax650          sha256 pin is TODO placeholder
         actual dir digest: <hash>
         Record this in third_party/models/manifest.yml to close the TODO.
[WARN]  faster-whisper-small.en        sha256 pin is TODO placeholder
         actual dir digest: <hash>
         Record this in third_party/models/manifest.yml to close the TODO.
[WARN]  piper-en_US-lessac-medium      sha256 pin is TODO placeholder
         actual hash: <hash>
         Record this in third_party/models/manifest.yml to close the TODO.
```

Record the printed digests/hashes in `third_party/models/manifest.yml` to close the TODOs.
Open a follow-up on issue #106 when all pins are captured.

Expected output when artifacts are missing:

```
[FAIL]  qwen2.5-7b-int4-ax650     not found
  See third_party/models/INSTALL.md for sourcing instructions.
```

---

## Closing TODO pins

When the first real fetch captures all hashes, update `manifest.yml` and note
the real SHAs in the issue #106 PR comment (or a follow-up issue). The on-hardware
build step is issue 06-06.
