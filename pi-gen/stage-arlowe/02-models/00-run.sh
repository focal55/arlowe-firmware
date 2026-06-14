#!/bin/bash
# Host-side step: assemble the verified model artifacts into a SEPARATE standalone
# models tree on the BUILD HOST. This tree is NOT written into the rootfs.
#
# This tree mirrors the layout the read-only models partition exposes at
# /opt/arlowe/models so the unit files' existing paths resolve once mounted:
#
#   <models-tree>/qwen2.5-7b-int4-ax650/     QWEN_MODEL_DIR (qwen-api.service)
#   <models-tree>/piper-voices/               ARLOWE_PIPER_MODEL (arlowe-voice.service)
#   <models-tree>/whisper/small.en/           faster-whisper cache (stt_server.py)
#
# The tree's path is exported to ${ARLOWE_MODELS_STAGE_MARKER} (a file in the
# pi-gen work dir) so plan 06-04's partition-image.sh can read it and rsync
# the tree into the dedicated models partition.
#
# /opt/arlowe/models inside the rootfs remains an EMPTY mount point.
# This script operates only on the build host; it does not modify the rootfs.
#
# Model artifact sources are defined in third_party/models/manifest.yml (plan
# 06-02). Artifacts must have been downloaded and verified (via
# scripts/verify-third-party.sh) before this stage runs — fail clearly if any
# are absent. The upstream gate is plan 06-02's manifest + verification step.
#
# ARLOWE_MODELS_CACHE: directory containing the downloaded model artifacts.
#   Default: ${WORK_DIR}/arlowe-models-cache (pi-gen sets WORK_DIR).
#   Override: set ARLOWE_MODELS_CACHE in the environment.
# ARLOWE_MODELS_STAGE: output tree directory.
#   Default: ${WORK_DIR}/arlowe-models-stage
#   Override: set ARLOWE_MODELS_STAGE in the environment.
set -euo pipefail

# pi-gen provides WORK_DIR; guard for manual runs.
if [[ -z "${WORK_DIR:-}" ]]; then
    echo "[02-models] ERROR: WORK_DIR is not set. Run via pi-gen or set WORK_DIR manually." >&2
    exit 1
fi

MODELS_CACHE="${ARLOWE_MODELS_CACHE:-${WORK_DIR}/arlowe-models-cache}"
MODELS_STAGE="${ARLOWE_MODELS_STAGE:-${WORK_DIR}/arlowe-models-stage}"
MODELS_STAGE_MARKER="${WORK_DIR}/arlowe-models-stage-path"

echo "[02-models] models cache: ${MODELS_CACHE}"
echo "[02-models] models stage: ${MODELS_STAGE}"

# ---------------------------------------------------------------------------
# Create the output tree structure.
# Paths match the unit file environment variables for zero-config resolution
# once the shared partition is mounted read-only at /opt/arlowe/models.
# ---------------------------------------------------------------------------
install -d -m 0755 \
    "${MODELS_STAGE}/qwen2.5-7b-int4-ax650" \
    "${MODELS_STAGE}/piper-voices" \
    "${MODELS_STAGE}/whisper/small.en"

# ---------------------------------------------------------------------------
# Qwen 2.5 7B int4 ax650 model (QWEN_MODEL_DIR in qwen-api.service)
# ---------------------------------------------------------------------------
QWEN_SRC="${MODELS_CACHE}/qwen2.5-7b-int4-ax650"
if [[ -d "${QWEN_SRC}" ]]; then
    echo "[02-models] staging qwen2.5-7b-int4-ax650"
    rsync -a "${QWEN_SRC}/" "${MODELS_STAGE}/qwen2.5-7b-int4-ax650/"
else
    echo "[02-models] ERROR: qwen2.5-7b-int4-ax650 not found at ${QWEN_SRC}" >&2
    echo "[02-models] Run scripts/verify-third-party.sh to download + verify models." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Piper TTS voice (ARLOWE_PIPER_MODEL in arlowe-voice.service points at the
# .onnx file directly: /opt/arlowe/models/piper-voices/en_US-lessac-medium.onnx)
# ---------------------------------------------------------------------------
PIPER_SRC="${MODELS_CACHE}/piper-voices"
if [[ -d "${PIPER_SRC}" ]] && ls "${PIPER_SRC}"/en_US-lessac-medium.onnx 2>/dev/null; then
    echo "[02-models] staging piper-voices"
    rsync -a "${PIPER_SRC}/" "${MODELS_STAGE}/piper-voices/"
else
    echo "[02-models] ERROR: piper-voices/en_US-lessac-medium.onnx not found at ${PIPER_SRC}" >&2
    echo "[02-models] Run scripts/verify-third-party.sh to download + verify models." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Whisper faster-whisper small.en model cache.
# stt_server.py loads with WhisperModel("base.en", ...) by default and
# faster-whisper resolves via HuggingFace cache. For the image we pre-populate
# the cache at /opt/arlowe/models/whisper/small.en so the unit starts offline.
# The HF_HOME env var in whisper-stt.service should point at /opt/arlowe/models
# so faster-whisper picks up this cache directory at runtime. (Plan 06-04 wires
# the env var; this script places the cache tree.)
# ---------------------------------------------------------------------------
WHISPER_SRC="${MODELS_CACHE}/whisper/small.en"
if [[ -d "${WHISPER_SRC}" ]]; then
    echo "[02-models] staging whisper/small.en"
    rsync -a "${WHISPER_SRC}/" "${MODELS_STAGE}/whisper/small.en/"
else
    echo "[02-models] ERROR: whisper/small.en cache not found at ${WHISPER_SRC}" >&2
    echo "[02-models] Run scripts/verify-third-party.sh to download + verify models." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Export the staging tree path for plan 06-04.
# partition-image.sh reads this file to locate the tree to rsync into the
# models partition device.
# ---------------------------------------------------------------------------
echo "${MODELS_STAGE}" > "${MODELS_STAGE_MARKER}"
echo "[02-models] wrote models stage path to ${MODELS_STAGE_MARKER}"
echo "[02-models] models tree assembled at ${MODELS_STAGE}"
