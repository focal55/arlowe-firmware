---
plan: 05
phase: 01-runtime-extraction
status: complete
date: 2026-05-02
---

# Plan 05 Summary: LLM Stack Extraction

## Files extracted

| Source | Destination | Notes |
|---|---|---|
| `~/iol-monorepo/packages/whisplay/iol_router.py` | `runtime/llm/router.py` | Renamed per ADR-0001 |
| `~/models/Qwen2.5-7B-Instruct/run_api.sh` | `runtime/llm/run_api.sh` | Sanitized, made executable |
| `~/models/Qwen2.5-7B-Instruct/qwen2.5_tokenizer_uid.py` | `runtime/llm/qwen2.5_tokenizer_uid.py` | Verbatim (no founder content) |

## Authored

- `runtime/llm/requirements.txt` — pinned deps (filelock, transformers)
- `runtime/llm/README.md` — component guide, ports table, ADR-0001 reference
- `docs/architecture/0001-iol-router-extraction.md` — ADR for rename + extract-clean decision

## Sanitization changes (router.py)

| Change | Before | After |
|---|---|---|
| `USAGE_STATS_PATH` | `Path.home() / ".claude/workspace/usage-stats.json"` | `Path("/var/lib/arlowe/state/usage-stats.json")` |
| `CLAUDE_BIN` | `"/home/focal55/.local/bin/claude"` | env `ARLOWE_CLAUDE_BIN` → `shutil.which("claude")` → `/usr/bin/claude` |
| Module docstring | IOL/OpenClaw history | Explains rename per ADR-0001 |
| Log prefix | `[IOL]` | `[router]` |

## Sanitization changes (run_api.sh)

| Change | Before | After |
|---|---|---|
| System prompt | `Your human is Joe.` | `Your human is the device owner.` |
| Binary path | hardcoded `./main_api_axcl_aarch64` | `${AX_LLM_BIN}` env var with `/opt/arlowe/` default |
| Model path | hardcoded relative path | `${QWEN_MODEL_DIR}` env var with `/opt/arlowe/` default |

## ADR-0001 decisions

- **Rename**: `iol_router.py` → `runtime/llm/router.py` (IOL name is historical residue)
- **Extract-clean**: full extraction with sanitization, no stub
- **openai_wrapper.py**: deferred to plan 13 — options documented, option 2 (repoint to :8000) recommended

## openai_wrapper.py status

**Not restored.** The file does not exist on arlowe-1 and `qwen-openai.service` is in
restart loop. Plan 13 picks one of three options (see ADR-0001 §Resolution). The
`QWEN_URL` constant in `router.py` retains the `:8001` endpoint with a comment
documenting the broken state and the plan 13 dependency.

## Voice client wiring

`voice_client.py` (plan 02) imports `from iol_router import route as iol_route, reset_local`.
That import needs updating to `from llm.router import route, reset_local` as part of
plan 02's sanitization pass. This plan owns the router file; plan 02 owns the import site.
