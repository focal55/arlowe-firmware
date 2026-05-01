---
phase: 01-runtime-extraction
plan: 08
type: execute
wave: 4
depends_on: ["07"]
files_modified:
  - runtime/dashboard/app/api/config/route.ts
  - runtime/dashboard/app/api/logs/route.ts
  - runtime/dashboard/app/api/voice/route.ts
  - runtime/dashboard/.env.example
  - runtime/dashboard/README.md
  - .planning/phases/01-runtime-extraction/01-08-SUMMARY.md
autonomous: true

requirements:
  - "EXTRACT-06 (rewrite phase): rewrite REWRITE-flagged routes to read from /etc/arlowe/config.yml and product paths instead of ~/.openclaw/ and ~/iol-monorepo/"

must_haves:
  truths:
    - "All `// TODO(plan-08):` markers from plan 07 are resolved or explicitly deferred (with phase target)"
    - "/api/config reads from /etc/arlowe/config.yml (with sensible fallback) instead of ~/.openclaw/workspace"
    - "/api/logs reads from /var/lib/arlowe/logs/ + journalctl filtered to product services (no openclaw refs)"
    - "/api/voice's systemctl call is correct for both --user (Phase 1 dev) and system (Phase 3+ prod) modes — pick one and document"
    - "Standalone dashboard builds AND `pnpm dev` serves the homepage with no founder paths read at runtime"
    - "runtime/dashboard/README.md documents the runtime contract (port 3000, /etc/arlowe/config.yml, /var/lib/arlowe/logs/)"
  artifacts:
    - path: "runtime/dashboard/app/api/config/route.ts"
      provides: "Config GET/SET reading from /etc/arlowe/config.yml"
    - path: "runtime/dashboard/app/api/logs/route.ts"
      provides: "Logs route reading from /var/lib/arlowe/logs/ + filtered journalctl"
    - path: "runtime/dashboard/app/api/voice/route.ts"
      provides: "Voice toggle (systemctl arlowe-voice)"
    - path: "runtime/dashboard/.env.example"
      provides: "Documented env knobs (no founder values)"
    - path: "runtime/dashboard/README.md"
      provides: "Runtime contract documentation"
      min_lines: 40
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
Resolve every `// TODO(plan-08):` marker plan 07 left behind. Specifically: rewrite the REWRITE-flagged routes (`/api/config`, `/api/logs`, plus `/api/voice` if needed) to read from product paths (`/etc/arlowe/config.yml`, `/var/lib/arlowe/logs/`) instead of founder paths (`~/.openclaw/workspace`, `~/whisplay/logs`). Author `runtime/dashboard/README.md` documenting the runtime contract.

Purpose: Land the second half of EXTRACT-06. Until this plan runs, the dashboard reads founder filesystem paths at runtime — the smoke test in plan 13 cannot trust the dashboard's surfaces.

Output: A dashboard whose routes read from product paths only. Builds cleanly. Documented.
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

<task type="auto">
  <name>Task 3: Verify /api/voice and other surface-stays routes are clean</name>
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
  <name>Task 4: Author runtime/dashboard/.env.example and runtime/dashboard/README.md</name>
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
  <name>Task 5: Final verification — build, dev-serve, no founder literals anywhere</name>
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
# Build still works after rewrites
cd runtime/dashboard && pnpm build

# Zero founder literals dashboard-wide (excluding node_modules/.next/)
! grep -rn --exclude-dir=node_modules --exclude-dir=.next \
  'focal55\|/home/focal55\|joe@focal55\|casa_ybarra\|iol-monorepo\|\.openclaw\|openclaw-gateway' \
  runtime/dashboard/

# Specific path rewrites landed
grep -q '/etc/arlowe/config.yml' runtime/dashboard/app/api/config/route.ts
grep -q '/var/lib/arlowe/logs' runtime/dashboard/app/api/logs/route.ts

# README documents the contract
test -f runtime/dashboard/README.md && wc -l < runtime/dashboard/README.md
```

PR-size: rewrites of 2-3 routes (each ~20-50 LOC of edits) + `.env.example` + README ≈ 200 net new lines. Comfortable under 400.
</verification>

<success_criteria>
- All TODO(plan-08) markers resolved
- /api/config, /api/logs rewritten to product paths
- /api/voice has SYSTEMCTL_MODE knob
- runtime/dashboard/.env.example documents env knobs (no founder values)
- runtime/dashboard/README.md documents the runtime contract (≥40 lines)
- `pnpm build` passes
- Zero founder literals dashboard-wide
- EXTRACT-06 complete
</success_criteria>

<output>
After completion, create `.planning/phases/01-runtime-extraction/01-08-SUMMARY.md` documenting:
- Routes rewritten and what they read now
- TODO(plan-08) markers resolved (with line counts)
- Build status: passing
- Dashboard surface count: keep / rewrite / deleted (final tally)
- EXTRACT-06: COMPLETE
</output>
