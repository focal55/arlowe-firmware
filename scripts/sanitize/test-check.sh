#!/usr/bin/env bash
# scripts/sanitize/test-check.sh
#
# Self-test: plants banned artifacts in temp trees and asserts check.sh catches them.
# This file is in .sanitize-allowlist so the literals below don't trip the production gate.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

# ---------------------------------------------------------------------------
# Scenario 1: planted banned literal — grep gate catches it
# ---------------------------------------------------------------------------

TMP=$(mktemp -d)
TMP2=$(mktemp -d)
trap 'rm -rf "$TMP" "$TMP2"' EXIT

git -C "$TMP" init -q
echo "user: focal55" > "$TMP/planted.txt"
git -C "$TMP" add .
git -C "$TMP" -c user.email=t@t -c user.name=t commit -qm test

cp "$REPO_ROOT/scripts/sanitize/banlist.txt" "$TMP/"
touch "$TMP/.sanitize-allowlist"

EXIT_CODE=0
if (cd "$TMP" && bash "$REPO_ROOT/scripts/sanitize/check.sh" --grep-only); then
  EXIT_CODE=0
else
  EXIT_CODE=$?
fi

if [[ "$EXIT_CODE" -eq 0 ]]; then
  echo "FAIL: grep gate did not catch planted focal55" >&2
  exit 1
fi

echo "PASS: grep gate correctly blocked planted focal55"

# ---------------------------------------------------------------------------
# Scenario 2: planted openclaw unit — units gate catches it, clean unit passes
# ---------------------------------------------------------------------------

touch "$TMP2/openclaw-test.service"
touch "$TMP2/safe-unit.service"

UNIT_OUT=$(bash "$REPO_ROOT/scripts/sanitize/check.sh" --units-only --scan-dir "$TMP2" 2>&1 || true)
UNIT_EXIT=0
bash "$REPO_ROOT/scripts/sanitize/check.sh" --units-only --scan-dir "$TMP2" >/dev/null 2>&1 || UNIT_EXIT=$?

if [[ "$UNIT_EXIT" -eq 0 ]]; then
  echo "FAIL: units gate did not catch planted openclaw-test.service" >&2
  exit 1
fi

if ! echo "$UNIT_OUT" | grep -q "openclaw-test.service"; then
  echo "FAIL: units gate output did not mention openclaw-test.service" >&2
  echo "  output was: $UNIT_OUT" >&2
  exit 1
fi

if echo "$UNIT_OUT" | grep -q "safe-unit.service"; then
  echo "FAIL: units gate output incorrectly flagged safe-unit.service" >&2
  echo "  output was: $UNIT_OUT" >&2
  exit 1
fi

echo "PASS: gate correctly blocked planted openclaw-test.service while allowing safe-unit.service"

# ---------------------------------------------------------------------------
# Scenario 3: --scan-dir honors the grep gate (Phase 6 reuse contract)
# ---------------------------------------------------------------------------

echo "user: focal55" > "$TMP2/leaked-config.txt"

GREP_EXIT=0
bash "$REPO_ROOT/scripts/sanitize/check.sh" --grep-only --scan-dir "$TMP2" >/dev/null 2>&1 || GREP_EXIT=$?

if [[ "$GREP_EXIT" -eq 0 ]]; then
  echo "FAIL: grep gate with --scan-dir did not catch planted focal55 literal" >&2
  exit 1
fi

echo "PASS: grep gate with --scan-dir correctly blocked planted focal55 literal"
exit 0
