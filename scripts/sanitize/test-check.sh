#!/usr/bin/env bash
# scripts/sanitize/test-check.sh
#
# Self-test: plants a banned literal in a temp git tree and asserts check.sh exits non-zero.
# This file is in .sanitize-allowlist so the literal below doesn't trip the production gate.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Create a minimal git tree in the temp dir with a planted banned literal.
git -C "$TMP" init -q
echo "user: focal55" > "$TMP/planted.txt"
git -C "$TMP" add .
git -C "$TMP" -c user.email=t@t -c user.name=t commit -qm test

# Copy banlist and an effectively-empty allow-list into the temp tree.
# The real allow-list globs don't match any paths in this temp tree, so no
# exclusions apply — the gate must catch the planted literal.
cp "$REPO_ROOT/scripts/sanitize/banlist.txt" "$TMP/"
touch "$TMP/.sanitize-allowlist"

# Run the gate against the temp tree; capture exit code without triggering set -e.
EXIT_CODE=0
if (cd "$TMP" && bash "$REPO_ROOT/scripts/sanitize/check.sh" --grep-only); then
  EXIT_CODE=0
else
  EXIT_CODE=$?
fi

if [[ "$EXIT_CODE" -eq 0 ]]; then
  echo "FAIL: gate did not catch planted focal55" >&2
  exit 1
fi

echo "PASS: gate correctly blocked planted focal55"
exit 0
