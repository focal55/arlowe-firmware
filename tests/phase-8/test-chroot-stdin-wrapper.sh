#!/usr/bin/env bash
# pi-gen runs each *-run-chroot.sh as `on_chroot < script`, so bash reads the
# script from stdin. A child that reads stdin (apt, an installer, cat) swallows
# the unread remainder of the script and bash exits 0 silently, skipping every
# later step.
#
# Contract for every pi-gen/stage-arlowe/*/*-run-chroot.sh:
#   - the body is a brace group: a line that is exactly `{`, preceded only by
#     blank lines, comments and `set ...` lines (so `set -euo pipefail` may sit
#     either before the `{` or inside the group; both are accepted);
#   - the last non-blank line is exactly `} </dev/null`, which gives every child
#     in the group an empty stdin. bash parses the whole group before running
#     it, so the script text is fully consumed before any child starts.
# The [defect], [wrapped] and [wrapped-fail] cases prove the mechanism and pass
# on any tree; the [open] and [close] cases fail until the scripts are wrapped.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
PASSED=0; FAILED=0
OUT=""; RC=0
ok() { if [[ $1 -eq 0 ]]; then echo "[OK]   $2"; PASSED=$((PASSED+1)); else echo "[FAIL] $2"; echo "  ${OUT//$'\n'/$'\n'  }"; FAILED=$((FAILED+1)); fi; }

# stdin_run SCRIPT: feed the script to bash on stdin, as on_chroot does.
stdin_run() { OUT="$(bash < "$1" 2>&1)"; RC=$?; }

# mk NAME CHILD MODE: write a script whose middle step is CHILD; MODE is wrap or plain.
mk() {
  local f="${WORK}/$1"
  {
    echo 'set -euo pipefail'
    [[ $3 == wrap ]] && echo '{'
    echo 'echo before'
    echo "$2"
    echo 'echo after'
    [[ $3 == wrap ]] && echo '} </dev/null'
  } > "${f}"
}

for child in 'cat >/dev/null' 'head -c1 >/dev/null' 'read -r _ || true'; do
  mk plain "${child}" plain; stdin_run "${WORK}/plain"
  [[ "${OUT}" == *before* && "${OUT}" != *after* ]]
  ok $? "[defect] unwrapped script with '${child}' loses its tail (detector works)"

  mk wrapped "${child}" wrap; stdin_run "${WORK}/wrapped"
  [[ ${RC} -eq 0 && "${OUT}" == *before* && "${OUT}" == *after* ]]
  ok $? "[wrapped] '} </dev/null' group with '${child}' runs to the end, exit 0"
done

# A failing step inside the group must still abort the script nonzero.
printf '%s\n' 'set -euo pipefail' '{' 'false' 'echo after' '} </dev/null' > "${WORK}/fail"
stdin_run "${WORK}/fail"
[[ ${RC} -ne 0 && "${OUT}" != *after* ]]
ok $? "[wrapped-fail] set -e still aborts inside the group"

shopt -s nullglob
SCRIPTS=("${REPO_ROOT}"/pi-gen/stage-arlowe/*/*-run-chroot.sh)
OUT="no pi-gen/stage-arlowe/*/*-run-chroot.sh found"
[[ ${#SCRIPTS[@]} -ge 2 ]]; ok $? "[glob] at least the two known chroot scripts are found"

for s in "${SCRIPTS[@]}"; do
  rel="${s#"${REPO_ROOT}"/}"
  OUT="$(bash -n "$s" 2>&1)"; ok $? "[syntax] ${rel} passes bash -n"

  # First line that is not blank, a comment or a set line must be the opening brace.
  first="$(grep -vE '^[[:space:]]*(#.*)?$|^[[:space:]]*set[[:space:]]' "$s" | head -n1)"
  OUT="first body line is: '${first}' (expected exactly '{')"
  st=1; [[ "${first}" == '{' ]] && st=0
  ok "${st}" "[open] ${rel} body starts with a '{' line"

  last="$(grep -vE '^[[:space:]]*$' "$s" | tail -n1)"
  OUT="last non-blank line is: '${last}' (expected exactly '} </dev/null')"
  [[ "${last}" == '} </dev/null' ]]; ok $? "[close] ${rel} ends with '} </dev/null'"
done

echo "${PASSED} passed, ${FAILED} failed"
[[ ${FAILED} -eq 0 ]]
