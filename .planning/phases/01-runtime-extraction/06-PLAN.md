---
phase: 01-runtime-extraction
plan: 06
type: execute
wave: 2
depends_on: ["01"]
files_modified:
  - docs/architecture/dashboard-extraction-audit.md
  - .planning/phases/01-runtime-extraction/01-06-SUMMARY.md
autonomous: true

requirements:
  - "EXTRACT-06 (audit phase): arlowe-dashboard Next.js app extracts to runtime/dashboard/; tcp/3000 preserved — split into audit + delete + rewrite tasks per research"

must_haves:
  truths:
    - "docs/architecture/dashboard-extraction-audit.md categorizes every route and page in arlowe-dashboard as keep / rewrite / delete with rationale"
    - "Categorization aligns with research findings (workforce/openclaw/IOL routes marked delete; product-relevant routes marked keep or rewrite)"
    - "Plan 07 (delete pass) and plan 08 (rewrite pass) have a reviewable artifact to operate against"
  artifacts:
    - path: "docs/architecture/dashboard-extraction-audit.md"
      provides: "Per-route + per-page audit table with keep/rewrite/delete + rationale"
      min_lines: 100
      contains: "openclaw"
  key_links:
    - from: "docs/architecture/dashboard-extraction-audit.md"
      to: "Phase 1 plans 07 + 08"
      via: "Source of truth for what plans 07/08 do"
      pattern: "keep|rewrite|delete"
---

<objective>
Audit every route and page in `~/iol-monorepo/packages/arlowe-dashboard/` (mirrored locally via `dev-pull-from-pi.sh` or already in `/Users/joeybarrajr/projects/iol-monorepo/packages/arlowe-dashboard/` from the Mac) and produce `docs/architecture/dashboard-extraction-audit.md` — a per-file table categorizing each as **keep**, **rewrite**, or **delete** with rationale.

Purpose: Per research §EXTRACT-06 / R2, the dashboard is "50%+ founder/openclaw/IOL contaminated. It is not a copy job." Plans 07 (delete pass) and 08 (rewrite pass) need a reviewable, per-file decision artifact to operate against, otherwise the work degenerates into ad-hoc judgement calls.

Output: A reviewable markdown audit document. No code changes in this plan — pure analysis.

This plan can be done by a researcher or DEV agent reading the dashboard tree systematically.
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
  <name>Task 1: Enumerate every route and page in arlowe-dashboard</name>
  <files>docs/architecture/dashboard-extraction-audit.md</files>
  <action>
Source: `/Users/joeybarrajr/projects/iol-monorepo/packages/arlowe-dashboard/` (Mac copy is fine — research confirmed it has the dashboard locally; whisplay is the one missing locally).

Run:
```bash
cd /Users/joeybarrajr/projects/iol-monorepo/packages/arlowe-dashboard

# All API routes
find app/api -name 'route.ts' -o -name 'route.js' | sort > /tmp/dashboard-routes.txt

# All pages (page.tsx/jsx files)
find app -name 'page.tsx' -o -name 'page.jsx' | sort > /tmp/dashboard-pages.txt

# All components
find app -name 'components' -type d -prune -o -path '*/components/*' -print 2>/dev/null
find app/components 2>/dev/null
find components 2>/dev/null
```

Read each `route.ts` enough to identify:
- What path the route serves (`/api/<thing>`)
- What it reads (`/home/focal55/...`, `~/.openclaw/...`, `journalctl`, `axcl-smi`, etc.)
- What founder/workforce concepts it touches

Read each `page.tsx` enough to identify:
- What user-facing surface it shows
- Whether it depends on workforce concepts (sub-agents, IOL, costs, cron, etc.)
- Whether it links to founder GitHub repos

Capture findings into a working scratch space (use `Write` tool with a `/tmp/audit-scratch.md` if helpful).

Outcome of this task: enough raw data to produce the audit table in Task 2. Do not yet write the final audit file.
  </action>
  <verify>
```bash
test -s /tmp/dashboard-routes.txt && \
  test -s /tmp/dashboard-pages.txt && \
  echo "OK — found $(wc -l < /tmp/dashboard-routes.txt) routes and $(wc -l < /tmp/dashboard-pages.txt) pages"
```
  </verify>
  <done>Every route and page enumerated; agent has read enough source to make keep/rewrite/delete calls confidently in Task 2.</done>
</task>

<task type="auto">
  <name>Task 2: Author dashboard-extraction-audit.md with per-file categorization</name>
  <files>docs/architecture/dashboard-extraction-audit.md</files>
  <action>
Author the audit file. Use the research findings (§EXTRACT-06) as the seed and confirm/refine by reading source. Use this structure:

```markdown
# Dashboard Extraction Audit

**Authored:** 2026-05-01
**Phase:** 1, plan 06
**Source tree:** `/Users/joeybarrajr/projects/iol-monorepo/packages/arlowe-dashboard/`
**Targets plans 07 (delete pass) and 08 (rewrite pass).**

## Summary

| Category | Count | Notes |
|---|---|---|
| Keep (sanitize-only) | <N> | Generic UI / generic backend |
| Rewrite (backend swap) | <N> | Surface useful, reads founder-only paths today |
| Delete | <N> | Founder workforce / OpenClaw / IOL tooling |
| **Total** | <N> | |

Net LOC delta estimated: ~50% of current dashboard removed.

## Routes (`app/api/**/route.ts`)

| Path | Decision | Reads | Rationale |
|---|---|---|---|
| `/api/health` | KEEP | `/proc`, `axcl-smi` | Generic system stats |
| `/api/voice` | REWRITE | `systemctl --user is-active arlowe-voice` | Surface stays; convert `--user` → system in plan 08 |
| `/api/connectivity/*` | KEEP (audit-each) | NetworkManager | Product-relevant; verify no SSID leak |
| `/api/npu/*` | KEEP | NPU status / benchmark | Useful diagnostics |
| `/api/config` | REWRITE | `/home/focal55/.openclaw/workspace` | Surface stays (config get/set); rewrite to read `/etc/arlowe/config.yml` |
| `/api/logs` | REWRITE | `/home/focal55/whisplay/logs`, `~/.openclaw/logs`, journalctl filter incl `openclaw-gateway` | Keep journalctl; drop openclaw refs |
| `/api/middleware/*` | AUDIT | (founder API auth shape) | Determine in this plan, not deferred |
| `/api/playwright-reports/*` | DELETE | Test infra | Don't ship to product |
| **Workforce / OpenClaw / IOL routes — DELETE all of these:** | | | |
| `/api/costs` | DELETE | `~/.openclaw/agents/main/sessions` | Workforce cost tracking |
| `/api/cron`, `/api/cron/run` | DELETE | `~/.openclaw/cron/jobs.json` | OpenClaw cron |
| `/api/sub-agents/*` | DELETE | Sub-agent introspection | Workforce |
| `/api/tasks/active` | DELETE | `~/.openclaw/agents/main/sessions/sessions.json` | Workforce |
| `/api/usage` | DELETE | `~/.openclaw/agents/main/sessions` | Workforce |
| `/api/stats` | DELETE | `~/.openclaw/workspace/usage-stats.json` | Workforce |
| `/api/gateway/restart` | DELETE | restarts `openclaw-gateway` | Workforce |
| `/api/iol/*` | DELETE | IOL control plane | Founder infra |

(Add any routes the enumeration in Task 1 surfaced but research didn't list. Audit each new one against the same heuristic.)

## Pages (`app/**/page.tsx`)

| Path | Decision | Rationale |
|---|---|---|
| `app/page.tsx` (homepage) | KEEP | System health + voice toggle |
| `app/connectivity/page.tsx` | KEEP | Wi-Fi management |
| `app/config/page.tsx` | REWRITE backend (surface stays) | Reads founder config paths today |
| `app/npu/page.tsx` | KEEP | NPU diagnostics |
| `app/stats/page.tsx`, `app/logs/page.tsx` | REWRITE backend | Surface stays after backend rewrite |
| `app/iol/page.tsx` | DELETE | Has `https://github.com/focal55/iol-monorepo/...` link; founder infra |
| `app/sub-agents/page.tsx` | DELETE | Has founder GitHub link; workforce UI |
| `app/cron/page.tsx`, `app/costs/page.tsx`, `app/subagent-types/`, `app/pathway/`, `app/testing/` | DELETE | Workforce/dev UI |

(Same: add anything the enumeration found but research didn't list.)

## Components

Most components in `app/components/` are generic UI primitives (StatusCard, RetroActivityMonitor, etc.). KEEP these.

Specific components to AUDIT:
- `ProviderBadge.tsx` — research notes references `OpenClaw` at L17. Either rewrite (sanitize the literal) or delete if it's only used by deleted pages.
- (Anything else the enumeration shows.)

| Component | Decision | Rationale |
|---|---|---|
| `app/components/StatusCard.tsx` | KEEP | Generic |
| `app/components/RetroActivityMonitor.tsx` | KEEP | Generic |
| `app/components/ProviderBadge.tsx` | DELETE-or-REWRITE | Has `OpenClaw` literal; check usage |
| ... | | |

## Top-level files

| File | Decision | Rationale |
|---|---|---|
| `package.json` | KEEP | Dependencies; review for any founder-private packages |
| `next.config.js` | KEEP | Standard |
| `tsconfig.json` | KEEP | Standard |
| `.env.example` | KEEP (sanitize) | Verify no founder defaults |
| `.env.local` | DELETE | (Should already be gitignored; the dashboard's `.env.local` is what `tts_sync.py` was reading — see plan 04 R4 fix) |

## Founder GitHub URL audit

Research called out two:
- `app/sub-agents/page.tsx:155` — `https://github.com/focal55/iol-monorepo/...` (page is DELETE; URL goes with it)
- `app/iol/page.tsx:412` — same (page is DELETE; URL goes with it)

After plan 07's deletes, `grep -rn 'focal55\|github.com/focal55' .` against the dashboard tree should return ZERO. Plan 07's verify step enforces this.

## Open audit questions

For any file the auditor genuinely cannot decide on (e.g., `/api/middleware/*`), record the question here and the recommended default. The plan-07 / plan-08 executor uses the recommended default unless the user overrides.

## References

- Research: `.planning/phases/01-runtime-extraction/01-RESEARCH.md` §EXTRACT-06, §R2
- Roadmap requirement: EXTRACT-06
```

The output should be ~150-300 lines depending on how many files the dashboard has. Aim for completeness over brevity — this is a reviewable artifact, not a summary.
  </action>
  <verify>
```bash
test -f docs/architecture/dashboard-extraction-audit.md && \
  test "$(wc -l < docs/architecture/dashboard-extraction-audit.md)" -ge 100 && \
  grep -qi 'keep' docs/architecture/dashboard-extraction-audit.md && \
  grep -qi 'rewrite' docs/architecture/dashboard-extraction-audit.md && \
  grep -qi 'delete' docs/architecture/dashboard-extraction-audit.md && \
  grep -qi 'openclaw' docs/architecture/dashboard-extraction-audit.md && \
  grep -qi 'iol' docs/architecture/dashboard-extraction-audit.md && \
  echo OK
```
  </verify>
  <done>Audit file exists; every route + every page categorized with rationale; covers all routes/pages found in Task 1 enumeration; references research findings.</done>
</task>

</tasks>

<verification>
Phase-level check for this plan: the audit must be reviewable and actionable.

```bash
# Audit covers all enumerated routes
total_routes=$(wc -l < /tmp/dashboard-routes.txt)
mentioned_routes=$(grep -c '/api/' docs/architecture/dashboard-extraction-audit.md)
echo "Routes enumerated: $total_routes ; mentioned in audit: $mentioned_routes"

# Audit covers all enumerated pages
total_pages=$(wc -l < /tmp/dashboard-pages.txt)
mentioned_pages=$(grep -cE 'app/[a-z]+/page\.tsx|^\| `app' docs/architecture/dashboard-extraction-audit.md || true)
echo "Pages enumerated: $total_pages ; mentioned in audit: $mentioned_pages"
```

PR-size: this plan adds one large doc file (~150-300 lines) and nothing else. Well under the 400-line cap.
</verification>

<success_criteria>
- `docs/architecture/dashboard-extraction-audit.md` exists, ≥100 lines
- Every route enumerated in Task 1 appears in the audit table with a category
- Every page enumerated in Task 1 appears in the audit table with a category
- Categories align with research findings (workforce/IOL/openclaw → DELETE; generic system → KEEP; surface-stays-backend-changes → REWRITE)
- Open audit questions documented (or recommendations recorded if none)
- One PR, ≤300 net lines (single new doc file)
</success_criteria>

<output>
After completion, create `.planning/phases/01-runtime-extraction/01-06-SUMMARY.md` documenting:
- Counts: keep / rewrite / delete
- Estimated LOC delta from delete pass (plan 07)
- Estimated LOC delta from rewrite pass (plan 08)
- Any open audit questions that need user input before plans 07/08 proceed
</output>
