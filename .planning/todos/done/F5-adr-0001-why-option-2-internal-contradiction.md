# F5 — ADR-0001 "Why option-2" bullet list contradicts the decision

**Origin:** PR-Reviewer pass on PR #53 (2026-05-24) flagged this as a blocker; PR was merged anyway as it ships docs-only and the contradiction is self-contained to the rationale section. Capturing here so it doesn't get forgotten.

**Target phase:** Opportunistic — fix the next time `docs/architecture/0001-iol-router-extraction.md` is touched, OR roll into Phase 2 docs sanitization if a sanitization-gate plan happens to revise ADRs. Not worth its own PR.

## Problem

`docs/architecture/0001-iol-router-extraction.md` is internally inconsistent post-PR-#52:

- **Decision statement, route table, and observable-behaviour section** all correctly state that the router uses ax-llm's native `POST /api/chat` returning `{done, message}`.
- **"Why option-2" bullet list (lines 63–65)** still says, verbatim: *"The native surface speaks the OpenAI `/v1/chat/completions` shape that `voice_client.py` already expects."*

That second statement is the opposite of the actual decision. A future reader hits the ADR asserting both endpoints and both response shapes simultaneously.

The 640d20a commit on PR #53 attempted to reconcile the drift but only touched the decision/route/observable sections; it missed the "Why option-2" rationale.

## Fix shape

Rewrite the "Verified working live" bullet (and adjacent rationale) to reflect post-PR-#52 reality:

```markdown
- **Verified working live.** `curl -s -XPOST http://localhost:8000/api/chat \
  -d '{"messages":[{"role":"user","content":"ping"}]}'` on arlowe-1 returns
  `{done: true, message: {...}}`. `voice_client.py` was updated in PR #52 to
  speak ax-llm's native shape; the previous assumption that ax-llm would
  expose the OpenAI `/v1/chat/completions` surface returned malformed
  responses on the running build.
```

Acceptance:
- ADR no longer asserts contradictory things about which endpoint/shape is in use.
- "Refinement history" note (already added by 640d20a) is consistent with the bullet rationale.
- No code changes.

## Effort estimate

~10 LOC docs change, single file. ~10min.

## Cross-references

- PR #53 review comment (posted by pr-reviewer agent, 2026-05-24)
- PR #52 — the actual fix that introduced the drift (`fix(llm): use ax-llm /api/chat native API instead of OpenAI-compat`)
- File: `docs/architecture/0001-iol-router-extraction.md:61-73`

---

**Closed:** Resolved in Phase 2, Plan 04 (sanitization-gate cleanup sweep).
The "Why option-2" bullet now matches the resolved decision; ADR is internally consistent.
