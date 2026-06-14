#!/usr/bin/env bash
# scripts/sanitize/check.sh
#
# Sanitization gate runner.
#
# Modes:
#   check.sh                Run grep + units gates against tracked files (default for CI).
#   check.sh --grep-only    Run only the banned-literal grep gate.
#   check.sh --units-only   Run only the banned-unit-name gate.
#   check.sh --scan-dir DIR Scan DIR via `find` instead of `git ls-files`.
#                           Use case: Phase 6 image-build, scanning the assembled
#                           rootfs at /mnt/img/ before pi-gen finalizes the .img.
#                           NOTE: .sanitize-allowlist is ignored in --scan-dir mode.
#                           Can be combined with --grep-only or --units-only.
#
# Exit codes: 0 clean, 1 hits found, 2 invalid arguments.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BANLIST="$SCRIPT_DIR/banlist.txt"
ALLOWLIST=".sanitize-allowlist"

MODE="both"
SCAN_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --grep-only)
      if [[ "$MODE" == "units-only" ]]; then
        echo "check.sh: --grep-only and --units-only are mutually exclusive" >&2
        exit 2
      fi
      MODE="grep-only"
      shift
      ;;
    --units-only)
      if [[ "$MODE" == "grep-only" ]]; then
        echo "check.sh: --grep-only and --units-only are mutually exclusive" >&2
        exit 2
      fi
      MODE="units-only"
      shift
      ;;
    --scan-dir)
      if [[ $# -lt 2 ]]; then
        echo "check.sh: --scan-dir requires a directory argument" >&2
        exit 2
      fi
      SCAN_DIR="$2"
      shift 2
      ;;
    *)
      echo "check.sh: unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

# git rev-parse and cd are only needed when using git-backed (non --scan-dir) mode.
# Skip when running inside a Docker testbed where git is not installed.
if [[ -z "$SCAN_DIR" ]]; then
  REPO_ROOT="$(git rev-parse --show-toplevel)"
  cd "$REPO_ROOT"
fi

# ---------------------------------------------------------------------------
# Grep gate
# ---------------------------------------------------------------------------

run_grep_gate() {
  command -v rg >/dev/null 2>&1 || { echo "check.sh: rg not found; install ripgrep" >&2; exit 2; }

  local files=()
  if [[ -n "$SCAN_DIR" ]]; then
    # --scan-dir mode: enumerate all files under DIR; allow-list does not apply.
    while IFS= read -r f; do
      files+=("$f")
    done < <(find "$SCAN_DIR" -type f)
  else
    # tracked-files mode: apply allow-list exclusions.
    local pathspecs=()
    if [[ -f "$ALLOWLIST" ]]; then
      while IFS= read -r line; do
        line="${line%%#*}"                          # strip inline comments
        line="${line#"${line%%[![:space:]]*}"}"     # ltrim
        line="${line%"${line##*[![:space:]]}"}"     # rtrim
        [[ -z "$line" ]] && continue
        pathspecs+=(":(exclude,glob)$line")
      done < "$ALLOWLIST"
    fi
    while IFS= read -r f; do
      files+=("$f")
    done < <(git ls-files -- "${pathspecs[@]+${pathspecs[@]}}")
  fi

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "sanitize grep: clean (0 files scanned)"
    return 0
  fi

  # rg exits 1 on no-matches; || true keeps pipefail happy.
  # -H forces filename even for single-file scans (no-heading alone omits it).
  local hits
  hits=$(rg -iFnH --column --no-heading -f "$BANLIST" -- "${files[@]}" || true)

  if [[ -z "$hits" ]]; then
    echo "sanitize grep: clean (${#files[@]} files scanned)"
    return 0
  fi

  local exit_code=0
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    # rg -n --column output: path:line:col:matched-text
    IFS=: read -r path line col rest <<< "$hit"
    printf '::error file=%s,line=%s,col=%s,title=Banned identity literal::banned identity literal at %s:%s:%s — if this is a legitimate historical reference, add the path to .sanitize-allowlist\n' \
      "$path" "$line" "$col" "$path" "$line" "$col"
    printf '%s:%s:%s: %s\n' "$path" "$line" "$col" "$rest" >&2
    exit_code=1
  done <<< "$hits"

  return "$exit_code"
}

# ---------------------------------------------------------------------------
# Units gate
# ---------------------------------------------------------------------------

run_units_gate() {
  local units=()
  if [[ -n "$SCAN_DIR" ]]; then
    while IFS= read -r u; do
      units+=("$u")
    done < <(find "$SCAN_DIR" -type f \
      \( -name '*.service' -o -name '*.timer' -o -name '*.socket' \
         -o -name '*.target' -o -name '*.mount' -o -name '*.path' \))
  else
    while IFS= read -r u; do
      units+=("$u")
    done < <(git ls-files \
      -- '*.service' '*.timer' '*.socket' '*.target' '*.mount' '*.path')
  fi

  if [[ ${#units[@]} -eq 0 ]]; then
    echo "sanitize units: clean (0 unit files found)"
    return 0
  fi

  local exit_code=0
  while IFS= read -r prefix; do
    prefix="${prefix%%#*}"                        # strip inline comments
    prefix="${prefix#"${prefix%%[![:space:]]*}"}" # ltrim
    prefix="${prefix%"${prefix##*[![:space:]]}"}" # rtrim
    [[ -z "$prefix" ]] && continue
    for unit in "${units[@]+${units[@]}}"; do
      local base
      base="$(basename "$unit")"
      # Unquoted RHS is intentional: $prefix is a bash glob pattern (e.g. "iol-*").
      # shellcheck disable=SC2053
      if [[ "$base" == $prefix ]]; then
        printf '::error file=%s,line=1,title=Banned systemd unit::banned systemd unit name %s (matches pattern %s); founder-only service must not ship in firmware\n' \
          "$unit" "$base" "$prefix"
        printf '%s: banned unit basename (matches %s)\n' "$unit" "$prefix" >&2
        exit_code=1
      fi
    done
  done < "$SCRIPT_DIR/unit-prefixes.txt"

  if [[ "$exit_code" -eq 0 ]]; then
    echo "sanitize units: clean (${#units[@]} unit files checked)"
  fi

  return "$exit_code"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

GREP_EXIT=0
UNITS_EXIT=0

case "$MODE" in
  grep-only)
    run_grep_gate || GREP_EXIT=$?
    ;;
  units-only)
    run_units_gate || UNITS_EXIT=$?
    ;;
  both)
    echo "--- grep gate ---"
    run_grep_gate  || GREP_EXIT=$?
    echo "--- units gate ---"
    run_units_gate || UNITS_EXIT=$?
    ;;
esac

if [[ $((GREP_EXIT | UNITS_EXIT)) -ne 0 ]]; then
  exit 1
fi
exit 0
