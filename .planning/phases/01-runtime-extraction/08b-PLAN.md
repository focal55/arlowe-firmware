---
phase: 01-runtime-extraction
plan: 08b
type: execute
wave: 5
depends_on: ["08"]
files_modified:
  - runtime/dashboard/app/api/voice/route.ts
  - runtime/dashboard/.env.example
  - runtime/dashboard/README.md
  - .planning/phases/01-runtime-extraction/01-08b-SUMMARY.md
autonomous: true

requirements:
  - "EXTRACT-06 (rewrite phase, part 2): /api/voice systemctl knob, .env.example, dashboard README, final dashboard-wide founder-literal verification"

must_haves:
  truths:
    - "/api/voice's systemctl call is config-driven (ARLOWE_SYSTEMCTL_MODE) so Phase 1 dev (--user) and Phase 11 prod (system) only flip a flag"
    - "All `// TODO(plan-08):` markers from plan 07 are resolved or explicitly deferred (with phase target)"
    - "Standalone dashboard builds AND `pnpm dev` serves the homepage with no founder paths read at runtime"
    - "runtime/dashboard/README.md documents the runtime contract (port 3000, /etc/arlowe/config.yml, /var/lib/arlowe/logs/)"
    - "Zero founder literals dashboard-wide (excluding node_modules/.next/)"
  artifacts:
    - path: "runtime/dashboard/app/api/voice/route.ts"
      provides: "Voice toggle (systemctl arlowe-voice) with mode flag"
    - path: "runtime/dashboard/.env.example"
      provides: "Documented env knobs (no founder values)"
    - path: "runtime/dashboard/README.md"
      provides: "Runtime contract documentation"
      min_lines: 40
  key_links:
    - from: "runtime/dashboard/app/api/voice/route.ts"
      to: "systemctl --user arlowe-voice OR systemctl arlowe-voice (per ARLOWE_SYSTEMCTL_MODE)"
      via: "child_process.execFile with mode-aware args"
      pattern: "ARLOWE_SYSTEMCTL_MODE|SYSTEMCTL_MODE"
---

<objective>
Finish the EXTRACT-06 rewrite pass that plan 08 started: rewrite `/api/voice`'s systemctl call into a config-flag form, author `.env.example` and `README.md`, and run the final dashboard-wide founder-literal verification + build check.

Purpose: Plan 08 handled `/api/config` and `/api/logs` (the two heaviest rewrites). This plan handles the lighter `/api/voice` rewrite plus the docs and the final verification. Splitting on this boundary keeps each plan single-PR-sized.

After this plan, EXTRACT-06 is complete: dashboard surface delete + rewrite both done, runtime contract documented, zero founder literals dashboard-wide, build passes, dev-serves.

Output: A complete dashboard ready to ship with the runtime.
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
@.planning/phases/01-runtime-extraction/01-08-SUMMARY.md
@docs/architecture/dashboard-extraction-audit.md
</context>

<tasks>

<task type="auto">
  <name>Task 1: Rewrite /api/voice — add SYSTEMCTL_MODE knob</name>
  <files>runtime/dashboard/app/api/voice/route.ts</files>
  <action>
Per audit, `/api/voice` is REWRITE — convert `--user` to system. But research §R7 said: "keep `--user` for Phase 1 smoke test. Convert to system when image build lands (Phase 11)."

For Phase 1, the correct call is `systemctl --user is-active arlowe-voice` and `systemctl --user start/stop arlowe-voice`. Keep that form.

Add a config-driven branch so Phase 11 only needs to flip the flag:
```ts
const SYSTEMCTL_MODE = process.env.ARLOWE_SYSTEMCTL_MODE || "user"; // Phase 1 default
const systemctl = SYSTEMCTL_MODE === "system"
  ? ["systemctl", "is-active", "arlowe-voice"]
  : ["systemctl", "--user", "is-active", "arlowe-voice"];
// (apply consistently to start/stop/status)
```

Add comment:
```ts
// SYSTEMCTL_MODE: in Phase 1, units are --user (run as focal55 on dev unit).
// Phase 3 introduces the dedicated arlowe system user; Phase 11 image build
// installs system-level units. Flipping ARLOWE_SYSTEMCTL_MODE=system at that
// point is sufficient. See research R7 for tech-debt rationale.
```

Verify nothing else in the file references `focal55` or `~/iol-monorepo`. Strip if found.

Spot-check the other KEEP-flagged routes that the audit didn't pull into REWRITE (`/api/health`, `/api/connectivity/*`, `/api/npu/*`):
```bash
grep -rn 'focal55\|/home/focal55\|\.openclaw\|iol-monorepo' runtime/dashboard/app/api/health runtime/dashboard/app/api/connectivity runtime/dashboard/app/api/npu 2>/dev/null
```
If anything is found, the audit was wrong — fix it here and document in the SUMMARY.
  </action>
  <verify>
```bash
# /api/voice has the SYSTEMCTL_MODE knob
grep -q 'ARLOWE_SYSTEMCTL_MODE\|SYSTEMCTL_MODE' runtime/dashboard/app/api/voice/route.ts && \
# No founder literals across all KEEP+REWRITE routes
  ! grep -rn 'focal55\|/home/focal55\|\.openclaw\|iol-monorepo' runtime/dashboard/app/api/ && \
  cd runtime/dashboard && pnpm build && \
  echo OK
```
  </verify>
  <done>/api/voice uses config-knob systemctl mode. No founder paths anywhere in app/api/. Builds.</done>
</task>

<task type="auto">
  <name>Task 2: Author runtime/dashboard/.env.example and runtime/dashboard/README.md</name>
  <files>
    runtime/dashboard/.env.example
    runtime/dashboard/README.md
  </files>
  <action>
**`runtime/dashboard/.env.example`**: Document any env knobs the dashboard supports. Likely includes:
```
# Dashboard runtime env (no defaults committed; values come from /etc/arlowe/config.yml at runtime)

# Where the dashboard reads/writes the config overlay
ARLOWE_CONFIG_PATH=/etc/arlowe/config.yml

# Logs directory (file appenders)
ARLOWE_LOGS_DIR=/var/lib/arlowe/logs

# systemctl mode: 'user' for Phase 1 dev, 'system' for Phase 11+ image
ARLOWE_SYSTEMCTL_MODE=user

# (DO NOT add ELEVENLABS_API_KEY or any founder secret here — those come from /etc/arlowe/config.yml)
```

Verify by `diff`-ing against any prior `.env.example` from the source tree — make sure no founder values came along.

**`runtime/dashboard/README.md`**: Cover:
- Module purpose: Local-network dashboard at port 3000; provides health, connectivity, config, logs, voice toggle, NPU diagnostics.
- Routes index (table): keep + rewrite from the audit. Mark deleted ones with strikethrough or just omit.
- Reads:
  - `/etc/arlowe/config.yml` for config overlay
  - `/var/lib/arlowe/logs/` for file logs
  - `journalctl` for product-service logs (service list documented inline)
  - `axcl-smi` for NPU status
  - `systemctl` (user or system mode based on `ARLOWE_SYSTEMCTL_MODE`)
- Writes:
  - `/etc/arlowe/config.yml` (atomic temp+rename) on POST /api/config
- Authentication: documented as "Phase 8 wires owner-pairing credentials". For Phase 1 the dashboard is open on localhost.
- How to run on arlowe-1:
  ```bash
  cd /path/to/runtime/dashboard
  pnpm install
  ARLOWE_SYSTEMCTL_MODE=user pnpm dev
  ```
- Reference research §EXTRACT-06, §R2.

40-100 lines.
  </action>
  <verify>
```bash
test -f runtime/dashboard/.env.example && \
  ! grep -n 'focal55\|joe@focal55\|iol-monorepo\|ELEVENLABS_API_KEY=.*[a-zA-Z0-9]' runtime/dashboard/.env.example && \
  test -f runtime/dashboard/README.md && \
  test "$(wc -l < runtime/dashboard/README.md)" -ge 40 && \
  grep -q '3000' runtime/dashboard/README.md && \
  grep -q '/etc/arlowe/config.yml' runtime/dashboard/README.md && \
  echo OK
```
  </verify>
  <done>.env.example documents knobs without leaking secrets; README documents the runtime contract; both committed.</done>
</task>

<task type="auto">
  <name>Task 3: Final verification — build, dev-serve, no founder literals anywhere</name>
  <files>(no files modified — verification only)</files>
  <action>
Final pass:

```bash
cd runtime/dashboard
pnpm install --frozen-lockfile=false
pnpm build  # MUST succeed
```

Then start the dev server briefly to confirm it serves:
```bash
( cd runtime/dashboard && timeout 10 pnpm dev ) &
DEV_PID=$!
sleep 5
curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/ || true
kill $DEV_PID 2>/dev/null || true
```

Expected: build completes; homepage returns 200 (or 401 if auth wraps it — either is acceptable, just not 500).

Then the founder-literals gate, dashboard-wide:
```bash
! grep -rn --exclude-dir=node_modules --exclude-dir=.next \
  'focal55\|/home/focal55\|joe@focal55\|casa_ybarra\|iol-monorepo\|\.openclaw\|openclaw-gateway' \
  runtime/dashboard/
```

If anything is found, fix it and re-run. Zero hits is the bar.

Clean up `.next/` before commit:
```bash
rm -rf runtime/dashboard/.next
```
  </action>
  <verify>
```bash
cd runtime/dashboard && \
  pnpm build && \
  ! grep -rn --exclude-dir=node_modules --exclude-dir=.next \
    'focal55\|/home/focal55\|joe@focal55\|casa_ybarra\|iol-monorepo\|\.openclaw\|openclaw-gateway' . && \
  echo OK
```
  </verify>
  <done>Build passes, dev-serves, zero founder literals dashboard-wide. EXTRACT-06 done.</done>
</task>

</tasks>

<verification>
Phase-level checks for this plan:

```bash
# Build still works after the final rewrite
cd runtime/dashboard && pnpm build

# Zero founder literals dashboard-wide (excluding node_modules/.next/)
! grep -rn --exclude-dir=node_modules --exclude-dir=.next \
  'focal55\|/home/focal55\|joe@focal55\|casa_ybarra\|iol-monorepo\|\.openclaw\|openclaw-gateway' \
  runtime/dashboard/

# Voice route has the mode knob
grep -q 'ARLOWE_SYSTEMCTL_MODE\|SYSTEMCTL_MODE' runtime/dashboard/app/api/voice/route.ts

# README documents the contract
test -f runtime/dashboard/README.md && wc -l < runtime/dashboard/README.md

# .env.example exists and is clean of secrets
test -f runtime/dashboard/.env.example && ! grep -n 'ELEVENLABS_API_KEY=.*[a-zA-Z0-9]' runtime/dashboard/.env.example
```

PR-size: 1 route rewrite (~30 LOC of edits) + `.env.example` + README ≈ 100 net new lines. Well under 400.
</verification>

<success_criteria>
- /api/voice has SYSTEMCTL_MODE knob
- runtime/dashboard/.env.example documents env knobs (no founder values)
- runtime/dashboard/README.md documents the runtime contract (≥40 lines)
- All TODO(plan-08) markers resolved (counting plans 08 + 08b together)
- `pnpm build` passes
- Zero founder literals dashboard-wide
- EXTRACT-06 complete (combined with plans 06, 07, 08)
</success_criteria>

<output>
After completion, create `.planning/phases/01-runtime-extraction/01-08b-SUMMARY.md` documenting:
- /api/voice rewrite (mode-flag pattern)
- .env.example + README contents summary
- Final founder-literal sweep result: zero
- Build + dev-serve verification result
- Dashboard surface count: keep / rewrite / deleted (final tally combining plans 06-08b)
- EXTRACT-06: COMPLETE
</output>
