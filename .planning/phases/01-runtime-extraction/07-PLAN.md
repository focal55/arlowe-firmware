---
phase: 01-runtime-extraction
plan: 07
type: execute
wave: 3
depends_on: ["01", "06"]
files_modified:
  - runtime/dashboard/**
  - .planning/phases/01-runtime-extraction/01-07-SUMMARY.md
autonomous: true

requirements:
  - "EXTRACT-06 (delete phase): copy dashboard to runtime/dashboard/, remove all routes/pages flagged DELETE in the audit"

must_haves:
  truths:
    - "runtime/dashboard/ exists and contains the Next.js app"
    - "All routes flagged DELETE in dashboard-extraction-audit.md are removed from runtime/dashboard/"
    - "All pages flagged DELETE in dashboard-extraction-audit.md are removed"
    - "Zero references to `focal55/iol-monorepo`, `~/.openclaw`, `openclaw-gateway`, `~/.openclaw/agents`, founder GitHub URLs remain"
    - "Standalone build still produces a working dashboard (`pnpm install && pnpm build` succeeds)"
  artifacts:
    - path: "runtime/dashboard/package.json"
      provides: "Dashboard package manifest"
    - path: "runtime/dashboard/app/page.tsx"
      provides: "Homepage (KEEP)"
    - path: "runtime/dashboard/app/api/health/route.ts"
      provides: "Health route (KEEP)"
    - path: "runtime/dashboard/app/api/voice/route.ts"
      provides: "Voice toggle (KEEP, rewritten in plan 08)"
  key_links:
    - from: "runtime/dashboard/"
      to: "no founder paths"
      via: "grep gate"
      pattern: "(?<!matches).*"
---

<objective>
Copy `arlowe-dashboard` from the Mac copy to `runtime/dashboard/` and execute the **delete** decisions from `docs/architecture/dashboard-extraction-audit.md` (plan 06). This plan does NOT do the rewrite work — that's plan 08. This plan only removes founder/workforce/IOL routes and pages.

Purpose: Land the bulk of EXTRACT-06's LOC reduction. The audit predicts ~50% of dashboard LOC removed.

Output: `runtime/dashboard/` containing only KEEP and REWRITE routes/pages (REWRITE backends still reference founder paths — that's plan 08's job). The dashboard must still build standalone (`pnpm install && pnpm build`) — surface-only damage is fine but compile-breaking deletions need cleanup in this same plan.
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
@.planning/phases/01-runtime-extraction/01-06-SUMMARY.md
@docs/architecture/dashboard-extraction-audit.md
</context>

<tasks>

<task type="auto">
  <name>Task 1: Copy dashboard tree to runtime/dashboard/</name>
  <files>runtime/dashboard/**</files>
  <action>
Source: `/Users/joeybarrajr/projects/iol-monorepo/packages/arlowe-dashboard/` (Mac copy).
Destination: `runtime/dashboard/`.

Use `rsync` to copy. Exclude:
- `node_modules/` (will reinstall)
- `.next/` (build artifact)
- `.env.local` (founder secrets — research R4 already noted this gets read by tts_sync; we kill the read in plan 04 and don't ship the file)
- `.env.local.*` 
- Any `*.log` files
- `playwright-report/`, `test-results/` if present

Command:
```bash
rsync -av \
  --exclude='node_modules/' \
  --exclude='.next/' \
  --exclude='.env.local' \
  --exclude='.env.local.*' \
  --exclude='*.log' \
  --exclude='playwright-report/' \
  --exclude='test-results/' \
  /Users/joeybarrajr/projects/iol-monorepo/packages/arlowe-dashboard/ \
  runtime/dashboard/
```

Replace plan 01's `runtime/dashboard/.gitkeep` after copy completes (delete the .gitkeep since the directory is no longer empty).

Verify the copy by checking package.json exists and is valid JSON.
  </action>
  <verify>
```bash
test -f runtime/dashboard/package.json && \
  python3 -c "import json; json.load(open('runtime/dashboard/package.json'))" && \
  test -d runtime/dashboard/app && \
  ! test -d runtime/dashboard/node_modules && \
  ! test -d runtime/dashboard/.next && \
  ! test -f runtime/dashboard/.env.local && \
  echo OK
```
  </verify>
  <done>Dashboard tree copied; build artifacts and secrets excluded; package.json valid.</done>
</task>

<task type="auto">
  <name>Task 2: Execute delete pass per audit</name>
  <files>runtime/dashboard/**</files>
  <action>
Read `docs/architecture/dashboard-extraction-audit.md` and delete every file/directory marked DELETE. Per research §EXTRACT-06, the canonical delete list is:

**API routes to DELETE** (whole file or whole route directory):
- `runtime/dashboard/app/api/costs/`
- `runtime/dashboard/app/api/cron/` (both `route.ts` and `run/route.ts`)
- `runtime/dashboard/app/api/sub-agents/` (all 3 routes)
- `runtime/dashboard/app/api/tasks/active/`
- `runtime/dashboard/app/api/usage/`
- `runtime/dashboard/app/api/stats/`
- `runtime/dashboard/app/api/gateway/restart/` (and the `gateway/` parent if empty after)
- `runtime/dashboard/app/api/iol/` (entire subtree)
- `runtime/dashboard/app/api/playwright-reports/`

**Pages to DELETE**:
- `runtime/dashboard/app/iol/`
- `runtime/dashboard/app/sub-agents/`
- `runtime/dashboard/app/cron/`
- `runtime/dashboard/app/costs/`
- `runtime/dashboard/app/subagent-types/`
- `runtime/dashboard/app/pathway/`
- `runtime/dashboard/app/testing/`

Plus anything else the audit flagged DELETE that wasn't in research.

Use `git rm -r` for each (or `rm -rf` then `git add` — whatever the agent prefers; but the operation MUST end in a clean git state).

After deletes, scan for orphaned imports / dead links:
```bash
# Find imports referencing deleted paths
grep -rn "from.*sub-agents\|from.*\bcron\b\|from.*\biol\b\|from.*\bcosts\b\|from.*\bstats\b\|from.*\bsubagent-types\b" runtime/dashboard/app runtime/dashboard/components 2>/dev/null
```

If the homepage or any KEEP page imports from a deleted path (most likely a navigation menu component), fix the import — comment out the menu entry or remove it. Do NOT add new functionality; this is a delete pass.

Likely fixups needed (from research):
- Any nav component (e.g., `app/components/Nav.tsx`) listing routes — remove menu entries pointing to deleted pages.
- Any `app/layout.tsx` referencing deleted pages — remove.
- Any `ProviderBadge.tsx` if the audit flagged it DELETE — remove and find/replace usages.
  </action>
  <verify>
```bash
# All DELETE items are gone
! test -d runtime/dashboard/app/api/costs && \
  ! test -d runtime/dashboard/app/api/cron && \
  ! test -d runtime/dashboard/app/api/sub-agents && \
  ! test -d runtime/dashboard/app/api/tasks/active && \
  ! test -d runtime/dashboard/app/api/usage && \
  ! test -d runtime/dashboard/app/api/stats && \
  ! test -d runtime/dashboard/app/api/gateway/restart && \
  ! test -d runtime/dashboard/app/api/iol && \
  ! test -d runtime/dashboard/app/iol && \
  ! test -d runtime/dashboard/app/sub-agents && \
  ! test -d runtime/dashboard/app/cron && \
  ! test -d runtime/dashboard/app/costs && \
  echo OK
```
  </verify>
  <done>Every DELETE item from the audit is removed. Orphan imports fixed. Tree compiles (verified next task).</done>
</task>

<task type="auto">
  <name>Task 3: Strip founder GitHub URLs and openclaw-gateway journalctl filters</name>
  <files>runtime/dashboard/**</files>
  <action>
Even after the delete pass, residual founder literals may remain in KEEP / REWRITE files (research called out two founder GitHub URLs in deleted pages, but there could be others — and `openclaw-gateway` appears in the journalctl filter inside the KEEP `/api/logs` route).

Run:
```bash
grep -rn 'github.com/focal55\|focal55/iol-monorepo' runtime/dashboard/  || echo "no GitHub leaks"
grep -rn 'openclaw-gateway\|openclaw' runtime/dashboard/ || echo "no openclaw refs"
```

For each hit:
- **`openclaw-gateway` in journalctl filter** (likely in `app/api/logs/route.ts`): remove that filter entry; keep the rest of the journalctl invocation. Add a comment: `// TODO(plan-08): expand journalctl filters to product services (qwen-*, arlowe-*, whisper-stt).`
- **`focal55` in any URL or string**: replace with the product equivalent or delete the line if cosmetic.
- **Any leftover `~/.openclaw` reference**: this is plan-08 territory (rewrite pass) — leave with a `// TODO(plan-08)` marker and document in this plan's SUMMARY.

For literals that the audit said to REWRITE (e.g., `/home/focal55/.openclaw/workspace` in `/api/config/route.ts`): leave them — plan 08 owns those. This task only kills the literals in pages/routes that should be CLEAN after delete pass.
  </action>
  <verify>
```bash
# No founder GitHub leaks
! grep -rn 'github.com/focal55\|focal55/iol-monorepo' runtime/dashboard/ && \
# openclaw-gateway journalctl filter is gone
  ! grep -rn 'openclaw-gateway' runtime/dashboard/ && \
  echo OK
# Note: ~/.openclaw paths in REWRITE files are EXPECTED here — plan 08 fixes them.
```
  </verify>
  <done>Founder GitHub URLs gone. openclaw-gateway journalctl filter gone. ~/.openclaw paths in REWRITE-marked files explicitly LEFT for plan 08 with TODO markers.</done>
</task>

<task type="auto">
  <name>Task 4: Verify standalone build still works</name>
  <files>(no files modified — verification only)</files>
  <action>
Confirm the dashboard still installs and builds:

```bash
cd runtime/dashboard
pnpm install --frozen-lockfile=false
pnpm build
```

If build fails:
- Read the error
- If it's an orphan import from a deleted path, fix the import (revisit Task 2's "fixups needed" guidance)
- If it's a missing env var, add to `.env.example` with a placeholder; do NOT add to `.env.local`
- If it's a missing dep that was workforce-tooling-only, that's a sign Task 2 missed an import cleanup

The build MUST pass before this plan completes. A non-building dashboard means the delete pass left dangling imports.

After successful build:
```bash
rm -rf runtime/dashboard/.next  # don't commit build artifact
```

Run lint if the dashboard has a lint config:
```bash
pnpm lint || echo "lint warnings noted; not blocking"
```
Lint warnings are acceptable; lint errors should be fixed.
  </action>
  <verify>
```bash
cd runtime/dashboard && pnpm install --frozen-lockfile=false >/dev/null 2>&1 && pnpm build && echo OK
```
  </verify>
  <done>`pnpm build` succeeds. `.next/` artifact cleaned up. Dashboard is structurally complete; backends still founder-coupled (that's plan 08).</done>
</task>

</tasks>

<verification>
Phase-level checks for this plan:

```bash
# Founder literals (in KEEP files) — these MUST be zero after this plan
! grep -rn 'github.com/focal55\|openclaw-gateway' runtime/dashboard/

# Workforce paths/concepts removed (in deleted files)
! test -d runtime/dashboard/app/api/costs
! test -d runtime/dashboard/app/sub-agents

# Dashboard still builds
cd runtime/dashboard && pnpm build
```

Note: `~/.openclaw` and `/home/focal55` paths may still be present in REWRITE-flagged files — that's plan 08's responsibility. The smell test for plan 07 is: every DELETE item is gone, every KEEP file is clean, every REWRITE file is annotated with `// TODO(plan-08):` and the build still works.

PR-size: This is mostly deletes. Net diff is negative (lines removed > lines added). Should be well under 600 net new lines (likely net negative); reviewer reads the audit doc + walks through deletes.
</verification>

<success_criteria>
- runtime/dashboard/ exists with the Next.js app
- All DELETE items from the audit are removed
- Zero `github.com/focal55` URLs, zero `openclaw-gateway` journalctl filters
- `pnpm install && pnpm build` succeeds
- REWRITE-flagged files retain their founder paths but are marked `// TODO(plan-08)`
</success_criteria>

<output>
After completion, create `.planning/phases/01-runtime-extraction/01-07-SUMMARY.md` documenting:
- Counts: directories deleted, files deleted, LOC delta
- Files annotated with TODO(plan-08) markers (the rewrite-pass worklist)
- Any audit decisions deviated from (with rationale)
- Build status: passing
</output>
