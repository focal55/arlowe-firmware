# ADR-0002: arlowe-scheduled-summary.service — strip from firmware

**Status:** Accepted
**Date:** 2026-05-01
**Phase:** 1 (Runtime extraction)
**Closes:** EXTRACT-12
**Related:** ADR-0001 (iol_router extraction)

## Context

`arlowe-scheduled-summary.service` is a systemd `--user` unit on arlowe-1 with a paired `.timer`
running every 4 hours. It invokes `~/iol-monorepo/deploy/scripts/arlowe-scheduled-summary.sh`,
which calls `claude -p` to generate a "scheduled summary" written to
`~/.local/state/arlowe/summaries/`.

The Phase 1 roadmap (EXTRACT-12) asked: extract if generic, strip if founder-only.

## Evidence

Verified on arlowe-1.local 2026-05-01 (research §EXTRACT-12):

The unit's own documentation header reads:

> Description=Arlowe scheduled summary (Claude Code equivalent of the old openclaw hourly-progress cron)
> Documentation=https://github.com/focal55/iol-monorepo/blob/main/deploy/systemd/README.md

The shell script's header literally says:

> Currently does nothing meaningful because the Arlowe memory system is mid-rebuild.

The `claude -p` prompt the script issues:

> This scheduled run is a placeholder — return a single short line acknowledging that scheduled
> work will resume once the memory layout is rewired.

Concretely, the unit:

1. Runs `claude -p` (uses founder's `~/.claude/.credentials.json`)
2. Discards the response into a log line
3. Writes to `~/.local/state/arlowe/summaries/`
4. Produces no observable product behaviour

## Decision

**Strip from firmware.** No service unit, no script, and no related state directory is extracted
into `runtime/`.

## Rationale

1. **No product value.** By the script's own admission, it does nothing meaningful.
2. **Cost.** Customer units would issue `claude -p` calls every 4 hours without producing useful
   output. Even at penny-per-call this is unacceptable for a placeholder.
3. **Credential coupling.** `claude -p` depends on `~/.claude/.credentials.json` (founder
   credentials). Customer units don't have this; the service would fail or, worse, attempt to
   authenticate against an unprovisioned identity.
4. **Banlist target.** The Documentation URL points at `github.com/focal55/iol-monorepo/...`,
   which is a Phase 2 sanitization-gate banlist literal. Easier to remove the unit than carve out
   an exemption.

## Consequences

**Positive:**

- One fewer founder-only systemd unit to track in Phase 2's image-build banlist. (It is still
  listed in the banlist as defense in depth; the build refusing to package it catches any
  accidental re-introduction.)
- Cleaner runtime: no placeholder cron jobs in the shipped image.

**Negative / future considerations:**

- If, post-v1, a periodic on-device task makes sense (e.g., "summarize today's conversations and
  surface to dashboard", "purge expired transcripts beyond retention", "rotate logs"), it should be
  designed fresh as part of the local memory work or the log management work. **Do not retrofit
  this stripped unit** — its design assumptions (cloud LLM call, founder credentials, no
  product-user-facing output) don't apply to a customer product.
- Some product-relevant periodic work already exists: `purge-logs` runs via the `run-logrotate`
  flow (logrotate timer). That is a separate, kept artifact; do not conflate it with the stripped
  scheduled-summary.

## What is NOT extracted

- `~/.config/systemd/user/arlowe-scheduled-summary.service`
- `~/.config/systemd/user/arlowe-scheduled-summary.timer`
- `~/iol-monorepo/deploy/scripts/arlowe-scheduled-summary.sh`
- `~/.local/state/arlowe/summaries/` (founder-local state, never customer-facing)

## Phase 2 banlist coverage

Phase 2's sanitization gate (SANIT-08) bans `openclaw-*`, `trace-*`, and
`workforce-metrics-snapshot.*` unit names from the image build. **Add `arlowe-scheduled-summary*`
to that banlist** as a follow-up enhancement: even though this ADR strips the unit, defense in
depth means the image build also refuses to package it if someone tries to add it back.

## References

- Research findings: `.planning/phases/01-runtime-extraction/01-RESEARCH.md` §EXTRACT-12
- Roadmap requirement: `.planning/REQUIREMENTS.md` EXTRACT-12
- Sister ADR: `docs/architecture/0001-iol-router-extraction.md` (extract-clean for iol_router)
