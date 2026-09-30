#!/usr/bin/env bash
# The import gate must walk `python3 -m pkg` into pkg/__main__.py and follow
# `from pkg import submodule`; before 08-25 it stopped at pkg/__init__.py and
# proved nothing about arlowe-pair.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GRAPH="${REPO_ROOT}/tests/phase-07.1/import-graph.py"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/units" "$T/runtime/pkg"
printf '[Service]\nEnvironment=PYTHONPATH=/opt/arlowe/runtime\nExecStart=/usr/bin/python3 -m pkg\n' \
    > "$T/units/fixture.service"
: > "$T/runtime/pkg/__init__.py"
printf 'from pkg import sub\n' > "$T/runtime/pkg/__main__.py"
printf 'import zz_arlowe_absent_module\n' > "$T/runtime/pkg/sub.py"

out=$(python3 "$GRAPH" --units "$T/units" --runtime "$T/runtime" --repo-root "$T" \
    --python python3 2>&1)
rc=$?
fails=0
check() { if [[ "$2" == 0 ]]; then echo "PASS $1"; else echo "FAIL $1"; fails=1; fi; }
grep -q 'runtime/pkg/__main__.py' <<<"$out"; check "walks pkg/__main__.py" $?
grep -q 'runtime/pkg/sub.py' <<<"$out"; check "follows from pkg import sub" $?
grep -q 'FAIL fixture: zz_arlowe_absent_module' <<<"$out"; check "names the missing import" $?
[[ "$rc" != 0 ]]; check "exits non-zero" $?

rm "$T/runtime/pkg/__main__.py"
python3 "$GRAPH" --units "$T/units" --runtime "$T/runtime" --repo-root "$T" \
    --python python3 >/dev/null 2>&1
rc=$?
[[ "$rc" != 0 ]]; check "a package without __main__.py fails" $?
exit "$fails"
