---
phase: 02-sanitization-gate
plan: 03
type: summary
status: complete
branch: feat/sanitize-02-03-dashboard-gate
---

# Plan 02-03 Summary: Playwright Dashboard Rendered-Text Gate

## What was shipped

Three files changed:

- `runtime/dashboard/tests/sanitize.spec.ts` (new, ~80 LOC)
- `runtime/dashboard/playwright.config.ts` (small edit)
- `.github/workflows/sanitize.yml` (new job, ~30 lines)

## Route enumeration approach

`enumerateRoutes(appDir)` walks `runtime/dashboard/app/` recursively using `fs.readdirSync` and `fs.statSync`. Rules:

- Skips `api/` (API routes — no rendered HTML) and directories starting with `_` (Next App Router private folders).
- Route groups `(name)` are transparent — they do not add a URL segment.
- Dynamic segments `[param]` get a synthetic `test` placeholder so the route is visitable. No dynamic segments exist today but handling is included to prevent silent skipping if one is added later.
- Root `app/page.tsx` maps to `/`.
- Returns a deduplicated array.

Discovered routes on current tree: `/`, `/connectivity`, `/logs`, `/npu`.

## `page.content()` vs `textContent()` choice

`page.content()` returns the full rendered HTML including `<head>`. This catches literals in `<meta name="description">`, `<title>`, and `alt` attributes — surfaces that `page.textContent('body')` would miss. Per CONTEXT.md: "text content only — `page.content()` (rendered HTML)."

## `waitUntil: 'load'` + `waitForTimeout(1500)` over `networkidle`

`networkidle` is flaky against an unconfigured backend: dashboard pages make `useEffect`-driven fetches to `/api/*` routes that return errors, and the network never fully settles. Per RESEARCH Pitfall 5. A 1500ms fixed wait lets second-render content (including error states) be included in the scan. Error states are valid render targets per CONTEXT.md.

## Expected failure baseline (Plan 04 closes this)

The spec currently FAILS on the main tree. Two sources of leakage:

1. `runtime/dashboard/app/layout.tsx:11` — `description: "Control panel for Arlowe-1"` renders into `<meta name="description" content="Control panel for Arlowe-1">` on every route. Trips the `arlowe-1` banlist entry.
2. `runtime/dashboard/app/components/RetroActivityMonitor.tsx` — renders `ARLOWE-1 SYSTEM MONITOR` in visible text. Trips on every route that includes the sidebar/header.

All 4 routes (`/`, `/connectivity`, `/logs`, `/npu`) fail on the `arlowe-1` literal. Plan 04 cleans these runtime/ references.

## DASH-06 partial coverage

`page.content()` catches any href whose URL string contains a banlist literal (e.g., a link to `https://focal55.local/admin` trips the gate because `focal55` appears in the rendered HTML attribute value). Arbitrary workforce-internal hrefs that do not contain a banlist literal are not covered. Per CONTEXT.md deferred-ideas: enumerating all workforce-internal URL prefixes is out of scope for Phase 2. Defense-in-depth for that class relies on PR review until a future phase introduces an explicit href allow-list. Known, deliberate gap.

## Pointer to Plan 04

Plan 04 (`#57`) cleans the `runtime/` tree references that cause the current expected failures. Once merged, all 4 routes should pass the rendered-text gate.
