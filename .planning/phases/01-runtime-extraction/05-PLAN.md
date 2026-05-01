---
phase: 01-runtime-extraction
plan: 05
type: execute
wave: 2
depends_on: ["01"]
files_modified:
  - runtime/llm/router.py
  - runtime/llm/run_api.sh
  - runtime/llm/qwen2.5_tokenizer_uid.py
  - runtime/llm/requirements.txt
  - runtime/llm/README.md
  - docs/architecture/0001-iol-router-extraction.md
  - .planning/phases/01-runtime-extraction/01-05-SUMMARY.md
autonomous: true

requirements:
  - "EXTRACT-05: ax-llm runtime invocation (run_api.sh, qwen2.5_tokenizer_uid.py, openai_wrapper.py) extracts to runtime/llm/"
  - "EXTRACT-11: iol_router.py reviewed; clean version extracted OR stubbed; founder IOL integration paths excised"

must_haves:
  truths:
    - "runtime/llm/router.py exists (renamed from iol_router.py per ADR-0001)"
    - "router.py has no `focal55` / `iol-monorepo` / `~/.claude/workspace` literals"
    - "router.py reads CLAUDE_BIN from config or PATH lookup, not /home/focal55/.local/bin/claude"
    - "router.py writes usage stats to /var/lib/arlowe/state/usage-stats.json (not ~/.claude/workspace)"
    - "run_api.sh system prompt does NOT contain `Joe`"
    - "docs/architecture/0001-iol-router-extraction.md exists and records the extract-clean decision plus the openai_wrapper resolution direction"
    - "openai_wrapper.py decision is documented (recovered from history / written fresh / eliminated by repointing to :8000) — actual implementation work happens in plan 13's smoke-test prep"
  artifacts:
    - path: "runtime/llm/router.py"
      provides: "Local/cloud LLM dispatch (renamed from iol_router.py)"
      min_lines: 400
    - path: "runtime/llm/run_api.sh"
      provides: "ax-llm server launcher; system prompt sanitized"
      min_lines: 5
      contains: "main_api_axcl_aarch64"
    - path: "runtime/llm/qwen2.5_tokenizer_uid.py"
      provides: "Qwen tokenizer HTTP server (port 12345)"
      min_lines: 100
    - path: "runtime/llm/requirements.txt"
      provides: "Pinned PyPI deps"
    - path: "runtime/llm/README.md"
      provides: "Documents the local/cloud dispatch, ports 8000/8001/12345, ADR-0001 reference"
      min_lines: 40
    - path: "docs/architecture/0001-iol-router-extraction.md"
      provides: "ADR for the rename + extract-clean decision + openai_wrapper resolution"
      min_lines: 50
  key_links:
    - from: "runtime/llm/router.py"
      to: "ax-llm at localhost:8000 OR shim at localhost:8001"
      via: "HTTP POST"
      pattern: "localhost:800[01]"
    - from: "runtime/llm/router.py"
      to: "claude CLI"
      via: "subprocess.run with config-resolved path"
      pattern: "claude.*-p|CLAUDE_BIN"
---

<objective>
Extract the LLM stack: rename `iol_router.py` → `runtime/llm/router.py` per ADR-0001 (extract-clean, no stub), copy `run_api.sh` and `qwen2.5_tokenizer_uid.py` from `~/models/Qwen2.5-7B-Instruct/`, sanitize all founder paths, scrub the "Your human is Joe" line from the system prompt, and write `docs/architecture/0001-iol-router-extraction.md` recording the decisions (extract-clean + openai_wrapper resolution direction).

Purpose: Land EXTRACT-05 (mostly — `openai_wrapper.py` resolution executes in plan 13) and EXTRACT-11 (the ADR + sanitized router). This is the LLM half of the smoke test.

Output: `runtime/llm/` populated, ADR-0001 written, system prompt clean.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/REQUIREMENTS.md
@.planning/phases/01-runtime-extraction/01-RESEARCH.md
@.planning/phases/01-runtime-extraction/01-01-SUMMARY.md
</context>

<tasks>

<task type="auto">
  <name>Task 1: Copy LLM source files into runtime/llm/ and rename iol_router → router</name>
  <files>
    runtime/llm/router.py
    runtime/llm/run_api.sh
    runtime/llm/qwen2.5_tokenizer_uid.py
  </files>
  <action>
Assumes `dev-pull-from-pi.sh --apply` has populated `.dev-stash/arlowe-1/`.

1. Copy `.dev-stash/arlowe-1/whisplay/iol_router.py` → `runtime/llm/router.py` (verbatim, ~452 LOC). The rename happens at the destination path; the file content stays identical for now.

2. Copy `.dev-stash/arlowe-1/llm/run_api.sh` → `runtime/llm/run_api.sh` (verbatim, ~12 lines).

3. Copy `.dev-stash/arlowe-1/llm/qwen2.5_tokenizer_uid.py` → `runtime/llm/qwen2.5_tokenizer_uid.py` (verbatim).

4. **DO NOT yet** create `openai_wrapper.py`. Per research §EXTRACT-05, the file is missing on the Pi and the resolution (option 1: recover/write / option 2: eliminate by repointing to :8000 / option 3: skip in Phase 1) is recorded in the ADR (Task 4) and executed in plan 13. Plan 05 stops at "decision recorded".

5. Make `run_api.sh` executable: `chmod +x runtime/llm/run_api.sh`.
  </action>
  <verify>
```bash
test -f runtime/llm/router.py && \
  test -x runtime/llm/run_api.sh && \
  test -f runtime/llm/qwen2.5_tokenizer_uid.py && \
  python3 -c "import ast; ast.parse(open('runtime/llm/router.py').read())" && \
  python3 -c "import ast; ast.parse(open('runtime/llm/qwen2.5_tokenizer_uid.py').read())" && \
  bash -n runtime/llm/run_api.sh && \
  echo OK
```
  </verify>
  <done>Files copied, router.py named correctly (the rename), run_api.sh executable. No openai_wrapper.py yet — that's plan 13.</done>
</task>

<task type="auto">
  <name>Task 2: Sanitize router.py — paths, CLAUDE_BIN, usage-stats, system prompt note</name>
  <files>runtime/llm/router.py</files>
  <action>
Apply per research §EXTRACT-11 (concrete sanitization steps):

1. **L36-37**: Replace
   ```python
   USAGE_STATS_PATH = Path.home() / ".claude/workspace/usage-stats.json"
   ```
   With:
   ```python
   USAGE_STATS_PATH = Path("/var/lib/arlowe/state/usage-stats.json")
   USAGE_STATS_PATH.parent.mkdir(parents=True, exist_ok=True)
   ```

2. **L48**: Replace
   ```python
   CLAUDE_BIN = "/home/focal55/.local/bin/claude"
   ```
   With:
   ```python
   import shutil
   CLAUDE_BIN = os.environ.get("ARLOWE_CLAUDE_BIN") or shutil.which("claude") or "/usr/bin/claude"
   ```
   (The cloud path may not work on a customer unit anyway — see ADR Task 4. The fail-fast happens at first invocation, not at module load, so `which("claude") or "/usr/bin/claude"` is acceptable as a default.)

3. **L40-41 (or wherever `QWEN_URL` lives)**: Currently `"http://localhost:8001/..."`. Per ADR-0001 direction (Task 4), we'll either:
   - Keep `8001` and rely on plan 13 fixing the wrapper (option 1)
   - Switch to `8000` directly (option 2 — recommended)
   For Phase 1: leave as `8001` BUT add a comment that the resolution happens in plan 13:
   ```python
   # NOTE: This URL routes through openai_wrapper.py on :8001 today.
   # qwen-openai.service is currently in restart loop — see ADR-0001 §Resolution.
   # Plan 13's smoke test prep either restores the wrapper or repoints this to :8000.
   QWEN_URL = "http://localhost:8001/v1/chat/completions"
   ```

4. **VOICE_MODEL env var (L50)**: Already env-var defaulted (`os.environ.get("ARLOWE_VOICE_MODEL", "claude-haiku-4-5")`). Keep as-is. Add a comment that this is config-knob territory for Phase 4.

5. **DISALLOWED_TOOLS list (L74-79)**: Keep AS-IS. Add comment:
   ```python
   # DISALLOWED_TOOLS is a defense-in-depth measure: the names listed here are
   # Claude Code workforce tools that should never be invoked from the voice path
   # even on a dev unit. The list is not load-bearing — it just prevents accidents
   # if a customer unit somehow ends up with workforce tooling on PATH.
   ```

6. **Imports**: Update to use the new package layout. Search for any imports of `sentiment_classifier` and rewrite to `from face.sentiment_classifier import ...`.

7. **Module docstring**: At the top, replace the historical comment about IOL/OpenClaw with:
   ```python
   """LLM router.

   Dispatches between local Qwen (HTTP, on-device) and cloud Claude (subprocess).
   Renamed from iol_router.py per ADR-0001 — the "IOL" prefix was historical
   residue; this module has no IOL infrastructure dependency.
   """
   ```
   Preserve the existing routing-logic comments below the docstring.

8. **Strip any remaining founder literals**: grep the file for `focal55`, `iol`, `OpenClaw`, `\.claude/workspace`, `/home/focal55`. Anything found, sanitize per the patterns above or delete.

After edits, the file must still parse as valid Python.
  </action>
  <verify>
```bash
# No founder literals
! grep -in 'focal55\|/home/focal55\|\.claude/workspace\|joe@focal55\|casa_ybarra\|iol-monorepo' runtime/llm/router.py

# Path-sanitized constants present
grep -q '/var/lib/arlowe/state/usage-stats.json' runtime/llm/router.py
grep -q 'ARLOWE_CLAUDE_BIN' runtime/llm/router.py

# ADR reference present
grep -q 'ADR-0001\|0001-iol-router' runtime/llm/router.py

# Still parses
python3 -c "import ast; ast.parse(open('runtime/llm/router.py').read())"

echo OK
```
  </verify>
  <done>router.py sanitized; CLAUDE_BIN resolves via env / shutil.which / fallback; usage stats write to /var/lib/arlowe; ADR referenced.</done>
</task>

<task type="auto">
  <name>Task 3: Sanitize run_api.sh — strip "Your human is Joe"</name>
  <files>runtime/llm/run_api.sh</files>
  <action>
Per research §EXTRACT-05 L13, the script contains:
```bash
--system_prompt "You are Arlowe, a friendly AI assistant with a calm, curious personality. Soft neon blue vibe. Be brief, conversational, and helpful. You live on a Raspberry Pi 5 with an Axera NPU. Your human is Joe."
```

Replace **`Your human is Joe.`** with **`Your human is the device owner.`** (research-recommended phrasing).

Also: any path references to `/home/focal55/...` for the `main_api_axcl_aarch64` binary or the model directory — replace with config-knob-style paths:
```bash
# Resolve at runtime; image build provisions these under /opt/arlowe/.
AX_LLM_BIN="${AX_LLM_BIN:-/opt/arlowe/runtime/llm/bin/main_api_axcl_aarch64}"
QWEN_MODEL_DIR="${QWEN_MODEL_DIR:-/opt/arlowe/models/qwen2.5-7b-int4-ax650}"
```

Update the rest of the script to use those vars. Keep `set -e` if not already present.

NOTE: For the Phase 1 smoke test, the binary lives at `~/ax-llm/build/main_api_axcl_aarch64` on arlowe-1. The smoke test (plan 13) sets `AX_LLM_BIN` and `QWEN_MODEL_DIR` to point at the existing locations. This is documented in plan 13's setup, not here.
  </action>
  <verify>
```bash
# No "Joe" in the system prompt
! grep -n 'Your human is Joe\|focal55' runtime/llm/run_api.sh

# Replacement phrasing present
grep -q 'device owner' runtime/llm/run_api.sh

# Env-overridable paths
grep -q 'AX_LLM_BIN\|QWEN_MODEL_DIR' runtime/llm/run_api.sh

# Still valid bash
bash -n runtime/llm/run_api.sh

echo OK
```
  </verify>
  <done>"Your human is Joe" replaced with "Your human is the device owner". Paths env-overridable. Script still valid bash.</done>
</task>

<task type="auto">
  <name>Task 4: Author ADR-0001 — iol-router extract-clean + openai_wrapper resolution</name>
  <files>docs/architecture/0001-iol-router-extraction.md</files>
  <action>
Author `docs/architecture/0001-iol-router-extraction.md` covering:

```markdown
# ADR-0001: iol_router.py extraction — extract-clean with rename

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
- `CLAUDE_BIN`: hardcoded `/home/focal55/.local/bin/claude` → env override + `shutil.which("claude")` + `/usr/bin/claude` fallback
- Module docstring rewritten to explain the rename
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
```

50-100 lines. Plain markdown, no emoji.
  </action>
  <verify>
```bash
test -f docs/architecture/0001-iol-router-extraction.md && \
  test "$(wc -l < docs/architecture/0001-iol-router-extraction.md)" -ge 50 && \
  grep -qi 'status: accepted' docs/architecture/0001-iol-router-extraction.md && \
  grep -qi 'extract-clean' docs/architecture/0001-iol-router-extraction.md && \
  grep -qi 'openai_wrapper' docs/architecture/0001-iol-router-extraction.md && \
  echo OK
```
  </verify>
  <done>ADR-0001 written, status Accepted, captures rename + sanitization + openai_wrapper resolution direction. EXTRACT-11 closed at the decision level.</done>
</task>

<task type="auto">
  <name>Task 5: Author runtime/llm/requirements.txt and runtime/llm/README.md</name>
  <files>
    runtime/llm/requirements.txt
    runtime/llm/README.md
  </files>
  <action>
**`runtime/llm/requirements.txt`**: Pin from arlowe-1's voice venv. Likely:
- `requests` (HTTP to local Qwen)
- (whatever else router.py and qwen2.5_tokenizer_uid.py import)

The qwen tokenizer Python script may also pull in `transformers` or similar — confirm by reading the imports.

**`runtime/llm/README.md`**:
- Module purpose: local-first LLM dispatch
- Components:
  - `router.py` — local/cloud dispatcher (rename of iol_router.py per ADR-0001)
  - `run_api.sh` — launches `main_api_axcl_aarch64` (the ax-llm HTTP server) on port 8000
  - `qwen2.5_tokenizer_uid.py` — tokenizer HTTP service on port 12345
  - `openai_wrapper.py` — **NOT YET RESTORED**, see ADR-0001 §"openai_wrapper.py — resolution"
- Service start order (per research §Boot health): `qwen-tokenizer` → `qwen-api` → `qwen-openai`
- Ports:
  | Port | Service | Provides |
  |---|---|---|
  | 12345 | qwen-tokenizer | Tokenizer HTTP |
  | 8000 | qwen-api | ax-llm native HTTP (works) |
  | 8001 | qwen-openai | OpenAI-compat shim (BROKEN — see ADR-0001) |
- Cloud path: subprocess to `claude` CLI; requires per-customer credentials (Phase 7 fix)
- Reference ADR-0001 for the rename and the wrapper resolution
- Reference research file for the wrapper-broken-state diagnosis

40-80 lines.
  </action>
  <verify>
```bash
test -f runtime/llm/requirements.txt && \
  test -f runtime/llm/README.md && \
  test "$(wc -l < runtime/llm/README.md)" -ge 40 && \
  grep -q '8000\|8001\|12345' runtime/llm/README.md && \
  grep -qi 'adr-0001\|0001-iol-router' runtime/llm/README.md && \
  grep -qi 'openai_wrapper' runtime/llm/README.md && \
  echo OK
```
  </verify>
  <done>requirements.txt pins LLM deps; README documents components, ports, ADR-0001 reference, openai_wrapper status.</done>
</task>

</tasks>

<verification>
Phase-level checks for this plan:

```bash
# Files exist and parse
python3 -c "import ast; [ast.parse(open(f).read()) for f in ['runtime/llm/router.py','runtime/llm/qwen2.5_tokenizer_uid.py']]"
bash -n runtime/llm/run_api.sh

# No founder literals
! grep -rn 'focal55\|/home/focal55\|\.claude/workspace\|joe@focal55\|casa_ybarra\|iol-monorepo' runtime/llm/

# Specific sanitizations landed
grep -q '/var/lib/arlowe/state' runtime/llm/router.py
grep -q 'ARLOWE_CLAUDE_BIN' runtime/llm/router.py
grep -q 'device owner' runtime/llm/run_api.sh
! grep -n 'Your human is Joe' runtime/llm/run_api.sh

# ADR exists
test -f docs/architecture/0001-iol-router-extraction.md
```

PR size: ~452 LOC router copy + ~12 LOC bash + ~tokenizer copy + ~50 line ADR + 50 line README + small requirements ≈ 700 raw lines, ~50 net new logic lines. Splittable as 05a (copy + sanitize) and 05b (ADR + docs) if PR cap is enforced.
</verification>

<success_criteria>
- runtime/llm/{router.py, run_api.sh, qwen2.5_tokenizer_uid.py} exist
- Zero founder literals in runtime/llm/
- "Your human is Joe" gone from system prompt
- USAGE_STATS_PATH writes to /var/lib/arlowe/state
- CLAUDE_BIN resolves via env / which / fallback
- ADR-0001 written, references the openai_wrapper deferred resolution
- README documents the contract; ports table captures the broken :8001 status
</success_criteria>

<output>
After completion, create `.planning/phases/01-runtime-extraction/01-05-SUMMARY.md` documenting:
- Files extracted (router.py renamed)
- Sanitization changes (USAGE_STATS_PATH, CLAUDE_BIN, system prompt)
- ADR-0001 decisions
- openai_wrapper.py status: deferred to plan 13
- Voice client (plan 02) imports `llm.router` — wired
</output>
