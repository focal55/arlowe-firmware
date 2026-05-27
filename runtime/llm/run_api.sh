#!/bin/bash
# Launch the ax-llm HTTP server (main_api_axcl_aarch64) on port 8000.
#
# Paths are resolved at runtime via env vars so the image build can provision
# them under /opt/arlowe/ without editing this file.
# For local smoke-testing on a Pi 5 dev unit with the AX accelerator, set:
#   AX_LLM_BIN=~/ax-llm/build/main_api_axcl_aarch64
#   QWEN_MODEL_DIR=~/models/Qwen2.5-7B-Instruct/qwen2.5-7b-ctx-int4-ax650
# See plan-13 smoke-test notes for the exact export commands.
set -e

# Resolve at runtime; image build provisions these under /opt/arlowe/.
AX_LLM_BIN="${AX_LLM_BIN:-/opt/arlowe/runtime/llm/bin/main_api_axcl_aarch64}"
QWEN_MODEL_DIR="${QWEN_MODEL_DIR:-/opt/arlowe/models/qwen2.5-7b-int4-ax650}"

cd "$(dirname "$0")"

"${AX_LLM_BIN}" \
  --template_filename_axmodel "${QWEN_MODEL_DIR}/qwen2_p128_l%d_together.axmodel" \
  --axmodel_num 28 \
  --url_tokenizer_model "http://127.0.0.1:12345" \
  --filename_post_axmodel "${QWEN_MODEL_DIR}/qwen2_post.axmodel" \
  --filename_tokens_embed "${QWEN_MODEL_DIR}/model.embed_tokens.weight.bfloat16.bin" \
  --tokens_embed_num 152064 \
  --tokens_embed_size 3584 \
  --use_mmap_load_embed 1 \
  --devices 0 \
  --system_prompt "You are Arlowe, a friendly AI assistant with a calm, curious personality. Soft neon blue vibe. Be brief, conversational, and helpful. You live on a Raspberry Pi 5 with an Axera NPU. Your human is the device owner."
