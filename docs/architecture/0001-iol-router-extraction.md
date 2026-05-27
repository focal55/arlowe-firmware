# ADR-0001: iol_router.py extraction — extract-clean with rename

<!-- status: accepted -->
**Status:** Accepted
**Date:** 2026-05-01
**Phase:** 1 (Runtime extraction)
**Closes:** EXTRACT-11
**Relates to:** EXTRACT-05 (openai_wrapper.py resolution, resolved 2026-05-10 in plan 13)

## Context

The runtime contains `iol_router.py`, the local/cloud LLM dispatcher. The "IOL" name
is historical residue from a pre-Claude-Code architecture (the OpenClaw-gateway path
on port 18789 was retired during the migration; the current code does not call any
founder-only IOL infrastructure). The Phase 1 roadmap requirement EXTRACT-11 asks
for a decision: extract-clean, stub, or strip.

Live state at extraction time (`arlowe-1.local`, 2026-05-01):
- `iol_router.py` is 452 lines; routes between local Qwen (`http://localhost:8001`)
  and cloud Claude (subprocess invocation of `claude -p`).
- The local path is currently broken: `qwen-openai.service` is in restart loop
  because `/home/focal55/models/Qwen2.5-1.5B-Instruct/openai_wrapper.py` does not
  exist. Voice queries today fall through to the cloud Claude path.
- The cloud path uses the founder's `~/.claude/.credentials.json` — works on
  arlowe-1, will not work on a customer unit until Phase 7 (PKI + per-customer auth).

## Decision

**Extract-clean with rename to `runtime/llm/router.py`.**

The module's logic is generic: dispatch local-vs-cloud based on a heuristic.
Nothing about it is founder-specific once paths are sanitized. A stub would lose
the local/cloud routing that the smoke test depends on; a strip would remove
the orchestrator's only LLM hookup.

Concrete sanitization landed in plan 05:
- Rename `iol_router.py` → `runtime/llm/router.py`
- `USAGE_STATS_PATH`: `~/.claude/workspace/usage-stats.json` → `/var/lib/arlowe/state/usage-stats.json`
- `CLAUDE_BIN`: hardcoded `/home/focal55/.local/bin/claude` → env override (`ARLOWE_CLAUDE_BIN`) + `shutil.which("claude")` + `/usr/bin/claude` fallback
- Module docstring rewritten to explain the rename
- All log prefixes updated from `[IOL]` to `[router]`
- All `iol_route(...)` callsites updated to `llm_route(...)` (in plan 02, voice_client.py)

## openai_wrapper.py — resolution (resolved 2026-05-10 in plan 13)

**Decision: option-2.** `QWEN_URL` in `runtime/llm/router.py` now points at
`http://localhost:8000/api/chat` (ax-llm's native chat endpoint). The
`openai_wrapper.py` shim is eliminated; `qwen-openai.service` is no longer
in the request path.

Originally rewired to `/v1/chat/completions`; refined to ax-llm's native
`/api/chat` in PR #52 (commit `ff8214f`) after the OpenAI-compat surface
returned unexpected shapes against the running ax-llm build (Feb 2026
axcl-context branch). The authoritative routes are documented in
`ax-llm/docs/http_api.md`:

- `POST /api/chat` — synchronous `{messages: [...]}` → `{done, message}`
- `POST /api/reset` — KV cache + system_prompt reset
- `POST /api/generate`, `GET /api/generate_provider` — streaming variant

### Why option-2

- **Verified working live.** `curl -s -XPOST http://localhost:8000/api/chat \
  -d '{"messages":[{"role":"user","content":"ping"}]}'` on a Pi 5 dev unit
  returns `{done: true, message: {...}}`. `voice_client.py` was updated in
  PR #52 to speak ax-llm's native shape; the previous assumption that ax-llm
  would expose the OpenAI `/v1/chat/completions` surface returned malformed
  responses on the running build.
- **Lowest LOC delta.** One URL constant changed; no new file.
- **Removes a moving part.** One fewer service to keep alive. The previous
  3-service path (`qwen-tokenizer` → `qwen-openai` shim → `qwen-api`) collapses
  to 2 (`qwen-tokenizer` → ax-llm at `:8000`).
- Plan 13 task 1 recommended option-2 with auto-fallback from option-1 if git
  recovery failed. Option-1 was not attempted because option-2 is verified
  working today and recovery would have served only to preserve a shim with no
  current consumer.

### Post-fix observable behaviour

After plan 13 staging on arlowe-1:
- A voice query causes `voice_client.py` → `llm.router.query_local()` → POST
  to `http://localhost:8000/api/chat`.
- ax-llm responds with `{done: true, message: "..."}`. The router consumes
  `response["message"]` directly (no `choices[0].message.content` indirection
  — that path belonged to the eliminated OpenAI-compat era).
- Round-trip target: under 5s wake-to-speech (validated in
  `docs/operations/phase-1-smoke-test.md` Observed-run section).

### Follow-up work

- **Phase 11 (boot health, dashboard, log management):** drop
  `qwen-openai.service` from the systemd unit set entirely. Update the
  dashboard's `/api/voice` and `/api/logs` service-list constants accordingly.
- **Smoke test:** Plan 13 task 4 exercises the new path end-to-end on
  arlowe-1; outcome captured in
  `docs/operations/phase-1-smoke-test.md`.

## Cloud-path credential dependency (Phase 7)

`query_cloud()` runs `claude -p` which implicitly uses `~/.claude/.credentials.json`.
On the dev unit (`arlowe-1`), this is the founder's credentials — the cloud path
works there today. On a sanitized customer unit, these credentials are absent and
the cloud path will fail silently at invocation time.

This is intentional for Phase 1: the v1 success criterion explicitly requires
"no internet round-trip in the default path." Cloud is opt-in. The fix is Phase 7
(first-boot pairing + customer-bound API key). The `CLAUDE_BIN` resolution via
`ARLOWE_CLAUDE_BIN` env var is the hook point for that work.

## Consequences

**Positive:**
- The router is sanitized and shippable today.
- Cloud-path tech debt (founder credentials) is now confined to Phase 7's identity work.
- Naming reflects what the module does rather than its history.

**Negative / known gaps:**
- `openai_wrapper.py` is unresolved at the end of plan 05; the local LLM path
  remains broken until plan 13.
- Cloud LLM path will not work on a customer-equivalent unit (no founder credentials).
  This is fine for v1 since the success criterion explicitly requires "no internet
  round-trip in the default path". Cloud is opt-in / Phase 7 territory.

## References

- Research findings: `.planning/phases/01-runtime-extraction/01-RESEARCH.md` §EXTRACT-05, §EXTRACT-11, §R1
- Roadmap requirement: `.planning/REQUIREMENTS.md` EXTRACT-11
- Sister ADR: `docs/architecture/0002-arlowe-scheduled-summary-stripped.md` (plan 12)
