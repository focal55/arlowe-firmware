# runtime/llm

Local-first LLM dispatch for the Arlowe voice pipeline.

## Components

| File | Purpose |
|---|---|
| `router.py` | Local/cloud LLM dispatcher. Renamed from `iol_router.py` per ADR-0001. |
| `run_api.sh` | Launches `main_api_axcl_aarch64` (ax-llm HTTP server) on port 8000. |
| `qwen2.5_tokenizer_uid.py` | Tokenizer HTTP service on port 12345. Required by ax-llm before inference. |
| `openai_wrapper.py` | **NOT YET RESTORED.** See ADR-0001 §"openai_wrapper.py — resolution". |

## Service start order

Per boot health research, services must start in this order:

1. `qwen-tokenizer` — starts `qwen2.5_tokenizer_uid.py` on port 12345
2. `qwen-api` — starts `run_api.sh`; the binary connects to the tokenizer at startup
3. `qwen-openai` — starts `openai_wrapper.py` on port 8001 (**currently broken**)

## Ports

| Port | Service | Status |
|---|---|---|
| 12345 | `qwen-tokenizer` — tokenizer HTTP | active |
| 8000 | `qwen-api` — ax-llm native HTTP | active |
| 8001 | `qwen-openai` — OpenAI-compat shim | **BROKEN** — see ADR-0001 |

## Routing logic (`router.py`)

`route(text)` classifies the query as `"local"` or `"cloud"`:

- **Local**: simple/conversational queries — sent via HTTP POST to `:8001`
  (OpenAI `/v1/chat/completions`). Falls back to cloud if the local call fails.
- **Cloud**: complex queries or local failure — runs `claude -p` as a subprocess
  (Claude Code CLI, non-interactive print mode). Requires `CLAUDE_BIN` to be
  resolvable; see Configuration below.

Both paths log token counts and latency to `/var/lib/arlowe/state/usage-stats.json`.

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `ARLOWE_CLAUDE_BIN` | `shutil.which("claude")` then `/usr/bin/claude` | Path to the `claude` CLI binary |
| `ARLOWE_VOICE_MODEL` | `claude-haiku-4-5` | Cloud model ID |
| `ARLOWE_VOICE_TIMEOUT` | `60` | Cloud subprocess timeout (seconds) |
| `AX_LLM_BIN` | `/opt/arlowe/runtime/llm/bin/main_api_axcl_aarch64` | Path to ax-llm binary (used by `run_api.sh`) |
| `QWEN_MODEL_DIR` | `/opt/arlowe/models/qwen2.5-7b-int4-ax650` | Path to Qwen model directory (used by `run_api.sh`) |

For the Phase 1 smoke test on arlowe-1, override `AX_LLM_BIN` and `QWEN_MODEL_DIR`
to point at the existing locations under `~/ax-llm/` and `~/models/`. See plan 13.

## openai_wrapper.py status

The `qwen-openai.service` unit references `openai_wrapper.py`, which does not exist
on the device. Port 8001 is therefore unreachable; all voice queries today fall
through to the cloud Claude path. Plan 13's smoke-test prep resolves this:

- **Recommended**: eliminate the wrapper by pointing `QWEN_URL` directly at `:8000`
  (ax-llm natively speaks OpenAI-compat `/v1/chat/completions`).
- Alternative: recover/write a ~50-line shim.

See `docs/architecture/0001-iol-router-extraction.md` for the full decision tree.

## Cloud path credential note

`query_cloud()` invokes `claude -p` which uses `~/.claude/.credentials.json`. On the
dev unit this is the founder's credentials. Customer units need their own credentials
— that is Phase 7 (first-boot pairing + per-customer API key) scope. The default
voice path does not require internet access when the local Qwen path is working.
