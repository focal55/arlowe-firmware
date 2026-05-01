# Agentic Workforce Template

Standardized scaffolding for projects built with a Claude Code agentic workforce. Click **"Use this template"** on GitHub to start a new project with all conventions, agents, and tooling already in place.

## What this template gives you

- **Issue templates** for the four work types: research, QA test-writing, DEV implementation, bug, docs
- **PR template** that triggers the PR-Reviewer agent
- **GitHub Actions workflows**: CI (lint + typecheck + test), PR checks, auto-labeling
- **Standard label set** declared in `.github/labels.yml`
- **CODEOWNERS** wired to route reviews
- **`init-project.sh` script** that bootstraps the GitHub Project board, applies labels, sets branch protection
- **`CLAUDE.md` and `AGENTS.md` templates** for project-level context
- **Architecture overview doc** explaining how GSD + DEV/QA/PR-Reviewer agents compose

## Workforce model at a glance

```
GSD (planning)            →  Roadmap → Phase plans → Issues created
                                                       ↓
GitHub Project board      →  Backlog → Researching → Specced → Writing Tests → Ready for Dev → In Dev → In Review → Verifying → Done
                                            ↓           ↓           ↓               ↓             ↓        ↓           ↓
Agents:                              gsd-phase-      (transition)   QA          (transition)   DEV    PR-Reviewer  gsd-verifier
                                     researcher
```

- **GSD** (`/gsd:*` slash commands, `gsd-*` agents) handles macro planning: roadmap → milestones → phases → phase plans → verification.
- **DEV / QA / PR-Reviewer** trio (in `~/.claude/agents/`) handle the per-task lifecycle on the GitHub board.
- **Human** orchestrates: moves cards, makes product calls, approves merges, handles escalations.

See `docs/architecture-overview.md` for the full integration story.

## Bootstrapping a new project

1. On GitHub, click **"Use this template"** → name your new repo
2. Clone the new repo locally
3. Run `bash scripts/init-project.sh <project-name>` from the repo root
   - Creates the standard GitHub Project (v2) board
   - Applies the standard label set
   - Sets branch protection on `main`
   - Initializes a project-level `CLAUDE.md` from the template
4. Run `/gsd:new-project` in Claude Code to seed the roadmap
5. Translate phase plan items into GitHub issues (the `02-qa-spec.yml` and `03-dev-task.yml` templates make this fast)
6. Workforce starts cutting

## Updating this template

This is a template repo, so updates here do **not** auto-propagate to projects already created from it. To pull updates into an existing project:

```bash
git remote add template https://github.com/focal55/agentic-workforce-template.git
git fetch template
# cherry-pick or merge specific files
git checkout template/main -- .github/workflows/ci.yml
```

Be deliberate about what you pull — workflow files are usually safe; issue templates need per-project customization.

## Files in this template

| Path | Purpose |
|---|---|
| `.github/ISSUE_TEMPLATE/` | Structured forms for each work type |
| `.github/PULL_REQUEST_TEMPLATE.md` | PR description template |
| `.github/workflows/ci.yml` | Lint, typecheck, test on every push and PR |
| `.github/workflows/pr-checks.yml` | PR-specific gates (size, conventional commit, etc.) |
| `.github/workflows/auto-label.yml` | Auto-applies labels based on issue template + paths |
| `.github/labels.yml` | Declarative label definitions |
| `.github/CODEOWNERS` | Reviewer routing |
| `scripts/init-project.sh` | Project-board + labels + branch-protection bootstrap |
| `CLAUDE.md.template` | Project-level Claude Code context |
| `AGENTS.md.template` | Per-project agent overrides (rare) |
| `docs/architecture-overview.md` | How the agentic workforce composes |

## License

Internal tooling — not for distribution. Adjust if making public.
