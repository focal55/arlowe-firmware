---
phase: 01-runtime-extraction
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - runtime/.gitkeep
  - runtime/voice/.gitkeep
  - runtime/face/.gitkeep
  - runtime/stt/.gitkeep
  - runtime/tts/.gitkeep
  - runtime/llm/.gitkeep
  - runtime/dashboard/.gitkeep
  - runtime/wake-word/.gitkeep
  - runtime/cli/.gitkeep
  - third_party/.gitkeep
  - third_party/ax-llm/.gitkeep
  - third_party/axcl/.gitkeep
  - scripts/dev-pull-from-pi.sh
  - .gitignore
  - .planning/phases/01-runtime-extraction/01-01-SUMMARY.md
autonomous: true

requirements:
  - "Sets up the directory layout that EXTRACT-01..EXTRACT-12 land into"

must_haves:
  truths:
    - "runtime/{voice,face,stt,tts,llm,dashboard,wake-word,cli}/ directories exist"
    - "third_party/{ax-llm,axcl}/ directories exist"
    - "scripts/dev-pull-from-pi.sh exists, is executable, and rsyncs source files from arlowe-1.local to a local stash"
    - ".gitignore blocks founder voice fingerprint files (*.pkl, wake-word/positive/, wake-word/negative/)"
  artifacts:
    - path: "runtime/voice/.gitkeep"
      provides: "Stream A landing zone"
    - path: "runtime/face/.gitkeep"
      provides: "Stream A landing zone"
    - path: "runtime/stt/.gitkeep"
      provides: "Stream A landing zone"
    - path: "runtime/tts/.gitkeep"
      provides: "Stream A landing zone"
    - path: "runtime/llm/.gitkeep"
      provides: "Stream A landing zone"
    - path: "runtime/dashboard/.gitkeep"
      provides: "Stream B landing zone"
    - path: "runtime/wake-word/.gitkeep"
      provides: "Stream D landing zone"
    - path: "runtime/cli/.gitkeep"
      provides: "Stream D landing zone"
    - path: "third_party/ax-llm/.gitkeep"
      provides: "Stream C submodule mount point (replaced in plan 09)"
    - path: "third_party/axcl/.gitkeep"
      provides: "Stream C deb vendoring mount point (replaced in plan 09)"
    - path: "scripts/dev-pull-from-pi.sh"
      provides: "rsync helper to mirror source files from arlowe-1 to local workspace"
      min_lines: 30
    - path: ".gitignore"
      provides: "Blocks founder voice biometric data"
      contains: "*.pkl"
  key_links:
    - from: "scripts/dev-pull-from-pi.sh"
      to: "arlowe-1.local"
      via: "ssh+rsync over SSH alias"
      pattern: "rsync.*arlowe-1"
---

<objective>
Scaffold the `runtime/` and `third_party/` directory structure that all subsequent Phase 1 plans land into, and provide the `scripts/dev-pull-from-pi.sh` helper so DEV agents can pull source files from `arlowe-1.local` to their local workspace.

Purpose: Phase 1 plans 02-12 all need either (a) directories that exist or (b) a way to pull source from the live device. This plan unblocks every other Phase 1 stream. It must complete first, as Wave 1.

Output: Empty `runtime/` tree, empty `third_party/` mount points, working `dev-pull-from-pi.sh`, `.gitignore` that blocks founder biometric data.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/REQUIREMENTS.md
@.planning/phases/01-runtime-extraction/01-RESEARCH.md
@docs/05-proposed-structure.md
</context>

<tasks>

<task type="auto">
  <name>Task 1: Scaffold runtime and third_party directory tree</name>
  <files>
    runtime/voice/.gitkeep
    runtime/face/.gitkeep
    runtime/stt/.gitkeep
    runtime/tts/.gitkeep
    runtime/llm/.gitkeep
    runtime/dashboard/.gitkeep
    runtime/wake-word/.gitkeep
    runtime/cli/.gitkeep
    third_party/ax-llm/.gitkeep
    third_party/axcl/.gitkeep
  </files>
  <action>
Create the eight `runtime/` subdirectories and two `third_party/` subdirectories with `.gitkeep` files so they commit to git when empty.

```bash
mkdir -p runtime/{voice,face,stt,tts,llm,dashboard,wake-word,cli}
mkdir -p third_party/{ax-llm,axcl}
touch runtime/{voice,face,stt,tts,llm,dashboard,wake-word,cli}/.gitkeep
touch third_party/{ax-llm,axcl}/.gitkeep
```

NOTE: `third_party/ax-llm/.gitkeep` is a temporary placeholder. Plan 09 replaces this directory with a real git submodule. Do not commit any source code into `third_party/ax-llm/` in this plan.
  </action>
  <verify>
```bash
test -d runtime/voice && test -d runtime/face && test -d runtime/stt && \
  test -d runtime/tts && test -d runtime/llm && test -d runtime/dashboard && \
  test -d runtime/wake-word && test -d runtime/cli && \
  test -d third_party/ax-llm && test -d third_party/axcl && echo OK
```
  </verify>
  <done>All 10 directories exist with `.gitkeep` files, tracked by git.</done>
</task>

<task type="auto">
  <name>Task 2: Author scripts/dev-pull-from-pi.sh helper</name>
  <files>scripts/dev-pull-from-pi.sh</files>
  <action>
Create an executable bash script at `scripts/dev-pull-from-pi.sh` that uses the `arlowe-1` SSH alias (already configured in the global `~/.claude/CLAUDE.md`) to rsync source files from the live Pi into a local stash directory `.dev-stash/arlowe-1/` (gitignored). This unblocks all Stream A/B/D plans which need source from the Pi.

Behaviour:
- Default: dry-run (rsync `-n`); requires explicit `--apply` flag to copy files.
- Targets to mirror (one rsync per target):
  - `~/iol-monorepo/packages/whisplay/` → `.dev-stash/arlowe-1/whisplay/`
  - `~/iol-monorepo/packages/arlowe-dashboard/` → `.dev-stash/arlowe-1/arlowe-dashboard/`
  - `~/bin/` → `.dev-stash/arlowe-1/bin/`
  - `~/wake_word/` → `.dev-stash/arlowe-1/wake_word/` **with `--exclude='*.pkl' --exclude='positive/' --exclude='negative/'`** to never pull founder biometric data.
  - `~/.config/systemd/user/` → `.dev-stash/arlowe-1/systemd-user/`
  - `~/iol-monorepo/packages/whisplay/systemd/` → `.dev-stash/arlowe-1/systemd-whisplay/`
  - `~/models/Qwen2.5-7B-Instruct/run_api.sh` → `.dev-stash/arlowe-1/llm/run_api.sh`
  - `~/models/Qwen2.5-7B-Instruct/qwen2.5_tokenizer_uid.py` → `.dev-stash/arlowe-1/llm/qwen2.5_tokenizer_uid.py`
- Print summary at end: byte count + file count per target.
- Exit code 0 only if all rsyncs succeed.
- Use `set -euo pipefail`.
- Print clear usage when called with `-h`/`--help`.

Reference for rsync flags: `-avz --delete-excluded` to mirror; with `--dry-run` by default. Add `--apply` flag handling.

Final line: `chmod +x scripts/dev-pull-from-pi.sh`.

Do NOT actually run the script in this task — that's the verifier's call. Just create it.
  </action>
  <verify>
```bash
test -x scripts/dev-pull-from-pi.sh && \
  bash -n scripts/dev-pull-from-pi.sh && \
  scripts/dev-pull-from-pi.sh --help 2>&1 | grep -qi 'usage' && \
  grep -q '*.pkl' scripts/dev-pull-from-pi.sh && \
  grep -q 'arlowe-1' scripts/dev-pull-from-pi.sh && \
  echo OK
```
  </verify>
  <done>Script is executable, passes shellcheck/`bash -n`, prints usage, and the `*.pkl` exclude is present (non-negotiable per research R6).</done>
</task>

<task type="auto">
  <name>Task 3: Update .gitignore to block founder biometric data and dev stash</name>
  <files>.gitignore</files>
  <action>
Append the following block to `.gitignore` (create the file if it doesn't exist):

```
# === Phase 1 Runtime Extraction ===
# Founder voice biometric data must NEVER enter this repo (research R6).
*.pkl
runtime/wake-word/positive/
runtime/wake-word/negative/
runtime/wake-word/*.pkl

# Local dev stash from scripts/dev-pull-from-pi.sh — never commit live Pi mirrors.
.dev-stash/

# Standard Python / Next.js noise that will accumulate in runtime/ subtrees.
__pycache__/
*.py[cod]
*$py.class
.venv/
venv/
node_modules/
.next/
.env.local
.env.*.local
```

If `.gitignore` already exists, preserve existing entries — only append the new block.
  </action>
  <verify>
```bash
grep -q '^\*\.pkl' .gitignore && \
  grep -q '\.dev-stash/' .gitignore && \
  grep -q 'runtime/wake-word/positive/' .gitignore && \
  echo OK
```
  </verify>
  <done>`.gitignore` blocks all `.pkl` files, `.dev-stash/`, and the wake-word audio sample directories. Founder biometric data cannot accidentally be committed.</done>
</task>

</tasks>

<verification>
Phase-level checks for this plan:

```bash
# Directories exist
ls runtime/{voice,face,stt,tts,llm,dashboard,wake-word,cli} 2>/dev/null
ls third_party/{ax-llm,axcl} 2>/dev/null

# Helper script is executable and syntactically valid
bash -n scripts/dev-pull-from-pi.sh

# Founder data is blocked
grep -q '\*\.pkl' .gitignore
```

A non-functional check (research R6 enforcement):
```bash
# A pkl file at any path under wake-word should be gitignored
mkdir -p /tmp/_test && cp /dev/null /tmp/_test/founder.pkl
git check-ignore -v runtime/wake-word/anything.pkl  # exit 0 = ignored = good
```
</verification>

<success_criteria>
- All 10 directories exist with `.gitkeep` files
- `scripts/dev-pull-from-pi.sh` is executable, prints usage, dry-runs by default, excludes `*.pkl`/`positive/`/`negative/`
- `.gitignore` blocks `*.pkl`, `.dev-stash/`, and the wake-word sample directories
- All changes committable in a single PR (<100 net lines)
</success_criteria>

<output>
After completion, create `.planning/phases/01-runtime-extraction/01-01-SUMMARY.md` documenting:
- The directory tree that now exists
- The dev-pull-from-pi.sh interface (flags, targets)
- That this plan is the prerequisite for all other Phase 1 plans
</output>
