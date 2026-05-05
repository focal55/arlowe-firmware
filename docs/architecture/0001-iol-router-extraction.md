# ADR-0001: iol_router.py extraction — extract-clean with rename

<!-- status: accepted -->
**Status:** Accepted
**Date:** 2026-05-01
**Phase:** 1 (Runtime extraction)
**Closes:** EXTRACT-11
**Relates to:** EXTRACT-05 (openai_wrapper.py resolution, deferred to plan 13)

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

## openai_wrapper.py — resolution (deferred to plan 13)

Phase 1's smoke test on arlowe-1 needs the local LLM path to either work or be
explicitly bypassed. Plan 13 picks one of:

1. **Recover from git history** — `git -C ~/iol-monorepo log --all --diff-filter=D --summary -- "**/openai_wrapper.py"`. Restore if found.
2. **Eliminate the wrapper** — point `QWEN_URL` at `localhost:8000` (ax-llm native API; verified working). Lowest LOC delta. **Recommended.**
3. **Skip in Phase 1** — smoke test passes on cloud-only routing; restore local in a later phase. Documented gap.

The decision lands in plan 13 because that's where the smoke-test prep runs and
where we can verify-by-running. Plan 05 records the options and the recommendation;
plan 13 picks one and documents which.

`QWEN_URL` currently points at `:8001` (the broken wrapper endpoint). The comment
above the constant in `runtime/llm/router.py` documents this and references this ADR.

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
