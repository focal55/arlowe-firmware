#!/usr/bin/env bash
# tests/phase-07.3/test-pi-archive-committed.sh
#
# Holds the committed third_party/pi-archive/manifest.yml to the build it came
# from. [real-build] is the SC1 tie: every pinned package must be a pkg row of
# docs/operations/phase-07.2-inputs.reference at the same name, version and arch,
# so the manifest is a real build's resolution, never a typed list. A pin bump
# re-records that reference in the same change, so the case stays permanent.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="${REPO_ROOT}/third_party/pi-archive/manifest.yml"
REFERENCE="${REPO_ROOT}/docs/operations/phase-07.2-inputs.reference"
KERNEL="${REPO_ROOT}/third_party/kernel/manifest.yml"

PASSED=0
FAILED=0

# check <name> <python asserting on m, text, pkgs, ro, ref_rows>
check() {
    local out
    if out="$(python3 - "${MANIFEST}" "${REFERENCE}" "${KERNEL}" "$2" 2>&1 <<'PY'
import re, sys, yaml
text = open(sys.argv[1]).read()
m = yaml.safe_load(text)
pkgs, ro = m["packages"], m["resolve_only"]
ref_rows = set()
for line in open(sys.argv[2]):
    f = line.rstrip("\n").split("\t")
    if f[0] == "pkg":
        ref_rows.add((f[1], f[2], f[3]))
kernel = yaml.safe_load(open(sys.argv[3]))
exec(sys.argv[4])
PY
)"; then echo "[OK]   $1"; PASSED=$((PASSED + 1))
    else echo "[FAIL] $1: ${out##*$'\n'}"; FAILED=$((FAILED + 1)); fi
}

check "[parses] pool_base, a non-empty packages list and a resolve_only list" '
assert isinstance(m["pool_base"], str) and m["pool_base"], "pool_base"
assert isinstance(pkgs, list) and pkgs, "packages is empty"
assert isinstance(ro, list), "resolve_only is not a list"'

check "[floor] at least 85 packages, so a truncated generation cannot pass" '
assert len(pkgs) >= 85, "only %d packages" % len(pkgs)'

check "[fields] every entry is complete and its url points into the pool" '
for e in pkgs + ro:
    n = e.get("name")
    assert isinstance(n, str) and n and isinstance(e.get("version"), str), e
    assert e.get("arch") in ("arm64", "all"), (n, e.get("arch"))
    fn = e.get("filename")
    assert isinstance(fn, str) and fn.endswith(".deb") and ":" not in fn and "/" not in fn, (n, fn)
    assert type(e.get("size")) is int and e["size"] > 0, (n, e.get("size"))
    assert re.fullmatch("[0-9a-f]{64}", str(e.get("sha256"))), (n, e.get("sha256"))
    u = e.get("url", "")
    assert u.startswith(m["pool_base"] + "/pool/") and u.endswith("/" + fn), (n, u)'

check "[unique] filenames across both sections, names within packages" '
fns = [e["filename"] for e in pkgs + ro]
assert len(fns) == len(set(fns)), sorted(f for f in fns if fns.count(f) > 1)
names = [e["name"] for e in pkgs]
assert len(names) == len(set(names)), sorted(n for n in names if names.count(n) > 1)'

check "[one-line] one line per entry, so a diff shows one line per bump" '
n = len(re.findall(r"(?m)^  - \{", text))
assert n == len(pkgs) + len(ro), "%d entry lines for %d entries" % (n, len(pkgs) + len(ro))'

check "[kernel-disjoint] no kernel package is pinned twice" '
kn = {d["filename"].split("_", 1)[0] for d in kernel["kernel"]["debs"]}
assert kn, "no kernel debs read"
both = kn & {e["name"] for e in pkgs + ro}
assert not both, sorted(both)'

check "[real-build] every package is a pkg row of the committed reference" '
missing = [(e["name"], e["version"], e["arch"]) for e in pkgs
           if (e["name"], e["version"], e["arch"]) not in ref_rows]
assert not missing, "not in the reference: %s" % missing'

check "[prestera] firmware-marvell-prestera is resolve-only and never installed" '
assert "firmware-marvell-prestera" in {e["name"] for e in ro}, "absent from resolve_only"
assert not any(r[0] == "firmware-marvell-prestera" for r in ref_rows), "it is a pkg row"'

echo
echo "${PASSED} passed, ${FAILED} failed"
(( FAILED == 0 ))
