# Phase 2: Sanitization Gate - Context

**Gathered:** 2026-05-25
**Status:** Ready for planning

<domain>
## Phase Boundary

Three mechanical sanitization gates that prevent founder identity from re-entering the codebase or shipping in firmware:

1. **CI grep gate** — fails any PR that introduces a banned identity literal in tracked files
2. **Image-build unit-name block** — fails CI if any tracked systemd unit file matches a banned founder-only service name (Phase 6 will reuse the same script at image-assembly time)
3. **Dashboard rendered-text gate** — Playwright test fails if any banned literal appears in rendered dashboard HTML

Plus: ensure the current `runtime/` tree passes all gates (SC4).

**Strategic role.** This is the *guardrail* phase. Phase 1 just landed a clean tree; every subsequent phase (service user, config overlay, image build, pairing, OTA, support access, dashboard surfaces) will add a lot of new code. Without this gate, each one would need a manual re-audit before merge. Landing it now is the cheapest possible moment.

**Why this matters specifically because we ship firmware.** Founder-only services aren't just labels — `openclaw-*`, `trace-*`, and `workforce-metrics-snapshot.*` are services that phone home to founder infrastructure. If one shipped on a customer's Pi, their device would try to reach founder-internal endpoints from their home network. The grep gate catches strings; the systemd-unit block catches the actual surveillance vectors. The artifact ships to physical hardware that can't be hot-fixed — the image build is the last reversible checkpoint, and Phase 12's first-flash SC1 grep-verifies a mounted SD card. Phase 2 is what makes that verification pass mechanically instead of by accident.

Out of scope: secrets scanning, license scanning, PII detection, founder name/brand literals beyond the 6 from ROADMAP SC1.

</domain>

<decisions>
## Implementation Decisions

### Banned-literal list & matching
- **List locked to the 6 from ROADMAP SC1**: `focal55`, `arlowe-1`, `casa_ybarra_chelsea`, `/home/focal55`, `joe@focal55`, `iol-monorepo`
- **Case-insensitive** matching (catches `Focal55`, `FOCAL55`, `/Home/Focal55`)
- **Substring (raw grep)** matching — no word-boundary anchoring; accept the false-positive risk for simpler implementation
- **Scans the whole tracked tree** — every file `git ls-files` returns

### Allow-list + failure ergonomics
- **Single file: `.sanitize-allowlist` at repo root**; entries are path globs (e.g., `.planning/**`, `docs/architecture/0001-*.md`, `docs/journey/**`)
- A path glob in the allow-list permits *any* banned literal in matching files — no per-literal precision
- **Comments on entries are optional**, not required
- **Failure output**: exit code + grep-style stdout (`path:line: literal`) + GitHub Actions `::error file=...,line=...` annotations so PRs show inline red marks at offending lines
- **Where it runs**: GitHub Actions PR check only, marked **required** on the default branch. No pre-commit hook. Agents and humans both discover failure via PR status.

### Image-build unit-name block
- **Phase 2 ships a tracked-file scan now**; Phase 6 reuses the same script when wiring pi-gen
- **Banned patterns locked to the 3 from ROADMAP SC2**: `openclaw-*`, `trace-*`, `workforce-metrics-snapshot.*`
- **Scan scope**: all tracked systemd unit files by extension — `*.service`, `*.timer`, `*.socket`, `*.target`, `*.mount`, `*.path`
- **Deliberate-failure test case = unit test on the script**: temp dir containing a fake `openclaw-test.service`, assert the script exits non-zero. Runs in CI alongside the gate itself. No fixture file committed under a production-scanned path.

### Dashboard snapshot strategy
- **Tool: Playwright** (already wired up in `runtime/dashboard/`, see `playwright.config.ts` and existing `tests/*.spec.ts`)
- **Text content only** — `page.content()` (rendered HTML) grep-checked for the 6 banned literals; no screenshots, no href/attribute scanning
- **Backend strategy**: dashboard runs via `pnpm dev` (or `playwright webServer`) with real, unconfigured API routes; pages render with empty/error states, which is what the gate validates against. Closest to production behavior, no fixture maintenance.
- **Route enumeration**: auto-discover from `runtime/dashboard/app/` directory structure (or Next route manifest) so new pages are covered automatically
- **File location**: new `runtime/dashboard/tests/sanitize.spec.ts`

### Claude's Discretion
- Grep-gate implementation tool (ripgrep + shell vs Python script). Lean toward whichever produces cleaner structured output for GitHub annotations.
- Exact mechanism for auto-discovering Next routes (filesystem walk over `app/` vs Next route manifest)
- File layout under `scripts/` (single `scripts/sanitize/` directory vs flat scripts)
- Whether the unit-name check is its own script or folded into the same runner as the grep gate
- Allow-list comment syntax (probably `#` line comments — same as `.gitignore`)
- CI workflow file naming/structure (`.github/workflows/sanitize.yml` vs adding a step to an existing workflow)
- Whether to emit a "did you mean" hint message on failure ("if this is a legit historical reference, add the path to .sanitize-allowlist")

</decisions>

<specifics>
## Specific Ideas

- The grep-gate failure output should be **agent-parseable**: `path/to/file.py:42: focal55` is enough for an agent to retry with context. A hint message ("banned identity literal; if it's a legit historical reference, add the path to .sanitize-allowlist") helps an agent self-correct without a human round-trip.
- The dashboard snapshot test should treat **error states as legitimate render targets** — the goal is "no banned literal in the rendered output," and error pages are part of the rendered surface that ships.
- The 3 banned unit prefixes (`openclaw-*`, `trace-*`, `workforce-metrics-snapshot.*`) match exactly the units present in `.dev-stash/arlowe-1/systemd-user/` — `.dev-stash/` is gitignored so they don't trip the gate today, but the prefixes are calibrated to those exact founder-internal services.

</specifics>

<deferred>
## Deferred Ideas

- **Screenshots from headless dashboard run** — ROADMAP SC3 mentions this; text-grep covers the same signal without screenshot maintenance overhead. ROADMAP SC3 may be amended to drop screenshots, or they may be added in a later phase if Phase 12 first-flash reveals a gap that text-grep missed.
- **Link `href` / attribute scanning in dashboard snapshot** — ROADMAP SC3 mentions "links to founder repos or workforce-internal endpoints." Text-grep on rendered HTML won't catch a banned literal inside an `<a href="...">` attribute value, but the source-tree grep gate *will* catch it in the source that produced the href. Defended by overlap; revisit if a real miss is observed.
- **Founder name/brand literals beyond the 6** (`Joe Ybarra`, `joeybarrajr`, `Ybarra`, `8bit Homies`, `focal55.com`) — explicitly scoped out per Area 1 decision. Could be added in a follow-up phase or as a hot-fix if a leak is found in practice.
- **Allow-list expiry / audit / required-reviewer approval on `.sanitize-allowlist` changes** — considered and rejected; allow-list edits are normal PRs reviewed normally.
- **Per-literal allow-list precision** (`docs/architecture/0001-*.md: iol-monorepo` allows only `iol-monorepo` there, not `focal55`) — rejected for v1; whole-file allowance via path glob is simpler.
- **Local pre-commit hook** — skipped; PR check is sufficient.
- **Generic identity-rule config** (hostname/email/handle patterns instead of literal list) — over-engineered for v1.
- **API response sanitization checks** (`/api/config`, `/api/voice`, etc.) — covered transitively by the source-tree grep gate; deferred unless a runtime-generated literal is observed.
- **Banned unit-content scanning** (e.g., `ExecStart=/home/focal55/...` inside a `whisper-stt.service`) — partially covered by the grep gate already scanning the unit file's text. No separate content scan needed.

</deferred>

---

*Phase: 02-sanitization-gate*
*Context gathered: 2026-05-25*
