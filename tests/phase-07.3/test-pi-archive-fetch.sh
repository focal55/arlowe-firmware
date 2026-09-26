#!/usr/bin/env bash
# tests/phase-07.3/test-pi-archive-fetch.sh
#
# Self-test for scripts/lib/pi-archive-fetch.py. Fixtures are three tiny files
# with deb names under `mktemp -d`; fetches use file:// URLs, so no case touches
# the network, and every cache location the helper searches is redirected into
# the work directory.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="${REPO_ROOT}/scripts/lib/pi-archive-fetch.py"

WORK="$(mktemp -d)"
trap 'chmod -R u+w "${WORK}" 2>/dev/null; rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0
A="alpha_1.0_arm64.deb"; B="beta_2.0_all.deb"; R="gamma_3.0_all.deb"

sha() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
size() { wc -c < "$1" | tr -d ' '; }

mkdir -p "${WORK}/origin"
printf 'alpha bytes' > "${WORK}/origin/${A}"
printf 'beta bytes'  > "${WORK}/origin/${B}"
printf 'gamma bytes' > "${WORK}/origin/${R}"

# entry <filename> <url dir> [size override]
entry() {
    local f="$1" s="${3:-$(size "${WORK}/origin/$1")}"
    printf '  - {name: "%s", filename: "%s", size: %s, sha256: "%s", url: "file://%s/%s"}\n' \
        "${f%%_*}" "${f}" "${s}" "$(sha "${WORK}/origin/${f}")" "$2" "${f}"
}

# manifest <out> <url dir> [size override for B]
manifest() {
    { echo 'pool_base: "file:///unused"'
      echo 'packages:'; entry "${A}" "$2"; entry "${B}" "$2" "${3:-}"
      echo 'resolve_only:'; entry "${R}" "$2"; } > "$1"
}

# setup <case>: C is the case dir; D the ARLOWE_PI_ARCHIVE_DIR; S the repo staging dir
setup() {
    C="${WORK}/$1"; D="${C}/dir"; S="${C}/repo/third_party/pi-archive"
    mkdir -p "${D}" "${S}" "${C}/shared" "${C}/xdg"
    MAP="${C}/paths"; manifest "${C}/m.yml" "${WORK}/origin"
}

# run [VAR=value ...]: runs the helper in the case's isolated environment
run() {
    OUT="$(env -u ARLOWE_PI_ARCHIVE_FETCH -u ARLOWE_PI_ARCHIVE_DIR \
        XDG_CACHE_HOME="${C}/xdg" ARLOWE_PI_ARCHIVE_SHARED_CACHE="${C}/shared" "$@" \
        python3 "${HELPER}" --manifest "${C}/m.yml" --repo-root "${C}/repo" --paths-out "${MAP}" 2>&1)"
    RC=$?
}

# ok <name>: records the exit status of the assertion that ran just before it
ok() {
    if [[ $? -eq 0 ]]; then echo "[OK]   $1"; PASSED=$((PASSED + 1))
    else
        echo "[FAIL] $1: rc=${RC}"; printf '       %s\n' "${OUT//$'\n'/$'\n'       }"
        FAILED=$((FAILED + 1))
    fi
}

setup found; cp "${WORK}/origin/"*.deb "${D}/"
run ARLOWE_PI_ARCHIVE_DIR="${D}"
[[ ${RC} -eq 0 && $(wc -l < "${MAP}") -eq 3 ]] && ! grep -qv "^[^	]*	${D}/" "${MAP}"
ok "[found-in-dir] every deb found in ARLOWE_PI_ARCHIVE_DIR, map names each"

setup order; cp "${WORK}/origin/"*.deb "${S}/"; cp "${WORK}/origin/${A}" "${D}/"
run ARLOWE_PI_ARCHIVE_DIR="${D}"
[[ ${RC} -eq 0 ]] && grep -qx "${A}	${D}/${A}" "${MAP}" && grep -qx "${B}	${S}/${B}" "${MAP}"
ok "[search-order] ARLOWE_PI_ARCHIVE_DIR wins over third_party/pi-archive"

setup missing; cp "${WORK}/origin/${A}" "${WORK}/origin/${R}" "${S}/"
run
[[ ${RC} -eq 1 && "${OUT}" == *"FAIL ${B}"* && "${OUT}" == *ARLOWE_PI_ARCHIVE_FETCH=1* &&
   -z "$(find "${C}/xdg" "${C}/shared" -type f)" ]]
ok "[missing-no-fetch] an absent deb fails, names the opt-in, fetches nothing"

setup digest; cp "${WORK}/origin/"*.deb "${S}/"; printf 'x' >> "${S}/${B}"
run
[[ ${RC} -eq 1 && "${OUT}" == *"FAIL ${B}"* && "${OUT}" == *"$(sha "${WORK}/origin/${B}")"* &&
   "${OUT}" == *"$(sha "${S}/${B}")"* ]]
ok "[digest-mismatch] changed bytes fail with expected and actual sha256"

setup size; cp "${WORK}/origin/"*.deb "${S}/"; manifest "${C}/m.yml" "${WORK}/origin" 999
run
[[ ${RC} -eq 1 && "${OUT}" == *"FAIL ${B}"*size* ]]
ok "[size-mismatch] a wrong size fails and names the deb"

setup stale; cp "${WORK}/origin/${A}" "${S}/"; echo "stale	/nowhere" > "${MAP}"
run
[[ ${RC} -eq 1 && ! -e "${MAP}" ]]
ok "[stale-map-removed] a failing run leaves no paths map behind"

# The shared cache stands in for /var/cache, which an unprivileged user cannot
# write. Root ignores chmod, so as root the case only asserts a clean fetch.
setup fetch; chmod 555 "${C}/shared"
run ARLOWE_PI_ARCHIVE_FETCH=1
X="${C}/xdg/arlowe-build/pi-archive"
if [[ $(id -u) -eq 0 ]]; then
    [[ ${RC} -eq 0 && -z "$(find "${C}" -name "*.part")" ]]
else
    [[ ${RC} -eq 0 && -f "${X}/${A}" && -f "${X}/${B}" && -f "${X}/${R}" &&
       -z "$(find "${C}" -name "*.part")" ]] && grep -qx "${B}	${X}/${B}" "${MAP}"
fi
ok "[fetch] opt-in fetch falls back to the writable XDG cache, leaves no .part"

setup badfetch; mkdir -p "${C}/origin"; cp "${WORK}/origin/"*.deb "${C}/origin/"
printf 'not beta' > "${C}/origin/${B}"
{ echo 'packages:'; entry "${A}" "${C}/origin"; entry "${B}" "${C}/origin"
  echo 'resolve_only:'; entry "${R}" "${C}/origin"; } > "${C}/m.yml"
run ARLOWE_PI_ARCHIVE_FETCH=1
[[ ${RC} -eq 1 && "${OUT}" == *"FAIL ${B}"* && -z "$(find "${C}/shared" "${C}/xdg" -name "${B}*")" ]]
ok "[fetch-bad-bytes] a fetched deb that fails its pin never gets its final name"

setup ro; cp "${WORK}/origin/"*.deb "${S}/"
run
[[ ${RC} -eq 0 ]] && grep -qx "${R}	${S}/${R}" "${MAP}"
ok "[resolve-only-covered] the resolve_only deb is mapped like any package"
printf 'x' >> "${S}/${R}"; run
[[ ${RC} -eq 1 && "${OUT}" == *"FAIL ${R}"* ]]
ok "[resolve-only-covered] and a changed resolve_only deb fails"

setup empty; printf 'packages: []\nresolve_only: []\n' > "${C}/m.yml"
run
[[ ${RC} -eq 2 && "${OUT}" == *"[pi-archive]"*"no debs"* ]]
ok "[empty-manifest] a manifest naming no debs could not run (exit 2)"

echo ""
echo "${PASSED} passed, ${FAILED} failed"
[[ ${FAILED} -eq 0 ]]
