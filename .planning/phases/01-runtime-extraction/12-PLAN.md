---
phase: 01-runtime-extraction
plan: 12
type: execute
wave: 2
depends_on: ["01"]
files_modified:
  - docs/architecture/0002-arlowe-scheduled-summary-stripped.md
  - .planning/phases/01-runtime-extraction/01-12-SUMMARY.md
autonomous: true

requirements:
  - "EXTRACT-12: arlowe-scheduled-summary.service reviewed; extracted if generic, stripped if founder-only; decision recorded as ADR"

must_haves:
  truths:
    - "docs/architecture/0002-arlowe-scheduled-summary-stripped.md exists and records the strip-from-firmware decision"
    - "ADR cites the live evidence (script header literally says 'currently does nothing meaningful')"
    - "ADR notes that no service unit, script, or related artifact is extracted into runtime/"
    - "If a future scheduled task is desired post-v1, ADR documents that it should be designed fresh, not retrofitted"
  artifacts:
    - path: "docs/architecture/0002-arlowe-scheduled-summary-stripped.md"
      provides: "ADR for stripping arlowe-scheduled-summary.service"
      min_lines: 40
  key_links:
    - from: "docs/architecture/0002-arlowe-scheduled-summary-stripped.md"
      to: "EXTRACT-12 requirement"
      via: "Status: Accepted; closes EXTRACT-12"
      pattern: "EXTRACT-12"
---

<objective>
Author `docs/architecture/0002-arlowe-scheduled-summary-stripped.md` recording the decision to strip `arlowe-scheduled-summary.service` (and its associated `.timer` and the `~/iol-monorepo/deploy/scripts/arlowe-scheduled-summary.sh` script) from the firmware. NO code is extracted; this plan is purely the ADR.

Purpose: Land EXTRACT-12. Per research §EXTRACT-12, the service is a placeholder that "currently does nothing meaningful" per its own documentation, runs `claude -p` with founder credentials, and writes throwaway log lines. Shipping it to customer units would be wasteful and depend on founder credentials.

Output: ADR-0002. No runtime code changes. Plans 02-11 already exclude these artifacts by virtue of not pulling them.
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
  <name>Task 1: Author ADR-0002 — strip arlowe-scheduled-summary from firmware</name>
  <files>docs/architecture/0002-arlowe-scheduled-summary-stripped.md</files>
  <action>
Author `docs/architecture/0002-arlowe-scheduled-summary-stripped.md`:

```markdown
# ADR-0002: arlowe-scheduled-summary.service — strip from firmware

**Status:** Accepted
**Date:** 2026-05-01
**Phase:** 1 (Runtime extraction)
**Closes:** EXTRACT-12
**Related:** ADR-0001 (iol_router extraction)

## Context

`arlowe-scheduled-summary.service` is a systemd `--user` unit on arlowe-1 with a paired `.timer` running every 4 hours. It invokes `~/iol-monorepo/deploy/scripts/arlowe-scheduled-summary.sh`, which calls `claude -p` to generate a "scheduled summary" written to `~/.local/state/arlowe/summaries/`.

The Phase 1 roadmap (EXTRACT-12) asked: extract if generic, strip if founder-only.

## Evidence

Verified on arlowe-1.local 2026-05-01 (research §EXTRACT-12):

The unit's own documentation header reads:
> Description=Arlowe scheduled summary (Claude Code equivalent of the old openclaw hourly-progress cron)
> Documentation=https://github.com/focal55/iol-monorepo/blob/main/deploy/systemd/README.md

The shell script's header literally says:
> Currently does nothing meaningful because the Arlowe memory system is mid-rebuild.

The `claude -p` prompt the script issues:
> This scheduled run is a placeholder — return a single short line acknowledging that scheduled work will resume once the memory layout is rewired.

Concretely, the unit:
1. Runs `claude -p` (uses founder's `~/.claude/.credentials.json`)
2. Discards the response into a log line
3. Writes to `~/.local/state/arlowe/summaries/`
4. Produces no observable product behaviour

## Decision

**Strip from firmware.** No service unit, no script, no related state directory is extracted into `runtime/`.

## Rationale

1. **No product value.** By the script's own admission, it does nothing meaningful.
2. **Cost.** Customer units would issue `claude -p` calls every 4 hours without producing useful output. Even at penny-per-call this is unacceptable for "does nothing".
3. **Credential coupling.** `claude -p` depends on `~/.claude/.credentials.json` (founder credentials). Customer units don't have this; the service would fail or worse, attempt to authenticate against an unprovisioned identity.
4. **Banlist target.** The Documentation URL points at `github.com/focal55/iol-monorepo/...` which is a Phase 2 sanitization-gate banlist literal. Easier to remove the unit than carve out an exemption.

## Consequences

**Positive:**
- One fewer founder-only systemd unit to track in Phase 2's image-build banlist (it's still listed; the build refusing to package it is a defense-in-depth measure even after this strip).
- Cleaner runtime: no placeholder cron jobs.

**Negative / future considerations:**
- If, post-v1, a periodic on-device task makes sense (e.g., "summarize today's conversations and surface to dashboard", "purge expired transcripts beyond retention", "rotate logs"), it should be designed fresh as part of the local memory work or the log management work. **Do not retrofit this stripped unit** — its design assumptions (cloud LLM call, founder credentials, no product user-facing output) don't apply to a customer product.
- Some product-relevant periodic work already exists: `purge-logs` runs via the `run-logrotate` flow (logrotate timer). That's a separate, kept artifact; don't conflate it with the stripped scheduled-summary.

## What is NOT extracted

- `~/.config/systemd/user/arlowe-scheduled-summary.service`
- `~/.config/systemd/user/arlowe-scheduled-summary.timer`
- `~/iol-monorepo/deploy/scripts/arlowe-scheduled-summary.sh`
- `~/.local/state/arlowe/summaries/` (founder-local state, never customer-facing)

## Phase 2 banlist coverage

Phase 2's sanitization gate (SANIT-08) bans `openclaw-*`, `trace-*`, and `workforce-metrics-snapshot.*` unit names from the image build. **Add `arlowe-scheduled-summary*` to that banlist** as a follow-up enhancement: even though this ADR strips the unit, defense in depth means the image build also refuses to package it if someone tries to add it back.

## References

- Research findings: `.planning/phases/01-runtime-extraction/01-RESEARCH.md` §EXTRACT-12
- Roadmap requirement: `.planning/REQUIREMENTS.md` EXTRACT-12
- Sister ADR: `docs/architecture/0001-iol-router-extraction.md` (extract-clean for iol_router)
```

40-100 lines. Plain markdown, no emoji.
  </action>
  <verify>
```bash
test -f docs/architecture/0002-arlowe-scheduled-summary-stripped.md && \
  test "$(wc -l < docs/architecture/0002-arlowe-scheduled-summary-stripped.md)" -ge 40 && \
  grep -qi 'status: accepted' docs/architecture/0002-arlowe-scheduled-summary-stripped.md && \
  grep -qi 'strip from firmware' docs/architecture/0002-arlowe-scheduled-summary-stripped.md && \
  grep -qi 'EXTRACT-12' docs/architecture/0002-arlowe-scheduled-summary-stripped.md && \
  echo OK
```
  </verify>
  <done>ADR-0002 written, status Accepted, decision recorded with evidence, references EXTRACT-12 and Phase 2 banlist follow-up.</done>
</task>

</tasks>

<verification>
This plan adds one doc file. Trivial PR.

```bash
# ADR exists and is properly structured
test -f docs/architecture/0002-arlowe-scheduled-summary-stripped.md
grep -E '^# ADR-0002|^\*\*Status:|^\*\*Closes:' docs/architecture/0002-arlowe-scheduled-summary-stripped.md
```

PR-size: <100 lines. Single new doc file.
</verification>

<success_criteria>
- ADR-0002 exists, ≥40 lines
- Status: Accepted; Closes: EXTRACT-12
- Decision: strip from firmware
- Evidence cited from live arlowe-1 inspection
- Phase 2 banlist follow-up noted
</success_criteria>

<output>
After completion, create `.planning/phases/01-runtime-extraction/01-12-SUMMARY.md` documenting:
- ADR-0002 decision summary
- Files NOT extracted (the strip list)
- Follow-up work flagged for Phase 2 banlist
- EXTRACT-12: COMPLETE
</output>
