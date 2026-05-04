---
phase: 01-runtime-extraction
plan: 06
type: summary
status: complete
issue: 6
---

# Phase 1 Plan 06 — Summary

## What

Audited every API route, page, top-level component, and top-level config file in `arlowe-dashboard` (the live source at `/Users/joeybarrajr/projects/iol-monorepo/packages/arlowe-dashboard/`, verified 2026-05-02). Output: `docs/architecture/dashboard-extraction-audit.md` — a per-file decision document feeding plans 07, 08, and 08b.

## Counts

| Category | Routes | Pages | Components (top + scoped) | Top-level / tests |
|---|---:|---:|---:|---:|
| KEEP    |  9 |  3 | 6 + 8 = 14 |  9 + 2 = 11 |
| REWRITE |  3 |  4 |  3 + 0 = 3 |  4 + 1 = 5 |
| DELETE  | 15 |  6 | 5 + 3 = 8 |  0 + 2 = 2 |
| Total   | 27 | 13 | 14 + 11 = 25 | 13 + 5 = 18 |

(Pages REWRITE = 4 if Q2 keeps stats; recommendation is to downgrade stats to DELETE → 3 REWRITE, 7 DELETE.)

## LOC delta estimates

- **Plan 07 (delete pass):** approximately **−4,200 LOC** (~43% of the dashboard's 9,621 `app/` LOC). Breakdown in audit § "Delete pass LOC budget". Likely needs a 2–3 sub-PR split to stay under 400-net per PR.
- **Plan 08 (backend rewrite):** approximately **+250 / −470 LOC net**. Touches `/api/config`, `/api/logs`, `/api/voice`, homepage `app/page.tsx`, `app/components/{Navigation,ProviderBadge,Header}.tsx`, and `app/layout.tsx` cosmetic literal.
- **Plan 08b (`.env.local` decoupling):** approximately **±30 LOC** plus regenerated `.env.example`. Fixes research §R4 (`tts_sync.py` reaching into the dashboard's `.env.local` for ElevenLabs key).

## Open questions for the user (block plan 07/08 only if user wants different defaults)

1. **Q1 — Config page:** recommend deleting `app/config/page.tsx` in plan 07 and keeping `/api/config` as a thin read-only endpoint. Defer the real config UI to Phase 11. Audit's REWRITE classification for the page assumes the user might disagree.
2. **Q2 — Stats page:** recommend downgrading to DELETE. Workforce-shaped. Phase 11 can reintroduce a voice-activity view if needed.
3. **Q3 — `/api/voice` `--user` flag:** keep `--user` in plan 08; system-level migration is Phase 11 image-build scope.
4. **Q4 — `/api/connectivity/connect` auth:** keep TODO-disabled in plan 08; bearer-token UX is Phase 7 scope.
5. **Q5 — `/api/middleware/auth.ts`:** keep as-is post-delete pass — `/api/connectivity/saved` still consumes it.

Default behaviour if the user doesn't override: take the recommendations above.

## Key findings worth flagging

- **Hardcoded gateway bearer token in source.** `app/api/gateway/restart/route.ts:5` contains `GATEWAY_TOKEN = '3693d83e56...'`. The route is DELETE so the token disappears with plan 07, but the team should rotate this token in the live OpenClaw gateway config — once a secret hits a public-bound repo's source tree it's burned.
- **Two confirmed founder GitHub URLs** at `app/sub-agents/page.tsx:155` and `app/iol/page.tsx:412`, both inside DELETE pages. Plan 07's grep verify covers these.
- **Cross-package secret read.** Research §R4 is confirmed: the dashboard's `.env.local` is currently the source of truth for the ElevenLabs key consumed by `runtime/tts/tts_sync.py`. Plan 08b must break this coupling.
- **`ProviderBadge.tsx` line 17** has `openclaw:` as an explicit map entry. One-line edit in plan 08.
- **`app/layout.tsx`** has a soft `Arlowe-1` literal in the description metadata. One-line cosmetic fix in plan 08.

## Artifact

- `docs/architecture/dashboard-extraction-audit.md` (282 lines, satisfies plan's `min_lines: 100` and `contains: "openclaw"` requirements).

## References

- Plan: `.planning/phases/01-runtime-extraction/06-PLAN.md`
- Research: `.planning/phases/01-runtime-extraction/01-RESEARCH.md`
- Issue: focal55/arlowe-firmware#6
