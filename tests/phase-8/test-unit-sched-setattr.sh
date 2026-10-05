#!/usr/bin/env bash
# Static gate: every unit that denies @resources and whose code path runs nmcli
# must re-admit sched_setattr (GLib calls it on thread creation; the deny gives
# nmcli SIGSYS), and no unit may drop the deny to get there.
# The helpers are invoked through check "$@", which shellcheck cannot see.
# shellcheck disable=SC2317,SC2329
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UNITS="${REPO_ROOT}/units"
fails=0
ok() { echo "[OK] $1"; }
fail() { echo "[FAIL] $1"; fails=1; }
check() { local name=$1; shift; if "$@"; then ok "$name"; else fail "$name"; fi; }

# code_tree <unit>: the repo path whose sources the unit's ExecStart runs, or empty.
code_tree() {
    local exec target
    exec=$(sed -n 's/^ExecStart=//p' "$1" | head -n1)
    if [[ "$exec" =~ python3?[[:space:]]+-m[[:space:]]+([A-Za-z0-9_]+) ]]; then
        echo "runtime/${BASH_REMATCH[1]}"
    elif [[ "$exec" =~ /opt/arlowe/(runtime/[^[:space:]]+) ]]; then
        target=${BASH_REMATCH[1]}
        if [[ "$target" == runtime/dashboard/* ]]; then echo "runtime/dashboard"; else echo "$target"; fi
    fi
}

runs_nmcli() {
    local tree="${REPO_ROOT}/$1"
    [[ -e "$tree" ]] || return 1
    grep -rIq --exclude-dir=tests --exclude-dir=fixtures --exclude-dir=node_modules \
        --exclude-dir=.next --exclude='*.md' -- nmcli "$tree"
}

denies_resources() { grep -Eq '^SystemCallFilter=~.*@resources' "$1"; }
has_line() { grep -qxF -- "$2" "$1"; }
in_users() { local u; for u in "${users[@]}"; do [[ "$u" == "$1" ]] && return 0; done; return 1; }

users=()
denying=()
for unit in "$UNITS"/*.service; do
    name=$(basename "$unit" .service)
    denies_resources "$unit" || continue
    denying+=("$name")
    tree=$(code_tree "$unit")
    if [[ -n "$tree" ]] && runs_nmcli "$tree"; then
        users+=("$name")
        echo "nmcli user: $name ($tree)"
    fi
done
echo "classified as nmcli users: ${users[*]:-none}"

# Without these the classifier could be broken and the loop below pass vacuously.
for required in arlowe-radio-init arlowe-pair arlowe-dashboard; do
    check "classifier finds $required as an nmcli user" in_users "$required"
done

for name in "${users[@]}"; do
    check "$name re-admits sched_setattr" has_line "$UNITS/$name.service" "SystemCallFilter=sched_setattr"
done

for name in "${denying[@]}"; do
    check "$name keeps the ~@privileged @resources deny" has_line "$UNITS/$name.service" "SystemCallFilter=~@privileged @resources"
done

exit "$fails"
