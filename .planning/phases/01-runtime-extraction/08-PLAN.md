---
phase: 01-runtime-extraction
plan: 08
type: execute
wave: 4
depends_on: ["07"]
files_modified:
  - runtime/dashboard/app/api/config/route.ts
  - runtime/dashboard/app/api/logs/route.ts
  - .planning/phases/01-runtime-extraction/01-08-SUMMARY.md
autonomous: true

requirements:
  - "EXTRACT-06 (rewrite phase, part 1): rewrite REWRITE-flagged routes /api/config and /api/logs to read from product paths"

must_haves:
  truths:
    - "/api/config reads from /etc/arlowe/config.yml (with sensible fallback) instead of ~/.openclaw/workspace"
    - "/api/logs reads from /var/lib/arlowe/logs/ + journalctl filtered to product services (no openclaw refs)"
    - "Standalone dashboard still builds (`pnpm build` succeeds) after these two route rewrites"
  artifacts:
    - path: "runtime/dashboard/app/api/config/route.ts"
      provides: "Config GET/SET reading from /etc/arlowe/config.yml"
    - path: "runtime/dashboard/app/api/logs/route.ts"
      provides: "Logs route reading from /var/lib/arlowe/logs/ + filtered journalctl"
  key_links:
    - from: "runtime/dashboard/app/api/config/route.ts"
      to: "/etc/arlowe/config.yml"
      via: "fs.readFile"
      pattern: "/etc/arlowe/config\\.yml"
    - from: "runtime/dashboard/app/api/logs/route.ts"
      to: "/var/lib/arlowe/logs/"
      via: "fs.readdir / fs.readFile"
      pattern: "/var/lib/arlowe/logs"
---

<objective>
Resolve the `// TODO(plan-08):` markers plan 07 left in `/api/config` and `/api/logs`. Specifically: rewrite both REWRITE-flagged routes to read from product paths (`/etc/arlowe/config.yml`, `/var/lib/arlowe/logs/`) instead of founder paths (`~/.openclaw/workspace`, `~/whisplay/logs`).

Purpose: Land the first half of the EXTRACT-06 rewrite pass. The split between this plan and plan 08b is a deliberate atomic-PR-cap measure — combining config-rewrite + logs-rewrite + voice-rewrite + .env.example + README + final-verification into one plan would exceed the 600-line atomic-PR cap. Each rewrite touches ~50-100 LOC plus support; two narrow plans is cleaner than one fat one.

Plan 08b finishes the rewrite pass (voice route, .env.example, README, final dashboard verification).

Output: `/api/config` and `/api/logs` rewritten; dashboard still builds.
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
@.planning/phases/01-runtime-extraction/01-07-SUMMARY.md
@docs/architecture/dashboard-extraction-audit.md
</context>

<tasks>

<task type="auto">
  <name>Task 1: Rewrite /api/config to read /etc/arlowe/config.yml</name>
  <files>runtime/dashboard/app/api/config/route.ts</files>
  <action>
The current implementation reads `/home/focal55/.openclaw/workspace` (research §EXTRACT-06). Rewrite to read `/etc/arlowe/config.yml` with these semantics:

**GET /api/config**:
1. Read `/etc/arlowe/config.yml` (overlay, present after pairing). Parse with `yaml`.
2. If file is absent, return 200 with `{paired: false, config: null, message: "Device is not paired."}`. This is the Phase 1 / pairing-pending state.
3. If parse fails, return 500 with the error.
4. On success, return 200 with `{paired: true, config: <parsed>}`.

**POST /api/config**:
For Phase 1, this can be a no-op stub OR a pass-through that writes back to `/etc/arlowe/config.yml` atomically (temp file + rename, per CONFIG-05). Phase 4 wires the schema validation. For now:
- Implement atomic write (temp file in `/etc/arlowe/.config.yml.tmp`, then `rename`)
- Do NOT validate the schema yet; just write what was sent
- Return 200 `{ok: true, written: <path>}`
- Add a comment: `// TODO(phase-4): validate against config/schema.yml before writing.`

Use `js-yaml` (add to `package.json` deps if not already there: `pnpm add js-yaml @types/js-yaml`).

Read the existing route to preserve any auth middleware / wrapper; replace only the file-system reads/writes.
  </action>
  <verify>
```bash
test -f runtime/dashboard/app/api/config/route.ts && \
  grep -q '/etc/arlowe/config.yml' runtime/dashboard/app/api/config/route.ts && \
  ! grep -n '\.openclaw\|focal55' runtime/dashboard/app/api/config/route.ts && \
  cd runtime/dashboard && pnpm build && echo OK
```
  </verify>
  <done>/api/config reads/writes /etc/arlowe/config.yml; founder paths gone; build passes.</done>
</task>

<task type="auto">
  <name>Task 2: Rewrite /api/logs to read from /var/lib/arlowe/logs/ and product-service journalctl</name>
  <files>runtime/dashboard/app/api/logs/route.ts</files>
  <action>
The current implementation references `/home/focal55/whisplay/logs`, `~/.openclaw/logs`, `~/.openclaw/cron/runs`, plus a journalctl filter that includes `openclaw-gateway` (research §EXTRACT-06).

Rewrite:
1. **File-based logs**: Replace `/home/focal55/whisplay/logs` with `/var/lib/arlowe/logs/` directory walk. Use `fs.readdir` + `fs.stat` to enumerate. Drop the `~/.openclaw/*` reads entirely.
2. **journalctl filter**: Replace whatever the current invocation is with:
   ```ts
   const services = [
     "arlowe-voice",
     "arlowe-face",
     "arlowe-dashboard",
     "qwen-tokenizer",
     "qwen-api",
     "qwen-openai",
     "whisper-stt",
   ];
   const args = ["-u", services.join(" -u "), "--no-pager", "--lines=200"];
   // ...
   ```
   (Adjust syntax for the current invocation pattern; the goal is "filter to product services, drop openclaw-gateway".)
3. **For Phase 1 dev**: services run as `--user` units, so `journalctl --user -u <service>` is the correct form. Add a code branch: prefer `--user` if `process.env.NODE_ENV === 'development'` or a config flag; otherwise system. Or, simpler: read the form from a config knob and default to system. Pick the simpler approach and document.

Comment block at top:
```ts
// /api/logs — reads /var/lib/arlowe/logs/ for file appenders and journalctl
// for the product service set. Founder paths (~/.openclaw, ~/whisplay/logs)
// removed in plan 08 (Phase 1 runtime extraction).
//
// Service set: arlowe-voice, arlowe-face, arlowe-dashboard,
// qwen-{tokenizer,api,openai}, whisper-stt. See ROADMAP Phase 11 for the
// canonical service ordering that BOOT-03 codifies.
```
  </action>
  <verify>
```bash
test -f runtime/dashboard/app/api/logs/route.ts && \
  grep -q '/var/lib/arlowe/logs' runtime/dashboard/app/api/logs/route.ts && \
  ! grep -n '\.openclaw\|focal55\|whisplay/logs\|openclaw-gateway' runtime/dashboard/app/api/logs/route.ts && \
  grep -q 'arlowe-voice\|arlowe-face\|qwen-' runtime/dashboard/app/api/logs/route.ts && \
  cd runtime/dashboard && pnpm build && echo OK
```
  </verify>
  <done>/api/logs reads /var/lib/arlowe/logs/ and journalctl for product services only. No openclaw refs. Builds.</done>
</task>

</tasks>

<verification>
Phase-level checks for this plan:

```bash
# Both rewrites landed
grep -q '/etc/arlowe/config.yml' runtime/dashboard/app/api/config/route.ts
grep -q '/var/lib/arlowe/logs' runtime/dashboard/app/api/logs/route.ts

# No founder literals in the two routes this plan owns
! grep -n 'focal55\|/home/focal55\|joe@focal55\|casa_ybarra\|iol-monorepo\|\.openclaw\|openclaw-gateway' runtime/dashboard/app/api/config/route.ts runtime/dashboard/app/api/logs/route.ts

# Build still works
cd runtime/dashboard && pnpm build
```

PR-size: 2 route rewrites (~50-100 LOC of edits each). Comfortable under 400 net.
</verification>

<success_criteria>
- /api/config rewritten to read /etc/arlowe/config.yml
- /api/logs rewritten to read /var/lib/arlowe/logs/ + product-service journalctl
- No founder literals in the two routes this plan owns
- `pnpm build` passes
- Plan 08b finishes the rewrite pass (voice route, .env.example, README, final verify)
</success_criteria>

<output>
After completion, create `.planning/phases/01-runtime-extraction/01-08-SUMMARY.md` documenting:
- Two routes rewritten and what they read now
- TODO(plan-08) markers resolved in those routes
- Build status: passing
- Open work in plan 08b: /api/voice, .env.example, README, final dashboard-wide verification
</output>
