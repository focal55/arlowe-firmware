---
phase: 02-sanitization-gate
plan: 01
status: complete
date: 2026-05-26
---

# Plan 02-01 Summary — Grep gate runner, allow-list, CI workflow skeleton

## What landed

### `scripts/sanitize/check.sh`
- Flags: `--grep-only` (active; runs the banlist scan), `--units-only` (placeholder, exits 0 with a note — Plan 02 implements it), `--scan-dir DIR` (placeholder, exits 0 — reserved for Plan 06 image-build hook).
- No-flag default: `--grep-only`. When Plan 02 lands, no-flag will run both gates.
- Emits `::error file=PATH,line=LINE,col=COL,title=Banned identity literal::...` annotations for inline PR marks.
- Each failure message includes `.sanitize-allowlist` so an agent can self-correct without a human round-trip.
- Exit 0 on clean tree; exit 1 if any hits.
- Uses `git ls-files -- :(exclude,glob)PATTERN...` pathspec engine for allow-list filtering — no extra dependency.

### `scripts/sanitize/banlist.txt`
Six case-insensitive fixed-string literals: `focal55`, `arlowe-1`, `casa_ybarra_chelsea`, `/home/focal55`, `joe@focal55`, `iol-monorepo`. No comments, no blank lines inside data (rg `-f` treats each line as a pattern).

### `.sanitize-allowlist`
Initial 24 entries. Globs are gitignore-style (`**` required for recursive — documented in header comment).

### `scripts/sanitize/test-check.sh`
Plants `user: focal55` in a `mktemp -d` git tree; asserts `check.sh --grep-only` exits non-zero; prints `PASS:` on success. The file is itself allow-listed so the literal doesn't trip the production gate.

### `.github/workflows/sanitize.yml`
Two jobs:
- `banlist-and-units`: checkout → `rg --version` sanity → `bash scripts/sanitize/check.sh --grep-only`
- `self-test`: checkout → `bash scripts/sanitize/test-check.sh`

No `paths:` filter (required-check + path filter = pending-forever trap per RESEARCH §Pitfall 1). Workflow runs on every PR and push to `main`.

## Why workforce plumbing is allow-listed path-wide

`.github/CODEOWNERS`, `AGENTS.md.template`, `README.md`, and `docs/architecture-overview.md` reference `@focal55` and `github.com/focal55/...` for legitimate workforce-protocol purposes. None of these files ship in any firmware image. The risk SANIT exists to prevent is founder-identity strings in customer images, not in developer-facing repo files. This resolves RESEARCH Open Questions 1 and 2.

The `.planning/**` wildcard covers all planning artifacts including `02-RESEARCH.md` and `02-CONTEXT.md`, which contain every banned literal as documentation by design.

## Verification snapshot (current `main` before Plan 04)

`bash scripts/sanitize/check.sh --grep-only` reports **25 hits** across **runtime/** files. These are the dirty-tree hits Plan 04 will drive to zero:

- `runtime/dashboard/app/layout.tsx` — 1 hit
- `runtime/dashboard/app/components/RetroActivityMonitor.tsx` — 1 hit
- `runtime/dashboard/README.md` — 1 hit
- `runtime/face/README.md` — 3 hits
- `runtime/face/requirements.txt` — 3 hits
- `runtime/llm/README.md` — 1 hit
- `runtime/llm/requirements.txt` — 1 hit
- `runtime/llm/router.py` — 1 hit
- `runtime/llm/run_api.sh` — 1 hit
- `runtime/stt/README.md` — 1 hit
- `runtime/tts/manifest.yml` — 2 hits
- `runtime/tts/README.md` — 4 hits
- `runtime/voice/README.md` — 1 hit
- `runtime/voice/requirements.txt` — 1 hit
- `runtime/wake-word/README.md` — 1 hit
- `runtime/wake-word/requirements.txt` — 1 hit

No hits in allow-listed paths (`.planning/`, `docs/`, `README.md`, `scripts/sanitize/`, etc.).

## Next steps

- **Plan 02**: Implements `--units-only` (the unit-name block for `openclaw-*`, `trace-*`, `workforce-metrics-snapshot.*` systemd units) and extends `check.sh`.
- **Plan 03**: Adds the Playwright dashboard rendered-text gate (`runtime/dashboard/tests/sanitize.spec.ts`) and a third job in `sanitize.yml`.
- **Plan 04**: Sanitizes the current `runtime/` tree (25 hits above) to drive the gate green on `main`.
