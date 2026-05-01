#!/usr/bin/env bash
# init-project.sh — bootstrap a new project after cloning from agentic-workforce-template.
#
# Usage:   bash scripts/init-project.sh <project-name>
# Example: bash scripts/init-project.sh 8bithomies
#
# Idempotent: safe to re-run. Skips steps that are already done.
#
# Requires:
#   - gh CLI authenticated with `repo`, `project`, `workflow` scopes
#   - Run from inside the cloned repo directory

set -euo pipefail

PROJECT_NAME="${1:-}"
if [ -z "$PROJECT_NAME" ]; then
  echo "Error: project name required" >&2
  echo "Usage: bash scripts/init-project.sh <project-name>" >&2
  exit 1
fi

# Discover the repo we're in (must be a git repo with a GitHub remote)
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Error: not inside a git repository" >&2
  exit 1
fi

REPO_FULL=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
if [ -z "$REPO_FULL" ]; then
  echo "Error: this repo is not connected to GitHub yet. Push to GitHub first." >&2
  exit 1
fi

OWNER="${REPO_FULL%%/*}"
REPO="${REPO_FULL##*/}"

echo "==> Bootstrapping project: $PROJECT_NAME"
echo "    Repo: $REPO_FULL"
echo

# ---------------------------------------------------------------------------
# 1. Apply standard label set
# ---------------------------------------------------------------------------
echo "==> Applying standard labels from .github/labels.yml..."

if [ ! -f ".github/labels.yml" ]; then
  echo "    (skipped — no labels.yml found)"
else
  # Parse labels.yml inline (avoids the github-label-sync dependency).
  # Format expected: blocks of - name / color / description per label.
  python3 - <<'PYEOF'
import subprocess
import re
import sys

with open(".github/labels.yml", "r") as f:
    content = f.read()

# Split into label blocks
blocks = re.split(r'\n(?=- name:)', content)
labels = []
for block in blocks:
    name_match = re.search(r'^- name:\s*"?([^"\n]+)"?', block, re.MULTILINE)
    color_match = re.search(r'^\s*color:\s*"?([^"\n]+)"?', block, re.MULTILINE)
    desc_match = re.search(r'^\s*description:\s*"?([^"\n]+)"?', block, re.MULTILINE)
    if name_match:
        labels.append({
            "name": name_match.group(1).strip(),
            "color": color_match.group(1).strip() if color_match else "CCCCCC",
            "description": desc_match.group(1).strip() if desc_match else "",
        })

print(f"    Found {len(labels)} labels in config")
for label in labels:
    # Try to create; if it exists, edit (idempotent)
    create = subprocess.run(
        ["gh", "label", "create", label["name"],
         "--color", label["color"],
         "--description", label["description"]],
        capture_output=True, text=True
    )
    if create.returncode != 0:
        if "already exists" in create.stderr:
            edit = subprocess.run(
                ["gh", "label", "edit", label["name"],
                 "--color", label["color"],
                 "--description", label["description"]],
                capture_output=True, text=True
            )
            if edit.returncode == 0:
                print(f"    updated: {label['name']}")
            else:
                print(f"    !! failed to edit {label['name']}: {edit.stderr.strip()}", file=sys.stderr)
        else:
            print(f"    !! failed to create {label['name']}: {create.stderr.strip()}", file=sys.stderr)
    else:
        print(f"    created: {label['name']}")
PYEOF
fi
echo

# ---------------------------------------------------------------------------
# 2. Create the GitHub Project (v2) board with standard columns
# ---------------------------------------------------------------------------
echo "==> Creating GitHub Project board..."

PROJECT_TITLE="$PROJECT_NAME"
EXISTING_PROJECT=$(gh project list --owner "$OWNER" --format json --jq ".projects[] | select(.title == \"$PROJECT_TITLE\") | .number" 2>/dev/null || true)

if [ -n "$EXISTING_PROJECT" ]; then
  echo "    Project '$PROJECT_TITLE' already exists (#$EXISTING_PROJECT). Skipping creation."
  PROJECT_NUMBER="$EXISTING_PROJECT"
else
  PROJECT_OUTPUT=$(gh project create --owner "$OWNER" --title "$PROJECT_TITLE" --format json)
  PROJECT_NUMBER=$(echo "$PROJECT_OUTPUT" | python3 -c "import sys, json; print(json.load(sys.stdin)['number'])")
  echo "    Created project '$PROJECT_TITLE' (#$PROJECT_NUMBER)"
fi

# Find the Status field (default single-select field on every project board)
echo "    Configuring Status field columns..."
STATUS_FIELD_ID=$(gh project field-list "$PROJECT_NUMBER" --owner "$OWNER" --format json --jq '.fields[] | select(.name == "Status") | .id' 2>/dev/null || true)

if [ -z "$STATUS_FIELD_ID" ]; then
  echo "    !! Could not find Status field on project. Skipping column setup."
  echo "    Add columns manually: Backlog, Researching, Specced, Writing Tests, Ready for Dev, In Dev, In Review, Verifying, Done"
else
  echo "    Status field id: $STATUS_FIELD_ID"
  echo "    NOTE: gh project field-edit cannot add SINGLE_SELECT options (GitHub API limitation as of 2025)."
  echo "    Add the columns via the web UI: https://github.com/users/$OWNER/projects/$PROJECT_NUMBER"
  echo
  echo "    Standard column order (delete the defaults first):"
  echo "      1. Backlog"
  echo "      2. Researching"
  echo "      3. Specced"
  echo "      4. Writing Tests"
  echo "      5. Ready for Dev"
  echo "      6. In Dev"
  echo "      7. In Review"
  echo "      8. Verifying"
  echo "      9. Done"
fi
echo

# ---------------------------------------------------------------------------
# 3. Set branch protection on main
# ---------------------------------------------------------------------------
echo "==> Setting branch protection on main..."

# Note: gh api accepts -F for fields; complex JSON via --input
PROTECTION_JSON=$(cat <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["Lint", "Typecheck", "Test", "Conventional commit title", "PR size", "Linked issue"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true
}
JSON
)

if echo "$PROTECTION_JSON" | gh api "repos/$REPO_FULL/branches/main/protection" --method PUT --input - >/dev/null 2>&1; then
  echo "    Branch protection applied to main"
else
  echo "    !! Failed to apply branch protection (may need to push at least one commit to main first, or repo may be empty)"
fi
echo

# ---------------------------------------------------------------------------
# 4. Initialize project-level CLAUDE.md if not present
# ---------------------------------------------------------------------------
echo "==> Initializing CLAUDE.md..."
if [ -f "CLAUDE.md" ]; then
  echo "    CLAUDE.md already exists, skipping"
elif [ -f "CLAUDE.md.template" ]; then
  cp CLAUDE.md.template CLAUDE.md
  # Replace placeholders
  sed -i.bak "s/{{PROJECT_NAME}}/$PROJECT_NAME/g" CLAUDE.md && rm -f CLAUDE.md.bak
  echo "    Created CLAUDE.md from template"
else
  echo "    No CLAUDE.md.template found, skipping"
fi
echo

# ---------------------------------------------------------------------------
# 5. Initialize AGENTS.md if not present
# ---------------------------------------------------------------------------
echo "==> Initializing AGENTS.md..."
if [ -f "AGENTS.md" ]; then
  echo "    AGENTS.md already exists, skipping"
elif [ -f "AGENTS.md.template" ]; then
  cp AGENTS.md.template AGENTS.md
  sed -i.bak "s/{{PROJECT_NAME}}/$PROJECT_NAME/g" AGENTS.md && rm -f AGENTS.md.bak
  echo "    Created AGENTS.md from template"
else
  echo "    No AGENTS.md.template found, skipping"
fi
echo

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
cat <<EOF

==> Bootstrap complete for '$PROJECT_NAME'

Next steps:
  1. Visit https://github.com/users/$OWNER/projects/$PROJECT_NUMBER and configure Status columns
     (Backlog → Researching → Specced → Writing Tests → Ready for Dev → In Dev → In Review → Verifying → Done)
  2. Edit CLAUDE.md to add project-specific context
  3. Run /gsd:new-project in Claude Code to seed the roadmap
  4. Translate phase plan items to GitHub issues using the structured templates
  5. Move cards on the board, agents pick up work via labels
EOF
