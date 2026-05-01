# Agentic Workforce Architecture

This document explains how a 1-human + Claude-Code-agents team is structured to ship software reliably. It is the source of truth for how the workforce composes; agents and humans both refer back to it.

The protocol is defined globally at `~/.claude/CLAUDE.md` so it applies to every Claude Code session. This document goes deeper than that file and explains the *why*.

## Roles

The workforce has two macro layers and four micro roles, all backed by a GitHub Project board.

### Macro layer: GSD (Get Shit Done)

GSD is a phase-based planning + verification framework, installed at `~/.claude/agents/gsd-*.md` and `~/.claude/get-shit-done/`. It produces structured planning artifacts in `.planning/`.

| GSD agent | Purpose |
|---|---|
| `gsd-roadmapper` | Creates project roadmap with phase breakdown |
| `gsd-project-researcher` | Researches domain ecosystem before roadmap |
| `gsd-research-synthesizer` | Combines parallel research outputs |
| `gsd-planner` | Creates phase plans (PLAN.md) with task breakdown |
| `gsd-plan-checker` | Verifies plans will achieve phase goals |
| `gsd-phase-researcher` | Researches a phase before planning it |
| `gsd-executor` | Executes a phase plan (used optionally — see below) |
| `gsd-verifier` | Goal-backward verification of phase completion |
| `gsd-debugger` | Systematic debugging with persistent state |
| `gsd-codebase-mapper` | Analyzes codebase structure |
| `gsd-integration-checker` | Verifies cross-phase integration |

GSD is invoked via slash commands:

- `/gsd:new-project` — initialize a new project with deep context gathering
- `/gsd:plan-phase` — create executable PLAN.md for a phase
- `/gsd:execute-phase` — run all plans in a phase
- `/gsd:verify-work` — UAT-style verification
- `/gsd:audit-milestone` — pre-archive audit of milestone completion

### Micro layer: DEV / QA / PR-Reviewer trio

Three single-purpose agents handle the per-task lifecycle on the GitHub Project board, installed at `~/.claude/agents/dev.md`, `qa.md`, `pr-reviewer.md`.

| Agent | Reads | Writes | Done when | Default model |
|---|---|---|---|---|
| **DEV** | Issue, related code, failing tests | Implementation code only | Tests pass green, lint clean, PR opened, label transition done | Sonnet |
| **QA** | Issue acceptance criteria, related code | Test specs (`*.spec.ts`) | Tests written and failing meaningfully, PR opened, dev follow-up issue created | Sonnet |
| **PR Reviewer** | PR diff, ADRs, CLAUDE.md | PR review (approve / request changes) | Reviewed against checklist | Sonnet (Opus override for `package:security`) |

The roles are deliberately narrow. DEV does not write tests; QA does not write production code; Reviewer does not commit code. Crossing these lines breaks the workforce.

## The honest spawn model

This is the most important section to understand correctly. The "agentic workforce" name is aspirational; the reality is more grounded.

### What's true

- **Claude Code is not a daemon.** It does not watch GitHub. It runs only when invoked by you.
- **Subagents are spawned by the main Claude conversation** via the Agent tool. They do their work and return.
- **Closing your laptop pauses the workforce.** When Claude Code isn't running, no agent is doing anything.
- **The orchestrator is you.** You decide when to start a session, what to dispatch, when to stop.

### What's automated

- **Card movement on the project board.** The `project-board-sync.yml` GitHub Actions workflow listens for issue/PR events and moves cards between columns based on labels. Runs entirely on GitHub, independent of Claude Code.
- **Label-driven dispatch.** When an agent finishes, it changes a label (e.g., `agent:dev` → `agent:reviewer`). The board sync workflow moves the card; the next time you (or `/workforce-tick`) query the board, you see the new state.

### Always-on mode while laptop is open

The closest you get to "always-on" is `/loop /workforce-tick`:

```bash
cd ~/projects/<active-project>
claude --model haiku-4-5
```

Then in the session: `/loop /workforce-tick`

The loop self-paces. Each tick:
1. Checks the pause label.
2. Queries the board for unblocked `agent:*`-labeled issues.
3. Atomically claims the highest-priority one per role (auto-assigns to focal55).
4. Dispatches the matching subagent in parallel.
5. Sleeps until the next tick.

Combined with **Remote Control** (`claude remote-control`), you can monitor and steer the loop from your phone or browser. Combined with the `--all` flag and `~/.claude/workforce-projects.yml`, a single loop session can poll multiple projects.

### Multi-project mode

`/workforce-tick` defaults to the current cwd's repo. For multi-project parallelism:

- **Per-project loops** (recommended for focused work): one terminal per active project, each running `/loop /workforce-tick`. Each loop scoped via `gh repo view`.
- **Single multi-project loop** (recommended for passive progress while traveling): `/workforce-tick --all` reads `~/.claude/workforce-projects.yml`:

```yaml
projects:
  - repo: focal55/8bithomies
    project_number: 1
    enabled: true
  - repo: focal55/another-project
    project_number: 2
    enabled: false
```

## Cost and model strategy

Match model capability to actual decision complexity. The workforce involves many cheap polls and fewer expensive thinking tasks; pricing should reflect that.

| Role | Model | Why |
|---|---|---|
| Loop driver (`/loop /workforce-tick`) | Haiku 4.5 | Polling and dispatching only. ~50× cheaper than Opus. |
| DEV agent | Sonnet 4.6 | Implementation quality matters but tests + acceptance criteria heavily constrain the work. |
| QA agent | Sonnet 4.6 | Test quality matters; the spec is given. |
| PR-Reviewer (default) | Sonnet 4.6 | Most PRs are routine. |
| PR-Reviewer (security PRs) | Opus 4.7 | Auth/payment/crypto reviews benefit from Opus reasoning. Triggered by `package:security` label or path patterns. |
| GSD agents | Inherits from caller | Planning is rare; cost impact is small. |

Rough daily cost for an active workforce:

- All Opus: ~$30–50/day
- Mixed (above): ~$5–10/day
- All Haiku: ~$1–2/day, but quality drops for code

The mixed strategy is the sweet spot: keeps code quality high, makes loop overhead negligible.

## Dispatch prompt convention

Subagents are **context-isolated**. They receive: their definition file, project CLAUDE.md, project AGENTS.md, the global `~/.claude/CLAUDE.md`, and the dispatch prompt. They do **not** receive: parent conversation history, parent's tool results, parent's TODO list, auto-memory files.

This means: **dispatch prompts must be self-contained.**

Required content in every dispatch prompt:

- GitHub repo (`owner/name`)
- Issue number and one-line summary
- Issue URL
- Role (`dev` / `qa` / `reviewer` / `researcher`)
- Explicit pickup instructions ("read issue with `gh issue view`, then... open PR with...")
- Definition-of-done reminder including the label transition the agent must perform
- Working directory for git operations

The `/workforce-tick` and `/pick-next-ticket` commands generate self-contained prompts automatically. When dispatching agents manually, follow the same convention.

## CLAUDE.md layering

| File | Loaded when | Should contain | Should NOT contain |
|---|---|---|---|
| `~/.claude/CLAUDE.md` (global) | Every Claude Code session, every project, every subagent | Workforce protocol, agent roles, label conventions, command list, personal preferences | Project-specific paths, stacks, project numbers |
| `<project>/CLAUDE.md` (project) | When Claude is in that project's cwd | Project-specific application: stack, layout, project number, repo, build commands | Generic workforce protocol (already global) |
| `<project>/AGENTS.md` (project) | Same — project cwd | Per-project agent overrides (rare) | Generic agent definitions (live in `~/.claude/agents/`) |

Subagents receive **all three** when dispatched. Precedence on conflict: project AGENTS.md > project CLAUDE.md > global CLAUDE.md > agent definition body.

The pattern is **default-on, opt-out**: the global CLAUDE.md activates the workforce protocol everywhere; a project's CLAUDE.md can disable it explicitly with a "Workforce: opted out" section.

## How the layers compose

```
                  ┌──────────────────────────────────────────┐
                  │  HUMAN: product owner, orchestrator      │
                  │  - moves cards manually only when needed │
                  │  - approves PR merges (gh pr merge       │
                  │    always prompts; never auto)           │
                  │  - art direction, product calls          │
                  │  - escalation handler                    │
                  └─────────────────┬────────────────────────┘
                                    │
                                    │ /gsd:new-project, /gsd:plan-phase
                                    ▼
                  ┌──────────────────────────────────────────┐
                  │  GSD: macro planning                     │
                  │  Roadmap → Milestone → Phase → PLAN.md   │
                  └─────────────────┬────────────────────────┘
                                    │
                                    │ /issue-from-plan
                                    ▼
              ┌─────────────────────────────────────────────────────┐
              │  GITHUB PROJECT BOARD                               │
              │  Backlog → Researching → Specced → Writing Tests    │
              │  → Ready for Dev → In Dev → In Review → Verifying   │
              │  → Done                                             │
              │                                                     │
              │  Card movement automated by                         │
              │  project-board-sync.yml (GitHub Actions)            │
              └─────────────────┬───────────────────────────────────┘
                                │
                /loop /workforce-tick   OR   /pick-next-ticket <role>
                                │
                ┌───────────────┼───────────────┬─────────────┐
                ▼               ▼               ▼             ▼
        gsd-phase-           QA agent      DEV agent     PR-Reviewer agent
        researcher                                       
                                                              │
                                                              ▼
                                                   Human merges (gh pr merge)
                                                              │
                                                              ▼
                                                   board sync → Verifying
                                                              │
                                                              ▼
                                                       gsd-verifier
                                                       (phase boundary)
```

## Standard board columns

Every project uses these columns, in this order:

1. **Backlog** — captured but not yet ready
2. **Researching** — needs spec / approach decision (gsd-phase-researcher)
3. **Specced** — approach decided, ready for tests (transitional)
4. **Writing Tests** — QA agent writing failing tests
5. **Ready for Dev** — red tests exist, DEV can start (transitional)
6. **In Dev** — DEV agent implementing
7. **In Review** — PR open, PR-Reviewer agent working
8. **Verifying** — merged, awaiting smoke test or phase verification
9. **Done** — shipped

## Standard labels

Defined in `.github/labels.yml`. Every project gets the same set so muscle memory transfers.

**Type labels** — what kind of work:
- `type:research`, `type:dev`, `type:qa`, `type:bug`, `type:docs`, `type:chore`

**Priority labels**:
- `priority:p0` (blocker), `priority:p1` (this milestone), `priority:p2` (later)

**Status labels**:
- `status:blocked`, `status:needs-human`, `status:loop-pause`

**Agent routing labels** (which agent should pick this up next):
- `agent:researcher`, `agent:qa`, `agent:dev`, `agent:reviewer`, `agent:verifier`

**Package labels** (auto-applied by `auto-label.yml`):
- `package:platform-*`, `package:game-*`, `package:apps-*`, `package:security`, etc.

`package:security` triggers PR-Reviewer to escalate to Opus.

## TDD as the contract

The DEV/QA/Reviewer split only works if **tests are the contract** between QA and DEV. If QA writes weak tests, DEV fills the gaps with bad implementation. If DEV ignores tests, the workforce loses its quality gate.

Rules:

1. **QA writes tests first.** Tests must fail meaningfully against current code.
2. **DEV makes tests pass.** No new tests in DEV PRs (escalate if tests are missing).
3. **Reviewer enforces the split.** A PR that adds production code AND tests in the same change is a smell — request a split unless the change is genuinely both (rare).

## Atomic PRs

Big PRs break agentic review. Rules:

- **<400 lines net.** If you exceed this, split.
- **One issue per PR.** If you fix two things, open two PRs.
- **One package per PR when possible.** Cross-package PRs need stronger justification.

The `pr-checks.yml` workflow enforces a hard cap of 600 net lines.

## Documentation as load-bearing infrastructure

Agents navigate by reading documentation. Bad docs = bad code. Required:

- **Global `~/.claude/CLAUDE.md`**: workforce protocol, personal preferences (reaches every project, every subagent)
- **Project `CLAUDE.md`**: project-specific config, stack, conventions, gotchas
- **Per-package `CLAUDE.md`**: package purpose, public API, internal conventions
- **`AGENTS.md` at project root**: per-project agent overrides (rare; mostly defer to global)
- **`docs/architecture/` ADRs**: every meaningful architecture decision, dated, with context and consequences

Maintain these as first-class engineering tasks. Allow time in every milestone for docs.

## Escalation paths

When agents hit ambiguity, they comment on the issue with `status:needs-human` and stop. Common escalation triggers:

- Acceptance criteria are ambiguous
- Tests seem wrong or contradictory
- Implementation needs a design choice not in the issue or ADRs
- Schema migration, breaking change, or new dependency required
- Security-sensitive code where the right answer isn't obvious

The human resolves, updates the issue, removes the `needs-human` label, and the workforce resumes.

## When to invoke which agent / command

| Situation | First action |
|---|---|
| Starting a new project | `/gsd:new-project` |
| Starting a new phase | `/gsd:plan-phase` |
| Phase plan ready, need issues on board | `/issue-from-plan` |
| Issue lacks failing tests | Add `agent:qa` label; QA picks up via `/workforce-tick` |
| Failing tests exist, ready to implement | Add `agent:dev` label; DEV picks up via `/workforce-tick` |
| PR opened | Add `agent:reviewer` label (DEV agent does this on completion); PR-Reviewer picks up |
| PR merged, phase tasks complete | `/gsd:verify-work` |
| Bug encountered | `/gsd:debug` |
| Need to understand existing code | `/gsd:map-codebase` |
| Want to dispatch one agent now | `/pick-next-ticket <role>` |
| Want continuous workforce while you work | `/loop /workforce-tick` (in a Haiku session) |
| Need to pause | Add `status:loop-pause` to any issue, or type `pause` in the loop |

## What this architecture optimizes for

- **Solo-dev velocity** — agents parallelize what one human can't
- **Quality gates** — TDD + role separation + automated review prevent regressions
- **Project portability** — same patterns across every project means muscle memory compounds
- **Auditability** — every change has an issue, a PR, a test, a review, and a merge with linked context
- **Cost control** — model strategy matches capability to need; loop driver is cheap, agents are mid-tier, security review escalates only when needed

## What this architecture does NOT optimize for

- **Hot-shot prototyping** — there's ceremony before code. For genuine throwaway prototypes, opt out via project CLAUDE.md.
- **Polyglot codebases** — the agents are tuned for TypeScript/Node-flavored projects. Heavy Go, Rust, or Python projects need agent customization.
- **Human-only teams** — humans don't need this much rail. The workforce is designed for agent-driven execution where the human is orchestrator, not implementer.
- **Working without a laptop open** — the workforce pauses when you close it. Use scheduled remote agents (`/schedule`) for genuinely autonomous work.

## Evolving this architecture

This document is versioned with the template repo. Changes here propagate to new projects automatically (via "Use this template"). Existing projects can pull updates manually.

When proposing changes, open a PR on the template repo with a short justification. Architecture decisions are sticky — agents copy the pattern they see, so changes compound.
