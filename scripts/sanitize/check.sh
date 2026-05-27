#!/usr/bin/env bash
# scripts/sanitize/check.sh
#
# Grep gate: scans tracked, non-allow-listed files for banned identity literals.
# Emits GitHub Actions error annotations on hits; exits non-zero if any found.
#
# Flags:
#   --grep-only   Run the banlist scan (default behavior in Plan 01).
#   --units-only  Placeholder for Plan 02 unit-name block (exits 0 with a note).
#   --scan-dir DIR  (reserved for Plan 06 image-build hook; not yet implemented)
#
# No flag defaults to --grep-only. When Plan 02 lands, no-flag will run both gates.
#
# Exit codes:
#   0  clean — no banned literals found
#   1  banned literal detected in at least one tracked file
#   2  tool dependency missing (e.g., ripgrep not installed)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

BANLIST="$SCRIPT_DIR/banlist.txt"
ALLOWLIST=".sanitize-allowlist"

MODE="grep-only"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --grep-only)  MODE="grep-only" ; shift ;;
    --units-only) MODE="units-only"; shift ;;
    --scan-dir)
      echo "check.sh: --scan-dir not implemented yet; landing in plan 06" >&2
      exit 0
      ;;
    *) echo "check.sh: unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [[ "$MODE" == "units-only" ]]; then
  echo "check.sh: units gate not implemented in plan 01; landing in plan 02" >&2
  exit 0
fi

# --- grep-only mode ---

command -v rg >/dev/null 2>&1 || { echo "check.sh: rg not found; install ripgrep" >&2; exit 2; }

# Build a pathspec array from .sanitize-allowlist (gitignore-style globs).
# git ls-files honors :(exclude,glob) pathspecs with gitignore semantics.
PATHSPECS=()
if [[ -f "$ALLOWLIST" ]]; then
  while IFS= read -r line; do
    line="${line%%#*}"                            # strip inline comments
    line="${line#"${line%%[![:space:]]*}"}"       # ltrim
    line="${line%"${line##*[![:space:]]}"}"       # rtrim
    [[ -z "$line" ]] && continue
    PATHSPECS+=(":(exclude,glob)$line")
  done < "$ALLOWLIST"
fi

# Enumerate tracked, non-allow-listed files.
# Use a while-read loop instead of mapfile for bash 3.x compatibility (macOS dev).
FILES=()
while IFS= read -r f; do
  FILES+=("$f")
done < <(git ls-files -- "${PATHSPECS[@]+${PATHSPECS[@]}}")

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "sanitize: clean (0 tracked files scanned after allow-list)"
  exit 0
fi

# Scan for banned literals. rg exits 1 on no-matches; || true keeps pipefail happy.
# -H forces filename in output even when only one file is scanned (no-heading alone
# omits the filename for single-file runs, breaking the path:line:col:text parse).
HITS=$(rg -iFnH --column --no-heading -f "$BANLIST" -- "${FILES[@]}" || true)

if [[ -z "$HITS" ]]; then
  echo "sanitize: clean (${#FILES[@]} tracked files scanned)"
  exit 0
fi

# Emit GitHub annotations and human-readable output for each hit.
EXIT=0
while IFS= read -r hit; do
  [[ -z "$hit" ]] && continue
  # rg -n --column output: path:line:col:matched-text
  IFS=: read -r path line col rest <<< "$hit"
  printf '::error file=%s,line=%s,col=%s,title=Banned identity literal::banned identity literal at %s:%s:%s — if this is a legitimate historical reference, add the path to .sanitize-allowlist\n' \
    "$path" "$line" "$col" "$path" "$line" "$col"
  printf '%s:%s:%s: %s\n' "$path" "$line" "$col" "$rest" >&2
  EXIT=1
done <<< "$HITS"

exit "$EXIT"
