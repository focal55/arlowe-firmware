---
plan: 12
phase: 01-runtime-extraction
status: COMPLETE
date: 2026-05-02
---

# Plan 12 Summary — ADR-0002: strip arlowe-scheduled-summary from firmware

## Decision

**Strip from firmware.** `arlowe-scheduled-summary.service`, its `.timer`, and
`arlowe-scheduled-summary.sh` are not extracted into `runtime/`.

## Files NOT extracted

- `~/.config/systemd/user/arlowe-scheduled-summary.service`
- `~/.config/systemd/user/arlowe-scheduled-summary.timer`
- `~/iol-monorepo/deploy/scripts/arlowe-scheduled-summary.sh`
- `~/.local/state/arlowe/summaries/`

## ADR written

`docs/architecture/0002-arlowe-scheduled-summary-stripped.md` — Status: Accepted, 98 lines.

Key rationale recorded: placeholder unit with no product value, runs on founder credentials,
costs API calls producing no output, Documentation URL is a banlist literal.

## Phase 2 follow-up flagged

Add `arlowe-scheduled-summary*` to SANIT-08 banlist in Phase 2 as defense in depth.

## Requirement

EXTRACT-12: COMPLETE
