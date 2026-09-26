#!/usr/bin/env bash
# tests/phase-07.3/test-pi-archive-repo.sh
#
# Self-test for scripts/lib/pi-archive-repo.sh. The fixtures are three tiny real
# debs built with dpkg-deb under `mktemp -d`: one arm64, one all, and one whose
# control Version carries an epoch its file name does not, as the Pi archive's
# firmware-* debs do.
#
# Runs on Linux only. On Linux, missing dpkg-dev is a FAILURE, not a skip: a CI
# runner quietly skipping this suite is exactly the failure it exists to catch.
if [[ "$(uname -s)" != Linux ]]; then
    echo "SKIP: this suite needs Linux (dpkg-deb, dpkg-scanpackages, GNU coreutils)." >&2
    exit 0
fi
set -uo pipefail
for tool in dpkg-deb dpkg-scanpackages python3; do
    command -v "${tool}" >/dev/null || { echo "FAIL: ${tool} not installed (apt-get install dpkg-dev python3-yaml)" >&2; exit 1; }
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILDER="${REPO_ROOT}/scripts/lib/pi-archive-repo.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
PASSED=0
FAILED=0
A="alpha_1.0_arm64.deb"; B="beta_2.0_all.deb"; R="fw-gamma_2.0-1_all.deb"

# mkdeb <name> <version> <arch> <file>
mkdeb() {
    local d="${WORK}/src/$1"
    mkdir -p "${d}/DEBIAN" "${d}/usr/share/doc/$1"
    echo "$1 payload" > "${d}/usr/share/doc/$1/README"
    printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: Test <test@example.invalid>\nDescription: fixture %s\n' \
        "$1" "$2" "$3" "$1" > "${d}/DEBIAN/control"
    dpkg-deb --root-owner-group -Zgzip --build "${d}" "${WORK}/pool/$4" >/dev/null
}
mkdir -p "${WORK}/pool"
mkdeb alpha 1.0 arm64 "${A}"
mkdeb beta 2.0 all "${B}"
mkdeb fw-gamma 1:2.0-1 all "${R}"
cp "${WORK}/pool/${A}" "${WORK}/pool/stray_0.1_all.deb"

sha() { sha256sum "$1" | cut -d' ' -f1; }
# entry <name> <version> <arch> <file>
entry() {
    printf '  - {name: "%s", version: "%s", arch: "%s", filename: "%s", size: %s, sha256: "%s", url: "file:///unused/%s"}\n' \
        "$1" "$2" "$3" "$4" "$(stat -c %s "${WORK}/pool/$4")" "$(sha "${WORK}/pool/$4")" "$4"
}

# setup <case> [alpha version in manifest]: C is the case dir, pool copied into it
setup() {
    C="${WORK}/$1"; mkdir -p "${C}/pool"; cp "${WORK}/pool/"*.deb "${C}/pool/"
    { echo 'pool_base: "file:///unused"'; echo 'packages:'
      entry alpha "${2:-1.0}" arm64 "${A}"; entry beta 2.0 all "${B}"
      echo 'resolve_only:'; entry fw-gamma 1:2.0-1 all "${R}"; } > "${C}/m.yml"
    for f in "${A}" "${B}" "${R}"; do printf '%s\t%s\n' "${f}" "${C}/pool/${f}"; done > "${C}/paths"
    O="${C}/out"
}
run() { OUT="$(bash "${BUILDER}" --manifest "${C}/m.yml" --paths "${C}/paths" --out "${O}" 2>&1)"; RC=$?; }
ok() {
    if [[ $? -eq 0 ]]; then echo "[OK]   $1"; PASSED=$((PASSED + 1))
    else
        echo "[FAIL] $1: rc=${RC:-}"; printf '       %s\n' "${OUT//$'\n'/$'\n'       }"
        FAILED=$((FAILED + 1))
    fi
}

setup builds; run
[[ ${RC} -eq 0 && "$(cd "${O}" && find . -mindepth 1 -printf "%f\n" | LC_ALL=C sort | tr '\n' ' ')" == "Packages SHA256SUMS ${A} ${B} ${R} " ]] &&
    (cd "${O}" && sha256sum --quiet -c SHA256SUMS)
ok "[builds] out holds exactly the three debs, Packages and SHA256SUMS; SHA256SUMS checks"

python3 - "${C}/m.yml" "${O}/Packages" <<'PY'
import sys, yaml
m = yaml.safe_load(open(sys.argv[1]))
want = {e["filename"]: e for e in m["packages"] + m["resolve_only"]}
stanzas = [dict(l.split(": ", 1) for l in s.splitlines() if ": " in l)
           for s in open(sys.argv[2]).read().strip().split("\n\n")]
assert len(stanzas) == 3, len(stanzas)
for s in stanzas:
    e = want[s["Filename"].removeprefix("./")]
    got = (s["Package"], s["Version"], s["Architecture"], int(s["Size"]), s["SHA256"])
    assert got == (e["name"], e["version"], e["arch"], e["size"], e["sha256"]), got
PY
ok "[index-matches-manifest] 3 stanzas; name/version (epoch incl.)/arch/size/sha256 equal the manifest"

setup tampered; echo x >> "${C}/pool/${B}"; run
[[ ${RC} -ne 0 && "${OUT}" == *"${B}"* && ! -e "${O}" ]]
ok "[tampered-source] an appended byte fails, names the deb, leaves no out dir"

setup unmapped; sed -i "/^${B}	/d" "${C}/paths"; run
[[ ${RC} -ne 0 && "${OUT}" == *"${B}"* && ! -e "${O}" ]]
ok "[missing-from-map] a manifest deb absent from the paths map fails, named"

setup extra; printf 'stray_0.1_all.deb\t%s\n' "${C}/pool/stray_0.1_all.deb" >> "${C}/paths"; run
[[ ${RC} -eq 0 && ! -e "${O}/stray_0.1_all.deb" ]] && ! grep -q stray "${O}/Packages"
ok "[extra-not-copied] a stray deb alongside the others never reaches out"

setup stale; mkdir -p "${O}"; echo junk > "${O}/junk"; run
[[ ${RC} -eq 0 && ! -e "${O}/junk" && -f "${O}/Packages" ]]
ok "[stale-out-replaced] a pre-existing out dir is replaced, junk gone"

setup control 9.9; run
[[ ${RC} -ne 0 && "${OUT}" == *"${A}"* && "${OUT}" == *9.9* && ! -e "${O}" ]]
ok "[control-mismatch] manifest version 9.9 vs control 1.0 fails, named"

echo "${PASSED} passed, ${FAILED} failed"
[[ ${FAILED} -eq 0 ]]
