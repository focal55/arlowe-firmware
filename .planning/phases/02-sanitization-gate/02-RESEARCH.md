# Phase 2: Sanitization Gate - Research

**Researched:** 2026-05-25
**Domain:** CI guardrails (ripgrep + GitHub Actions + Playwright + Next.js App Router)
**Confidence:** HIGH

## Summary

Three mechanical gates implementing what `02-CONTEXT.md` already locked down. Tooling choices are essentially forced by what's already in the repo:

- **Grep gate**: ripgrep 14.1.1 (already installed in standard GitHub Actions `ubuntu-latest` runners as of 2024). `git ls-files` to scope to tracked files, `-iFn --column --no-heading` for case-insensitive fixed-string output in a parseable form. A bash loop converts each hit to a `::error file=PATH,line=N,col=C::message` line for inline PR annotations. Allow-list filtering happens in pure bash against the captured hits — no need to pull in a node glob library when the gate is run from bash. Use `git check-ignore` semantics via a small awk/shell script or vendor a tiny glob matcher; the simplest path is `git ls-files -- ':!:GLOB1' ':!:GLOB2' ...` populated from `.sanitize-allowlist`, which gives gitignore-compatible globs for free.
- **Unit-name block**: same runner script, different inputs. `git ls-files '*.service' '*.timer' '*.socket' '*.target' '*.mount' '*.path'` enumerates tracked unit files, basename-match against the three banned prefixes (`openclaw-*`, `trace-*`, `workforce-metrics-snapshot.*`). Deliberate-failure test is a bash test against a `mktemp -d` containing a fake `openclaw-test.service`, asserting non-zero exit.
- **Dashboard rendered-text gate**: new Playwright spec at `runtime/dashboard/tests/sanitize.spec.ts`. Enumerate routes by `fs.readdirSync` walking `app/` for `page.tsx` (NOT `route.ts` — those are API endpoints, no rendered HTML to scan). For each route, `await page.goto(...)`, `await page.waitForLoadState('networkidle')`, then `expect(await page.content()).not.toMatch(/.../i)`. The existing `playwright.config.ts` already runs `pnpm start -p 3000` via `webServer` and has `reuseExistingServer: !process.env.CI` set correctly. **Pitfall**: the existing config uses `pnpm start` (production server), which requires `pnpm build` first; CI must run build before the test or the webServer command must become `pnpm build && pnpm start -p 3000`.

**Primary recommendation:** Single bash script `scripts/sanitize/check.sh` runs both grep gate + unit-name block, called from a new `.github/workflows/sanitize.yml`. Dashboard gate stays in the existing Playwright suite. Required-check trap (path-filtered workflows blocking PRs forever as "pending"): solve by **not using `paths:` in `on:`** — the sanitize workflow always runs on every PR, no exceptions. The scan itself is fast enough (~1s on 182 tracked files) that path-filtering is premature optimization that breaks branch protection.

## Standard Stack

### Core
| Tool | Version | Purpose | Why Standard |
|------|---------|---------|--------------|
| ripgrep (`rg`) | 14.1.1 (system) | Banlist scan | Already installed on `ubuntu-latest` runners; `--vimgrep` and `--json` outputs are explicitly machine-parseable. Faster than `grep -r` and respects `.gitignore` by default. |
| `git ls-files` | bundled | Tracked-file enumeration | Authoritative scope: matches exactly the SC1 "tracked files" definition. Avoids the `.dev-stash/` problem mechanically — gitignored = not listed. |
| bash 5 | runner-provided | Glue, output formatting | Single language for the whole runner script keeps it auditable in <100 LOC. |
| Playwright | 1.58.2 (already in `runtime/dashboard/devDependencies`) | Dashboard rendered-HTML scan | Already wired up; `playwright.config.ts` already provisions webServer + Chromium + Firefox. |
| Node `fs.readdirSync` | bundled with Node 20 | Route enumeration in spec | Walking `app/` for `page.tsx` is ~15 LOC; no library needed. |

### Supporting
| Tool | Purpose | When to Use |
|------|---------|-------------|
| `git diff --name-only` | (Optional, deferred) Limit scan to changed files in PR | NOT for v1. Full-tree scan is correct because a literal can be reintroduced by a rebase/merge that touches a file the PR author didn't write. Mentioned only because someone will suggest it. |
| `actions/setup-node@v4`, `pnpm/action-setup@v4` | Already in `ci.yml` | Reuse, don't reinstall, in the new workflow. |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| ripgrep | `grep -rIni` (POSIX) | grep is universal but ~5x slower and lacks `.gitignore` awareness. ripgrep is on every modern runner image; portability is not a real concern in CI. |
| ripgrep | Python script with `re.compile` | Python gives precise control over allow-list glob matching and JSON output. ~50 extra LOC vs bash; only worth it if we ever need per-literal precision (which 02-CONTEXT.md explicitly defers). |
| ripgrep | `git grep -inE` | `git grep` is what `dashboard-extraction-audit.md` already uses elsewhere. Equivalent functionality. Slightly less flexible on `--column` / `--vimgrep` outputs. Either works; pick one and stay consistent. |
| `fs.readdirSync` for route enumeration | Read `.next/server/app-paths-manifest.json` | The manifest is post-build, exists only after `pnpm build`. Since Playwright already requires a built dashboard (webServer is `pnpm start`), reading the manifest is technically possible. But filesystem walk of `app/` is simpler and works even if a future spec author runs `pnpm test:e2e` against `pnpm dev`. Stick with `fs.readdirSync`. |
| Playwright snapshot `toMatchSnapshot` | Direct `expect(content).not.toMatch(BANLIST_REGEX)` | Snapshot diffing for a "must not contain X" check is the wrong tool — snapshots assert on *positive* content shape. Use direct regex assertion. |

**Installation:**
ripgrep is pre-installed on `ubuntu-latest`. Verify with `rg --version` in a workflow step before relying on it. No `npm install` or `apt install` step required.

## Architecture Patterns

### Recommended Project Structure
```
scripts/
└── sanitize/
    ├── check.sh                # Main runner (grep gate + unit-name block)
    ├── banlist.txt             # 6 literals, one per line, no comments
    ├── unit-prefixes.txt       # 3 banned unit prefixes
    └── test-check.sh           # Self-test: creates temp tree with planted hit, asserts non-zero exit
.sanitize-allowlist             # Path globs allowed to contain banned literals (gitignore-style)
.github/workflows/
└── sanitize.yml                # Calls scripts/sanitize/check.sh + invokes Playwright sanitize spec
runtime/dashboard/tests/
└── sanitize.spec.ts            # Rendered-HTML banlist scan
```

Rationale for splitting `banlist.txt` / `unit-prefixes.txt` out of the script: a future "add a 7th literal" PR touches a single data file, not the runner. Also makes the deliberate-failure test trivial — feed the test runner a different banlist.

### Pattern 1: Grep gate runner
**What:** Scan tracked files for any banlist literal; convert hits to GitHub annotations; exit non-zero on any hit.

**When to use:** Top of `.github/workflows/sanitize.yml`, every PR.

**Skeleton:**
```bash
#!/usr/bin/env bash
# scripts/sanitize/check.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

BANLIST="$SCRIPT_DIR/banlist.txt"
ALLOWLIST=".sanitize-allowlist"

# Build a pathspec from .sanitize-allowlist (gitignore-style globs).
# git ls-files honors :(exclude) pathspecs with gitignore semantics.
PATHSPECS=()
if [[ -f "$ALLOWLIST" ]]; then
  while IFS= read -r line; do
    # Strip comments (#...) and blank lines.
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"   # ltrim
    line="${line%"${line##*[![:space:]]}"}"   # rtrim
    [[ -z "$line" ]] && continue
    PATHSPECS+=(":(exclude,glob)$line")
  done < "$ALLOWLIST"
fi

# Enumerate tracked, non-allow-listed files.
mapfile -t FILES < <(git ls-files -- "${PATHSPECS[@]+${PATHSPECS[@]}}")

# Build a single alternation pattern from the banlist (one literal per line).
# -iF makes it case-insensitive fixed-string; we still want one-pattern-per-rg-call
# only if we need per-literal column data. Easier: -f BANLIST.
HITS=$(rg -iFn --column --no-heading -f "$BANLIST" -- "${FILES[@]}" || true)

if [[ -z "$HITS" ]]; then
  echo "sanitize: clean (${#FILES[@]} tracked files scanned)"
  exit 0
fi

# Emit GitHub annotations + human-readable summary.
EXIT=0
while IFS= read -r hit; do
  # hit format from rg -n --column: path:line:col:matched-text
  IFS=: read -r path line col rest <<< "$hit"
  msg="banned identity literal; if this is a legit historical reference, add the path to .sanitize-allowlist"
  printf '::error file=%s,line=%s,col=%s::%s\n' "$path" "$line" "$col" "$msg"
  printf '%s:%s:%s: %s\n' "$path" "$line" "$col" "$rest" >&2
  EXIT=1
done <<< "$HITS"
exit "$EXIT"
```

**Sources:**
- ripgrep flags (`-i`, `-F`, `-n`, `--column`, `--no-heading`, `-f`): verified via `rg --help` on system, ripgrep 14.1.1.
- `git ls-files -- ':(exclude,glob)foo/**'` pathspec syntax: git ≥2.13.
- GitHub annotation format: confirmed against GitHub Actions workflow-commands docs (see Sources).

### Pattern 2: Unit-name block
**What:** Enumerate tracked systemd unit files; basename-match against banned prefixes.

**Skeleton (call from same `check.sh` or a sibling script):**
```bash
# Tracked unit files.
mapfile -t UNITS < <(git ls-files \
  -- '*.service' '*.timer' '*.socket' '*.target' '*.mount' '*.path')

EXIT=0
while IFS= read -r prefix; do
  prefix="${prefix%%#*}"; prefix="${prefix// /}"
  [[ -z "$prefix" ]] && continue
  for unit in "${UNITS[@]}"; do
    base="$(basename "$unit")"
    # shell glob match — relies on extglob NOT being needed for *. prefix patterns
    if [[ "$base" == $prefix ]]; then
      printf '::error file=%s,line=1::banned systemd unit name (matches %s)\n' "$unit" "$prefix"
      EXIT=1
    fi
  done
done < "$SCRIPT_DIR/unit-prefixes.txt"
exit "$EXIT"
```

The three prefixes (`openclaw-*`, `trace-*`, `workforce-metrics-snapshot.*`) are literally bash glob patterns; `[[ basename == $prefix ]]` does the right thing when `$prefix` is unquoted on the RHS.

**Deliberate-failure self-test** (runs alongside the gate in CI):
```bash
# scripts/sanitize/test-check.sh
set -euo pipefail
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT
git -C "$TMP" init -q
touch "$TMP/openclaw-test.service"
git -C "$TMP" add . && git -C "$TMP" -c user.email=t@t -c user.name=t commit -qm test

# Run the unit-block portion against TMP — should exit non-zero.
if (cd "$TMP" && bash "$REPO_ROOT/scripts/sanitize/check.sh" --units-only); then
  echo "FAIL: gate did not catch planted openclaw-test.service" >&2
  exit 1
fi
echo "PASS: gate correctly blocked planted unit"
```

Add a matching planted-literal test for the grep gate. Both tests run in CI as a separate workflow job (`name: sanitize-self-test`) so a regression in the gate itself is caught.

### Pattern 3: Dashboard rendered-text gate
**What:** Boot the dashboard, visit every page, assert rendered HTML contains none of the 6 literals.

**Skeleton (`runtime/dashboard/tests/sanitize.spec.ts`):**
```typescript
import { test, expect } from '@playwright/test';
import { readdirSync, statSync } from 'fs';
import path from 'path';

// Walk app/ for page.tsx files, convert each to a URL path.
// Skip route groups (parens), private folders (_underscore), and api/ (no rendered HTML).
function enumerateRoutes(appDir: string): string[] {
  const routes: string[] = [];
  function walk(dir: string, urlSegments: string[]) {
    for (const entry of readdirSync(dir)) {
      const full = path.join(dir, entry);
      if (!statSync(full).isDirectory()) continue;
      if (entry === 'api' || entry.startsWith('_')) continue;
      // Route groups: (name) folders do not contribute to URL.
      const nextSegments = entry.startsWith('(') && entry.endsWith(')')
        ? urlSegments
        : [...urlSegments, entry];
      // If this directory has page.tsx, record the route.
      try {
        statSync(path.join(full, 'page.tsx'));
        routes.push('/' + nextSegments.join('/'));
      } catch { /* no page.tsx, just keep walking */ }
      walk(full, nextSegments);
    }
  }
  // Root page.tsx → '/'
  try { statSync(path.join(appDir, 'page.tsx')); routes.push('/'); } catch {}
  walk(appDir, []);
  return [...new Set(routes)];
}

const APP_DIR = path.join(__dirname, '..', 'app');
const ROUTES = enumerateRoutes(APP_DIR);
const BANLIST = [
  'focal55', 'arlowe-1', 'casa_ybarra_chelsea',
  '/home/focal55', 'joe@focal55', 'iol-monorepo',
];

test.describe('sanitization: no founder literals in rendered HTML', () => {
  for (const route of ROUTES) {
    test(`route ${route} contains no banned literal`, async ({ page }) => {
      await page.goto(route, { waitUntil: 'networkidle' });
      const html = await page.content();
      for (const literal of BANLIST) {
        expect(
          html.toLowerCase().includes(literal.toLowerCase()),
          `route ${route} rendered HTML contains "${literal}"`,
        ).toBe(false);
      }
    });
  }
});
```

**Why `page.content()` not `page.textContent('body')`:** the CONTEXT decision is "text content only — `page.content()` (rendered HTML)." This catches literals in `<title>`, `<meta>`, alt attributes, and visible text. Does NOT catch `href` attributes mid-attribute (confirmed in CONTEXT deferred list), but covers the layout.tsx `description: "Control panel for Arlowe-1"` which renders into `<meta name="description">`.

**Why `networkidle`:** the dashboard pages do `useEffect`-driven `fetch('/api/health')` etc. on mount and render placeholder content first. `networkidle` waits for the API requests to settle so the second-render text is included in the scan. The trade-off is ~500ms per route. For 4 routes that's 2s; acceptable.

**Sources:**
- Next.js App Router file conventions (page.tsx, route.ts, route groups `(name)`, dynamic segments `[name]`, private folders `_name`): confirmed against Next.js docs.
- `page.content()` returns full HTML including doctype: Playwright docs.

### Pattern 4: GitHub Actions workflow
**File:** `.github/workflows/sanitize.yml`

**Skeleton:**
```yaml
name: Sanitize

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]

# NO `paths:` filter — required checks + path filtering = "pending forever" trap.
# The whole scan takes ~2s; path-gating is premature optimization.

concurrency:
  group: sanitize-${{ github.ref }}
  cancel-in-progress: true

jobs:
  banlist-and-units:
    name: Banlist + unit-name block
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: rg --version  # sanity-check that rg is on the runner
      - run: bash scripts/sanitize/check.sh

  self-test:
    name: Gate self-test (deliberate-failure cases)
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: bash scripts/sanitize/test-check.sh

  dashboard-rendered-text:
    name: Dashboard rendered-text gate
    runs-on: ubuntu-latest
    defaults: { run: { working-directory: runtime/dashboard } }
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4
        with: { version: 9 }
      - uses: actions/setup-node@v4
        with: { node-version: '20', cache: 'pnpm' }
      - run: pnpm install --frozen-lockfile
      - run: pnpm exec playwright install --with-deps chromium
      - run: pnpm build      # required because playwright.config webServer uses `pnpm start`
      - run: pnpm exec playwright test sanitize.spec.ts
```

### Anti-Patterns to Avoid

- **Path-filtered required check.** Do NOT add `on: pull_request: paths: ['runtime/**', 'scripts/**']`. A PR that only edits `docs/journey/2026-05-25.md` will not trigger the workflow; the required check stays pending forever; the PR cannot merge. This is a well-documented GitHub bug (see Sources). The fix is to not use `paths:` at all on a required check. If skipping is genuinely desired in the future, use a "bucket" job pattern with `dorny/paths-filter` and an aggregator job that's `if: always()` and inspects sub-job results.
- **Skipping `pnpm build` before Playwright.** The existing `playwright.config.ts` has `webServer: { command: 'pnpm start -p 3000' }` — `next start` requires a `.next/` build artifact. Add `pnpm build` to the workflow OR change the webServer command to `pnpm build && pnpm start -p 3000` (CONTEXT mentions `pnpm dev` as an option; that works too but renders different output and includes dev-only HMR scripts. Production build is closer to ship behavior).
- **Allow-listing whole `.planning/**` for the grep gate without thinking.** `.planning/phases/02-sanitization-gate/02-RESEARCH.md` (this file) MUST be allow-listed because it contains every banned literal as documentation. So must `02-CONTEXT.md`, `.planning/REQUIREMENTS.md`, and most of `.planning/phases/01-runtime-extraction/`. But `.planning/STATE.md` and future phase plans should NOT be blanket-allow-listed — they could legitimately need scanning. Recommended starting `.sanitize-allowlist`:
  ```
  # Planning artifacts that document banned literals as part of their purpose.
  .planning/REQUIREMENTS.md
  .planning/ROADMAP.md
  .planning/PROJECT.md
  .planning/phases/01-runtime-extraction/**
  .planning/phases/02-sanitization-gate/**
  # Architecture decision records that capture historical state.
  docs/architecture/0001-iol-router-extraction.md
  docs/architecture/0002-arlowe-scheduled-summary-stripped.md
  docs/architecture/dashboard-extraction-audit.md
  docs/architecture-overview.md
  # Operations doc that records phase-1 smoke-test history.
  docs/operations/phase-1-smoke-test.md
  # Workforce wiring — references @focal55 the GitHub user, not the founder identity in firmware sense.
  .github/CODEOWNERS
  .github/ISSUE_TEMPLATE/config.yml
  AGENTS.md.template
  README.md
  # Dev pull script — references arlowe-1 because that's the dev unit it pulls from.
  scripts/dev-pull-from-pi.sh
  # Third-party distribution paperwork.
  third_party/axcl/DISTRIBUTION-RIGHTS.md
  third_party/axcl/INSTALL.md
  third_party/whisplay-driver/PROVENANCE.md
  # Allowlist of itself — required so the script doesn't grep its own banlist via the script file.
  .sanitize-allowlist
  scripts/sanitize/banlist.txt
  scripts/sanitize/unit-prefixes.txt
  ```
  See "Open Questions" for which of these the planner should challenge.
- **Trying to use `rg --json` for annotations.** The JSON output is one message per *event* (begin/match/end), not one per match line, and includes `submatches` arrays. Bash parsing of it is painful. `-n --column --no-heading` plain output is `path:line:col:text` which is trivial to split on `:`. Stick with that.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Tracked-file enumeration | `find . -type f` with manual `.gitignore` parsing | `git ls-files` | Honors `.gitignore`, `.git/info/exclude`, submodule boundaries, and pathspec excludes for free. Matches the SC1 "tracked files" definition exactly. |
| Glob-pattern path matching for allow-list | minimatch/micromatch/picomatch JS library | `git ls-files -- ':(exclude,glob)PATTERN'` pathspec | gitignore-style globs come for free via git's own pathspec engine. No node_modules, no extra dependency for a bash script. |
| Route discovery in dashboard test | next/router internal APIs, parsing `app-paths-manifest.json` | 15-line `fs.readdirSync` walk | App Router routes ARE the filesystem. No abstraction layer needed; the manifest only exists post-build and adds coupling. |
| Banlist regex compilation | Hand-crafted character-class regex | ripgrep `-f banlist.txt -F` | `-F` says "treat each pattern as a literal", `-f` reads patterns from a file. Adding a 7th literal is a one-line file edit. |
| GitHub Actions annotation formatting | Custom JSON output parsed by a third-party action | `printf '::error file=...::message\n'` directly | The annotation format is a documented workflow-command stdin syntax; the runner picks it up automatically. No action plugin needed. |
| Deliberate-failure test harness | Pytest, bats, or another test framework | Plain bash with `mktemp -d`, `git init -q`, `set -e` | The test is "run the script against a planted tree and assert non-zero exit." Three lines of bash. A framework adds friction. |

**Key insight:** This phase is bash + ripgrep + git's own pathspec engine + a 50-line Playwright spec. The temptation to introduce a Python script or a node CLI tool is real and should be resisted — every new dependency is a new surface to sanitize.

## Common Pitfalls

### Pitfall 1: Required check + path filter = unmergeable PRs
**What goes wrong:** A workflow with `on: pull_request: paths: ['runtime/**']` doesn't trigger on a PR that only touches `docs/`. The required status check then shows as "Expected — Waiting for status to be reported" forever, blocking merge.
**Why it happens:** GitHub's required-check logic treats "workflow did not trigger" as "check never reported" — not as "check passed because it didn't need to run."
**How to avoid:** Don't use `paths:` filters on workflows that are marked required. Sanitize runs in ~2s on the current tree; gating it on path changes is not worth the complexity.
**Warning signs:** PRs sitting in "Some checks haven't completed" purgatory; check the workflow runs page — if the workflow shows zero runs for the head SHA, this is the trap.
**Source:** [GitHub community discussion #44490 — Allow required checks to pass/skip when using path filtering](https://github.com/orgs/community/discussions/44490)

### Pitfall 2: Allow-list glob semantics don't match user intuition
**What goes wrong:** Author adds `docs/architecture/*.md` to `.sanitize-allowlist`, expecting it to also cover `docs/architecture/subfolder/foo.md`. It doesn't — single `*` doesn't cross `/`.
**Why it happens:** This is `.gitignore` semantics, which is what `git ls-files :(exclude,glob)` uses. Most JS devs expect minimatch defaults where `*` may or may not cross `/` depending on options.
**How to avoid:** Use `**` for recursive matching in the allow-list. Document this in the allow-list file header comment. Test by running `git ls-files -- ':(exclude,glob)docs/architecture/**'` locally and confirming the expected paths drop out.
**Warning signs:** A file the author thought was allow-listed shows up as a gate hit; verify the actual glob expansion with `git ls-files`.

### Pitfall 3: Playwright `webServer` starts before build artifacts exist
**What goes wrong:** `pnpm start -p 3000` (current config) crashes immediately with "Could not find a production build" if `.next/` doesn't exist. Playwright's webServer waits for URL availability and times out at 120s.
**Why it happens:** `next start` requires `next build` artifacts; the existing config assumes someone (a human running locally) has built first. CI doesn't have that context.
**How to avoid:** Add an explicit `pnpm build` step in the workflow before `pnpm exec playwright test`. Alternative: change `webServer.command` to `pnpm build && pnpm start -p 3000` and bump `timeout` to 180000.
**Warning signs:** Playwright failures with "Error: timed out waiting 120000ms" or HTTP 500s from the dashboard.

### Pitfall 4: ripgrep matches its own arguments file
**What goes wrong:** `scripts/sanitize/banlist.txt` contains the 6 literals as data; when the script enumerates tracked files via `git ls-files`, this file is in the list; ripgrep scans it; finds all 6 literals; exits non-zero. The gate fails because of its own configuration.
**Why it happens:** The banlist file is, by design, a list of the banned literals.
**How to avoid:** Allow-list `scripts/sanitize/banlist.txt` and `scripts/sanitize/unit-prefixes.txt` in `.sanitize-allowlist`. The `.sanitize-allowlist` file itself does not contain banned literals so does not need self-allow-listing — but if a future version comments out a literal as "allowed only here", it would, so allow-list it too pre-emptively.
**Warning signs:** First CI run of the gate fails with hits inside `scripts/sanitize/`.

### Pitfall 5: Network-idle wait masks empty-state false negatives
**What goes wrong:** A page's `useEffect` fetches `/api/voice`, gets a 500 (because no backend), renders an error message "Failed to load voice status for arlowe-1". Page hits `networkidle` only after the error renders. Gate catches it. Good. BUT — if the API hangs (because the backend partially works and never responds), `networkidle` never fires, Playwright times out, test fails for the wrong reason and looks like a flake.
**Why it happens:** `networkidle` is fragile when backends are unhealthy.
**How to avoid:** Either (a) mock all `/api/*` routes in the spec with `page.route('**/api/**', r => r.fulfill({...}))` returning a deterministic error shape, OR (b) use `waitUntil: 'load'` (DOM ready, scripts run) which is less strict and lets the test scan whatever rendered, even if API requests are pending. CONTEXT picks "unconfigured backend, error states are valid render targets" — option (b) aligns with that. Recommend `waitUntil: 'load'` plus a short explicit `page.waitForTimeout(1500)` to let async useEffects settle. Yes, that's a sleep; for a 4-route test it's fine.
**Warning signs:** Sanitize test passes locally, fails intermittently in CI with timeout errors.

### Pitfall 6: Case-insensitive matches inside JSON / YAML keys
**What goes wrong:** A future PR adds `casa_ybarra_chelsea` to a JSON object as a key name. The gate catches it (good). But a future PR adds an OAuth scope literal like `iol-monorepo-readonly` which is a coincidental substring match. False positive.
**Why it happens:** Substring matching is what CONTEXT picked (no word-boundary anchoring) and the false-positive risk was explicitly accepted.
**How to avoid:** Allow-list the offending file with a comment. This is the documented v1 behavior, not a bug.
**Warning signs:** Author surprised by a hit on a file they didn't realize contained the substring. Failure-output message hints at the allow-list remedy.

## Code Examples

### Reading the banlist file once, scanning all tracked files
```bash
# Source: ripgrep --help (rg 14.1.1)
rg -iFn --column --no-heading -f scripts/sanitize/banlist.txt -- $(git ls-files)
```
- `-i` case-insensitive
- `-F` fixed strings (no regex interpretation)
- `-n` line numbers
- `--column` column of first match (1-based)
- `--no-heading` flat `path:line:col:text` per match (default-on when output isn't a terminal, but explicit is safer)
- `-f FILE` read patterns from FILE, one per line

### Emitting GitHub annotations from a shell loop
```bash
# Source: https://docs.github.com/en/actions/using-workflows/workflow-commands-for-github-actions
printf '::error file=%s,line=%s,col=%s,title=%s::%s\n' \
  "$path" "$line" "$col" "Banned literal" "$message"
```
The runner picks up `::error` lines on stdout (the `::` prefix and `::` separator are both required). Multi-line messages need `%0A` in place of `\n` inside the message body; for single-line messages this isn't a concern.

### Excluding via git pathspec (gitignore-style)
```bash
# Source: git pathspec docs, magic signature :(exclude,glob)
git ls-files -- \
  ':(exclude,glob).planning/phases/01-runtime-extraction/**' \
  ':(exclude,glob)docs/architecture/0001-iol-router-extraction.md'
```
Note the `glob` magic — without it, `**` would only literally match `**`. With it, `.gitignore` semantics apply.

### Walking app/ for routes
```typescript
// Source: Node fs docs + Next.js App Router file conventions
import { readdirSync, statSync } from 'fs';
import { join } from 'path';

function hasPage(dir: string): boolean {
  try { return statSync(join(dir, 'page.tsx')).isFile(); } catch { return false; }
}
// then walk subdirectories, skipping 'api/', leading '_', and treating
// '(group)/' as a transparent passthrough that does not add a URL segment.
```

## State of the Art

| Old Approach | Current Approach | Notes |
|--------------|------------------|-------|
| GNU grep -rIn | ripgrep `rg` | Faster, gitignore-aware, JSON+vimgrep outputs. Standard on modern CI runners. |
| Snapshot files for "must not contain X" tests | Direct assertion `expect(text).not.toMatch(/.../i)` | Snapshots are for "must look like Y" tests; banlist is "must not contain X" — negative assertion, no file artifact needed. |
| Custom Github Actions for inline annotations | Plain `::error file=...::msg` printf to stdout | Workflow commands are runner-built-in; no marketplace action required. |
| Pages Router `pages/foo.tsx` route convention | App Router `app/foo/page.tsx` | Already adopted in `runtime/dashboard/`. `page.tsx` is the public-page marker; `route.ts` is the API marker; route groups `(name)/` don't contribute URL segments. |

**Deprecated/outdated:**
- `--column` is shown in older ripgrep examples as if it implies `-n`; it does, but always pair with explicit `-n` for clarity. (rg 14 docs.)
- The `paths:` filter on a required workflow is sometimes mentioned in older blog posts as a monorepo optimization — actively harmful for required-check workflows on small/fast scans. Use only with the "bucket job" aggregator pattern.

## Open Questions

1. **Should `.github/CODEOWNERS` be allow-listed, or sanitized?**
   - What we know: it contains `* @focal55` because `@focal55` is the GitHub username of the founder, and CODEOWNERS routes workforce review automation. Removing it breaks the workforce protocol; sanitizing the username breaks GitHub's CODEOWNERS validation.
   - What's unclear: whether SC1 considers GitHub-username `@focal55` "founder identity in the firmware sense" or just "version control plumbing."
   - Recommendation: allow-list it. The risk SANIT exists to prevent is founder-identity strings *shipping in firmware/image*; CODEOWNERS never ships in any image. CONTEXT's deferred-ideas section already excludes "founder name/brand literals" so the author has already drawn this line.

2. **Should `AGENTS.md.template` and `README.md` be allow-listed?**
   - These reference `@focal55` and `github.com/focal55/agentic-workforce-template.git` for legitimate workforce-template purposes.
   - Recommendation: allow-list. Same reasoning as CODEOWNERS — workforce plumbing doesn't ship.

3. **Does the F5 ADR-0001 contradiction get fixed in Phase 2 or stay opportunistic?**
   - F5 todo (`/Users/joeybarrajr/projects/arlowe-firmware/.planning/todos/pending/F5-adr-0001-why-option-2-internal-contradiction.md`) explicitly says "Opportunistic — fix the next time docs/architecture/0001-... is touched, OR roll into Phase 2 docs sanitization."
   - The current Phase 2 SC4 ("the current runtime/ tree passes all sanitization checks") does NOT cover `docs/`. Allow-listing the ADR file means SC4 is met without touching the file.
   - Recommendation: do the ADR fix as a side-quest task in Phase 2's plan (10 LOC, ~10 min) only if (a) the file ends up *not* allow-listed, or (b) the plan author wants to clear the F5 todo. Otherwise defer it. Not blocking.

4. **Is the Phase 6 image-build hook future-proofed?**
   - The unit-name block scans `git ls-files` for `*.service` etc. Phase 6 will need it to scan the assembled image rootfs *before* pi-gen finalizes the `.img`. That's a different filesystem (mounted rootfs at e.g. `/mnt/img/etc/systemd/system/`), not git.
   - What's unclear: whether the same script can take a `--root DIR` argument and `find DIR -name '*.service'` instead of `git ls-files`, OR whether Phase 6 ships its own variant.
   - Recommendation: design `check.sh` with a `--scan-dir DIR` flag from day one. Default scans `git ls-files`; with `--scan-dir`, it `find`s tracked-extension files under DIR. Phase 6 then reuses the binary, not just the logic. Document this contract in the script's header.

5. **Does `pnpm exec playwright install --with-deps chromium` need every browser, or just chromium?**
   - The existing config defines both chromium and firefox projects. The sanitize spec only needs one browser — HTML output is browser-independent for a rendered-text scan.
   - Recommendation: in the sanitize CI job, pass `--project=chromium` to keep install time short. Other Playwright tests (connectivity, navigation) can still run multi-browser in a separate workflow.

## Sources

### Primary (HIGH confidence)
- ripgrep 14.1.1 `--help` (verified directly via `rg --help` on dev machine) — flag semantics for `-i`, `-F`, `-n`, `--column`, `--no-heading`, `-f`, `--vimgrep`, `--json`.
- Next.js App Router file conventions — [`/docs/app/getting-started/layouts-and-pages`](https://nextjs.org/docs/app/getting-started/layouts-and-pages) — verifies `page.tsx`/`route.ts`/dynamic segments/route groups.
- Playwright `page.content()` returns full HTML — [Playwright Page API](https://playwright.dev/docs/api/class-page#page-content).
- Playwright webServer `reuseExistingServer` semantics — [Playwright test-webserver docs](https://playwright.dev/docs/test-webserver).
- GitHub Actions annotation syntax — [Workflow commands docs](https://docs.github.com/en/actions/using-workflows/workflow-commands-for-github-actions).
- Existing repo state directly inspected:
  - `.github/workflows/ci.yml`, `pr-checks.yml`, `auto-label.yml`, `project-board-sync.yml`
  - `runtime/dashboard/playwright.config.ts`, `package.json`, `tests/*.spec.ts`
  - `runtime/dashboard/app/` route layout, `Navigation.tsx`, `layout.tsx`, `RetroActivityMonitor.tsx`
  - `.gitignore` (confirms `.dev-stash/` is gitignored)
  - `git grep -inE` direct output showing 16 runtime files with banned literals (the SC4 cleanup target)

### Secondary (MEDIUM confidence)
- GitHub required-check + path-filter trap — multiple community sources agree this is a real bug:
  - [community discussion #44490](https://github.com/orgs/community/discussions/44490)
  - [community discussion #26251](https://github.com/orgs/community/discussions/26251)
  - [community discussion #54877](https://github.com/orgs/community/discussions/54877)
- micromatch / minimatch / gitignore-glob comparison — [npm-compare micromatch vs minimatch](https://npm-compare.com/micromatch,minimatch). MEDIUM because the recommendation here is to avoid both in favor of git's native pathspec.

### Tertiary (LOW confidence)
- "Filesystem walk vs Next route manifest for test fixture" — pattern is common in community blog posts but not officially documented. Recommendation backed by reading the actual Next 16 docs that confirm file-system routing semantics. LOW because no single canonical source.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — every tool is already in the repo or pre-installed on `ubuntu-latest`; flags verified directly against `rg --help`.
- Architecture: HIGH — script skeletons compiled mentally against actual repo file layout; no novel patterns.
- Pitfalls: MEDIUM-HIGH — required-check trap is HIGH confidence (multiple GitHub community threads), Playwright `webServer` build-artifact trap is HIGH (read the config directly), networkidle flakiness is MEDIUM (general Playwright lore, not specific to this repo).
- Open questions: explicit; planner should resolve allow-list scope (Q1, Q2) before tasking the gate runner.

**Research date:** 2026-05-25
**Valid until:** 2026-06-25 (30 days; ripgrep/playwright/GitHub Actions are stable, allow-list contents depend on what other PRs land first).
