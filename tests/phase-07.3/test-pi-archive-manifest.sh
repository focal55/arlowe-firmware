#!/usr/bin/env bash
# tests/phase-07.3/test-pi-archive-manifest.sh
#
# Self-test for the attribution rules in scripts/lib/pi-archive-manifest.py.
# Every fixture is synthesized under `mktemp -d`; no archive is contacted.
#
# The rules decide which installed packages only the Pi archive supplies and
# therefore must be pinned. [different-both] is the load-bearing case: a
# name/version both archives carry with different bytes is resolved by apt's
# tie-breaking, which is not a pin.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GEN="${REPO_ROOT}/scripts/lib/pi-archive-manifest.py"
POOL="http://pi.example/debian"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0

hex64() { python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$1"; }

# stanza <name> <version> <arch> <filename> <sha-seed>
stanza() {
    printf 'Package: %s\nVersion: %s\nArchitecture: %s\nFilename: %s\nSize: %s\nSHA256: %s\nDescription: fixture\n continuation line\n\n' \
        "$1" "$2" "$3" "$4" "${#5}000" "$(hex64 "$5")"
}

# make_fixtures <dir>: pi/Packages, deb/Packages, kernel.yml, ref.txt (installed set)
make_fixtures() {
    local d="$1"
    mkdir -p "${d}/pi" "${d}/deb"
    {
        stanza pionly-a 1.0 arm64 pool/main/p/pionly-a/pionly-a_1.0_arm64.deb pa
        stanza pionly-all 2.0 all pool/main/p/pionly-all/pionly-all_2.0_all.deb pall
        stanza epochpkg 1:1.2.3-1+rpt1 arm64 pool/main/e/epochpkg/epochpkg_1.2.3-1+rpt1_arm64.deb ep
        stanza shared-same 3.0 arm64 pool/main/s/shared-same/shared-same_3.0_arm64.deb same
        stanza shared-diff 4.0 arm64 pool/main/s/shared-diff/shared-diff_4.0_arm64.deb diff-pi
        stanza linux-kbuild-6.12.96+rpt 1:6.12.96-1+rpt1 arm64 \
            pool/main/l/linux/linux-kbuild-6.12.96+rpt_6.12.96-1+rpt1_arm64.deb kb
    } > "${d}/pi/Packages"
    {
        stanza debonly 5.0 arm64 pool/main/d/debonly/debonly_5.0_arm64.deb donly
        stanza shared-same 3.0 arm64 pool/main/s/shared-same/shared-same_3.0_arm64.deb same
        stanza shared-diff 4.0 arm64 pool/main/s/shared-diff/shared-diff_4.0_arm64.deb diff-deb
    } > "${d}/deb/Packages"
    cat > "${d}/kernel.yml" <<'EOF'
kernel:
  deb_version: "6.12.96-1+rpt1"
  debs:
    - filename: "linux-image-6.12.96+rpt-rpi-2712_6.12.96-1+rpt1_arm64.deb"
    - filename: "linux-kbuild-6.12.96+rpt_6.12.96-1+rpt1_arm64.deb"
EOF
    printf '%s\n' \
        $'pin\tthird_party/x/y.deb\tabc' \
        $'pkg\tpionly-a\t1.0\tarm64' \
        $'pkg\tpionly-all\t2.0\tall' \
        $'pkg\tepochpkg\t1:1.2.3-1+rpt1\tarm64' \
        $'pkg\tdebonly\t5.0\tarm64' \
        $'pkg\tshared-same\t3.0\tarm64' \
        $'pkg\taxclhost\t3.10.2\tall' \
        $'pkg\tlinux-image-6.12.96+rpt-rpi-2712\t1:6.12.96-1+rpt1\tarm64' \
        $'pkg\tlinux-kbuild-6.12.96+rpt\t1:6.12.96-1+rpt1\tarm64' \
        > "${d}/ref.txt"
}

F="${WORK}/fx"
make_fixtures "${F}"

# gen <ref> <out> [extra args...]: run generate against the shared fixtures
gen() {
    local ref="$1" out="$2"; shift 2
    python3 "${GEN}" generate --installed-reference "${ref}" \
        --pi-list "${F}/pi/Packages" --debian-list "${F}/deb/Packages" \
        --kernel-manifest "${F}/kernel.yml" --pool-base "${POOL}" --out "${out}" "$@"
}

record() {
    if [[ "$2" == ok ]]; then echo "[OK]   $1"; PASSED=$((PASSED + 1))
    else echo "[FAIL] $1: $3"; FAILED=$((FAILED + 1)); fi
}

# expect_rc <name> <rc> <needle or ''> <ref> [extra args...]
expect_rc() {
    local name="$1" want="$2" needle="$3" ref="$4"; shift 4
    local out rc
    out="$(gen "${ref}" "${WORK}/scratch.yml" "$@" 2>&1)"; rc=$?
    if [[ ${rc} -eq ${want} && ( -z "${needle}" || "${out}" == *"${needle}"* ) ]]; then
        record "${name}" ok
    else
        record "${name}" bad "wanted rc=${want}${needle:+ naming \"${needle}\"}, got rc=${rc}: ${out}"
    fi
}

# expect_py <name> <python asserting on `m` (the loaded manifest) and `text`>
expect_py() {
    local out
    if out="$(python3 - "${GOOD}" "$2" 2>&1 <<'PY'
import sys, yaml
text = open(sys.argv[1]).read()
m = yaml.safe_load(text)
by = {e["name"]: e for e in m["packages"]}
# An absence check against an empty manifest proves nothing.
assert "pionly-a" in by, "the baseline run produced no manifest"
exec(sys.argv[2])
PY
)"; then record "$1" ok; else record "$1" bad "${out}"; fi
}

GOOD="${WORK}/good.yml"
gen "${F}/ref.txt" "${GOOD}" --allow-local axclhost > "${WORK}/good.log" 2>&1 \
    || echo "       (baseline run failed: $(cat "${WORK}/good.log"))"
[[ -s "${GOOD}" ]] || printf 'packages: []\n' > "${GOOD}"

expect_py "[pi-only] arm64 and arch:all Pi-only packages are pinned from their stanzas" '
a, al = by["pionly-a"], by["pionly-all"]
assert a["url"] == "http://pi.example/debian/pool/main/p/pionly-a/pionly-a_1.0_arm64.deb", a
assert a["filename"] == "pionly-a_1.0_arm64.deb" and a["arch"] == "arm64", a
assert a["size"] == 2000 and len(a["sha256"]) == 64, a
assert al["arch"] == "all" and al["url"].endswith("/pionly-all_2.0_all.deb"), al'

expect_py "[epoch] version keeps the epoch, filename does not" '
e = by["epochpkg"]
assert e["version"] == "1:1.2.3-1+rpt1", e
assert e["filename"] == "epochpkg_1.2.3-1+rpt1_arm64.deb", e'

expect_py "[debian-only] a Debian-only package is left to the snapshot" '
assert "debonly" not in by, by.keys()'

expect_py "[identical-both] identical bytes in both archives are left to the snapshot" '
assert "shared-same" not in by, by.keys()'

cp "${F}/ref.txt" "${WORK}/diff.txt"
printf 'pkg\tshared-diff\t4.0\tarm64\n' >> "${WORK}/diff.txt"
expect_rc "[different-both] same name/version with different bytes fails and is named" \
    1 "shared-diff" "${WORK}/diff.txt" --allow-local axclhost

expect_rc "[local-allowlist] an allow-listed local package passes" 0 "" \
    "${F}/ref.txt" --allow-local axclhost
expect_py "[local-allowlist] and is absent from the output" '
assert "axclhost" not in by, by.keys()'
expect_rc "[local-allowlist] without the flag it fails and is named" 1 "axclhost" "${F}/ref.txt"

expect_py "[kernel-excluded] kernel packages are pinned elsewhere, not here" '
assert not [n for n in by if n.startswith("linux-")], by.keys()'

awk -F'\t' -v OFS='\t' '$2 == "linux-kbuild-6.12.96+rpt" { $3 = "1:6.12.109-1+rpt1" } 1' \
    "${F}/ref.txt" > "${WORK}/kmis.txt"
expect_rc "[kernel-mismatch] a kernel package off the kernel pin fails" \
    1 "linux-kbuild-6.12.96+rpt" "${WORK}/kmis.txt" --allow-local axclhost

cp "${F}/ref.txt" "${WORK}/armhf.txt"
printf 'pkg\tlibfoo\t1.0\tarmhf\n' >> "${WORK}/armhf.txt"
expect_rc "[armhf] an installed armhf package fails" 1 "libfoo" "${WORK}/armhf.txt" --allow-local axclhost

printf 'pkg\tdebonly\t5.0\tarm64\n' > "${WORK}/zero.txt"
expect_rc "[zero-entries] an installed set with nothing Pi-only fails" 1 "" "${WORK}/zero.txt"

gen "${F}/ref.txt" "${WORK}/again.yml" --allow-local axclhost > /dev/null 2>&1
expect_py "[format-and-determinism] one flow mapping per entry, each carrying a pin" '
lines = [l for l in text.splitlines() if l.startswith("  - {")]
assert len(m["packages"]) == 3 and len(lines) == 3, (len(m["packages"]), lines)
assert m["resolve_only"] == [], m
import re
for p in m["packages"]:
    assert p["filename"] and re.fullmatch("[0-9a-f]{64}", p["sha256"]), p'
if cmp -s "${GOOD}" "${WORK}/again.yml"; then
    record "[format-and-determinism] two runs are byte-identical" ok
else
    record "[format-and-determinism] two runs are byte-identical" bad "outputs differ"
fi

echo
echo "${PASSED} passed, ${FAILED} failed"
(( FAILED == 0 ))
