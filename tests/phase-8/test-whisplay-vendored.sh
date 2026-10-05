#!/usr/bin/env bash
# Failing-first tests for #289: the Whisplay display driver is vendored in the
# repo, pinned by sha256, documented in ADR 0014, and the build fails hard
# without it.
#
# CONTRACT the implementation must meet
#
# 1. third_party/whisplay-driver/WhisPlay.py and LICENSE are tracked by git and
#    not matched by any ignore rule. .gitignore still ignores
#    install_wm8960_drive.sh and the WM8960-Audio-HAT* bundle.
#
# 2. third_party/whisplay-driver/PROVENANCE.md carries these lines, each alone
#    on its line, hex in lower case:
#        upstream-commit: <40 hex>
#        sha256 WhisPlay.py: <64 hex>
#        sha256 LICENSE: <64 hex>
#    The two sha256 values equal the sha256 of the committed files.
#
# 3. docs/architecture/0014-vendor-whisplay-driver.md contains all three values
#    verbatim and headings (any level, case-insensitive) containing: Context,
#    Decision, Alternatives, License obligations, Provenance, Exclusions,
#    Update procedure, Audit checklist. The Exclusions section mentions WM8960.
#
# 4. SEAM for check 4 of scripts/verify-third-party.sh: when the environment
#    variable ARLOWE_VERIFY_ONLY=4 is set, the script runs check 4 and nothing
#    else (no manifest parse, no network, no other check) and exits 0 when check
#    4 passes, 1 when it fails. REPO_ROOT keeps resolving from the script's own
#    location, so the tests run a copy of the script inside a temp tree. Check 4
#    reads only <REPO_ROOT>/third_party/whisplay-driver/{WhisPlay.py,LICENSE},
#    compares both against the sha256 values in that tree's PROVENANCE.md, prints
#    a line containing "[OK]" and "WhisPlay" on success and "[FAIL]" and
#    "WhisPlay" on failure. ARLOWE_WHISPLAY_SRC is ignored.
#
# 5. The vendoring block of pi-gen/stage-arlowe/01-runtime/00-run-chroot.sh is
#    the text from the line containing 'vendoring WhisPlay driver"' up to
#    (excluding) the next line starting with '# ---'. It derives its source from
#    ${REPO_ROOT}, runs under set -euo pipefail, and exits non-zero when
#    WhisPlay.py or LICENSE is missing. README.md and PROVENANCE.md stay
#    optional. The test executes the block with install(1) stubbed and
#    /opt/arlowe rewritten to a temp dir.
#
# 6. ARLOWE_WHISPLAY_SRC appears nowhere under scripts/, pi-gen/,
#    docs/operations/ or in third_party/whisplay-driver/INSTALL.md.
# The helpers are invoked through check "$@", which shellcheck cannot see.
# shellcheck disable=SC2317,SC2329
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT
DRV=third_party/whisplay-driver
PROV="${REPO_ROOT}/${DRV}/PROVENANCE.md"
ADR="${REPO_ROOT}/docs/architecture/0014-vendor-whisplay-driver.md"
CHROOT="${REPO_ROOT}/pi-gen/stage-arlowe/01-runtime/00-run-chroot.sh"
VERIFY="${REPO_ROOT}/scripts/verify-third-party.sh"
fails=0
ok() { echo "[OK] $1"; }
fail() { echo "[FAIL] $1"; if [[ -n "${2:-}" ]]; then echo "  ${2//$'\n'/$'\n'  }"; fi; fails=1; }
check() { local name=$1; shift; local out; if out="$("$@" 2>&1)"; then ok "$name"; else fail "$name" "$out"; fi; }

sha() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
prov() { sed -n "s/^$1: \([0-9a-f]\{$2\}\)\$/\1/p" "${PROV}" 2>/dev/null | head -n1; }
COMMIT="$(prov upstream-commit 40)"
SHA_PY="$(prov 'sha256 WhisPlay.py' 64)"
SHA_LIC="$(prov 'sha256 LICENSE' 64)"

tracked_and_not_ignored() {
    local f=$1 rc
    git -C "${REPO_ROOT}" ls-files --error-unmatch "${DRV}/${f}" >/dev/null 2>&1 \
        || { echo "${DRV}/${f} is not tracked by git"; return 1; }
    git -C "${REPO_ROOT}" check-ignore -q "${DRV}/${f}"; rc=$?
    [[ ${rc} -eq 1 ]] || { echo "${DRV}/${f} matches an ignore rule"; return 1; }
}
for f in WhisPlay.py LICENSE; do check "${f} is tracked and not ignored" tracked_and_not_ignored "${f}"; done

recorded() {
    [[ -n "${COMMIT}" ]] || { echo "PROVENANCE.md has no 'upstream-commit: <40 hex>' line"; return 1; }
    [[ -n "$2" ]] || { echo "PROVENANCE.md has no 'sha256 $1: <64 hex>' line"; return 1; }
    [[ -f "${REPO_ROOT}/${DRV}/$1" ]] || { echo "${DRV}/$1 is absent"; return 1; }
    [[ "$(sha "${REPO_ROOT}/${DRV}/$1")" == "$2" ]] || { echo "sha256 of $1 differs from PROVENANCE.md ($2)"; return 1; }
}
check "WhisPlay.py sha256 matches PROVENANCE.md" recorded WhisPlay.py "${SHA_PY}"
check "LICENSE sha256 matches PROVENANCE.md" recorded LICENSE "${SHA_LIC}"

adr_complete() {
    [[ -f "${ADR}" ]] || { echo "docs/architecture/0014-vendor-whisplay-driver.md does not exist"; return 1; }
    local miss=0 h v
    for h in Context Decision Alternatives "License obligations" Provenance Exclusions "Update procedure" "Audit checklist"; do
        grep -Eiq "^#+ .*${h}" "${ADR}" || { echo "ADR has no heading containing '${h}'"; miss=1; }
    done
    awk 'tolower($0) ~ /^#+ .*exclusions/{p=1; next} p&&/^#/{exit} p' "${ADR}" | grep -q WM8960 \
        || { echo "ADR Exclusions section does not mention WM8960"; miss=1; }
    for v in "${COMMIT}" "${SHA_PY}" "${SHA_LIC}"; do
        if [[ -z "${v}" ]] || ! grep -Fq "${v}" "${ADR}"; then echo "ADR does not contain PROVENANCE value '${v}'"; miss=1; fi
    done
    return "${miss}"
}
check "ADR 0014 has the required sections and the pinned values" adr_complete

# --- check 4 via the ARLOWE_VERIFY_ONLY=4 seam, in a temp copy of the tree ---
mktree() {
    local t="${WORK}/$1"
    mkdir -p "${t}/scripts" "${t}/${DRV}"
    cp "${VERIFY}" "${t}/scripts/verify-third-party.sh"
    cp "${PROV}" "${t}/${DRV}/PROVENANCE.md" 2>/dev/null
    cp "${REPO_ROOT}/${DRV}/WhisPlay.py" "${REPO_ROOT}/${DRV}/LICENSE" "${t}/${DRV}/" 2>/dev/null
    echo "${t}"
}
# run4 TREE [ENV=VAL...]: sets RC and OUT.
run4() { local t=$1; shift; OUT="$(env ARLOWE_VERIFY_ONLY=4 "$@" bash "${t}/scripts/verify-third-party.sh" 2>&1)"; RC=$?; }
expect_pass() { [[ ${RC} -eq 0 && "${OUT}" == *"[OK]"*WhisPlay* ]] || { echo "rc=${RC}, want 0 with an [OK] WhisPlay line"; echo "${OUT}" | tail -5; return 1; }; }
expect_fail() { [[ ${RC} -eq 1 && "${OUT}" == *"[FAIL]"*WhisPlay* ]] || { echo "rc=${RC}, want 1 with a [FAIL] WhisPlay line"; echo "${OUT}" | tail -5; return 1; }; }

T="$(mktree ok)"; run4 "${T}"
check "check 4 passes on the committed files" expect_pass

T="$(mktree tamper-py)"; printf '\n# tampered\n' >> "${T}/${DRV}/WhisPlay.py"; run4 "${T}"
check "check 4 fails on a tampered WhisPlay.py" expect_fail

T="$(mktree tamper-lic)"; printf '\ntampered\n' >> "${T}/${DRV}/LICENSE"; run4 "${T}"
check "check 4 fails on a tampered LICENSE" expect_fail

T="$(mktree no-py)"; rm -f "${T:?}/${DRV:?}/WhisPlay.py"; run4 "${T}"
check "check 4 fails when WhisPlay.py is absent" expect_fail

T="$(mktree no-lic)"; rm -f "${T:?}/${DRV:?}/LICENSE"; run4 "${T}"
check "check 4 fails when LICENSE is absent" expect_fail

# A valid-looking override dir must not rescue a tampered in-repo file ...
mkdir -p "${WORK}/override"
cp "${REPO_ROOT}/${DRV}/WhisPlay.py" "${REPO_ROOT}/${DRV}/LICENSE" "${WORK}/override/" 2>/dev/null
T="$(mktree override-cannot-rescue)"; printf '\n# tampered\n' >> "${T}/${DRV}/WhisPlay.py"
run4 "${T}" "ARLOWE_WHISPLAY_SRC=${WORK}/override"
check "ARLOWE_WHISPLAY_SRC pointing at good files does not rescue a tampered in-repo file" expect_fail

# ... and must not break a good in-repo file either.
mkdir -p "${WORK}/other"; printf 'class Other: pass\n' > "${WORK}/other/WhisPlay.py"; printf 'x\n' > "${WORK}/other/LICENSE"
T="$(mktree override-cannot-break)"; run4 "${T}" "ARLOWE_WHISPLAY_SRC=${WORK}/other"
check "ARLOWE_WHISPLAY_SRC pointing at different files does not change the verdict" expect_pass

# --- chroot vendoring block, executed with install(1) stubbed ---
chroot_case() { # name want(zero|nonzero) files...
    local name=$1 want=$2; shift 2
    local t="${WORK}/chroot-${name}" f out rc
    mkdir -p "${t}/${DRV}"
    for f in "$@"; do echo content > "${t}/${DRV}/${f}"; done
    awk '/vendoring WhisPlay driver"/{p=1} p&&/^# ---/{exit} p' "${CHROOT}" | sed "s#/opt/arlowe#${t}/dst#g" > "${t}/block.sh"
    [[ -s "${t}/block.sh" ]] || { echo "vendoring block not found in 00-run-chroot.sh"; return 1; }
    out="$(bash -c '
        set -euo pipefail
        REPO_ROOT=$1
        install() {
            local a=() d=0; while [[ $# -gt 0 ]]; do case $1 in -o|-g|-m) shift 2;; -d) d=1; shift;; *) a+=("$1"); shift;; esac; done
            if [[ ${d} -eq 1 ]]; then mkdir -p "${a[@]}"; else cp "${a[0]}" "${a[1]}"; fi
        }
        source "$2"
    ' _ "${t}" "${t}/block.sh" 2>&1)"; rc=$?
    if [[ "${want}" == zero ]]; then
        [[ ${rc} -eq 0 ]] || { echo "rc=${rc}, want 0"; echo "${out}"; return 1; }
    else
        [[ ${rc} -ne 0 ]] || { echo "rc=0, want non-zero; output was:"; echo "${out}"; return 1; }
    fi
}
check "chroot vendoring succeeds with all four files" chroot_case all zero WhisPlay.py LICENSE README.md PROVENANCE.md
check "chroot vendoring succeeds without the optional README.md and PROVENANCE.md" chroot_case optional zero WhisPlay.py LICENSE
check "chroot vendoring exits non-zero when WhisPlay.py is missing" chroot_case no-py nonzero LICENSE README.md PROVENANCE.md
check "chroot vendoring exits non-zero when LICENSE is missing" chroot_case no-lic nonzero WhisPlay.py README.md PROVENANCE.md

# --- no residue of the out-of-repo source ---
no_src_var() {
    local hits
    hits="$(git -C "${REPO_ROOT}" grep -n ARLOWE_WHISPLAY_SRC -- scripts pi-gen docs/operations "${DRV}/INSTALL.md" | cut -c1-120)"
    [[ -z "${hits}" ]] || { echo "${hits}"; return 1; }
}
check "ARLOWE_WHISPLAY_SRC is gone from scripts, pi-gen, runbooks and INSTALL.md" no_src_var

# --- .gitignore ---
gitignore_ok() {
    local gi="${REPO_ROOT}/.gitignore" bad=0 p
    for p in WhisPlay.py LICENSE; do
        if grep -Eq "^/?${DRV}/${p}\$" "${gi}"; then echo ".gitignore still lists ${DRV}/${p}"; bad=1; fi
    done
    grep -Fxq "${DRV}/install_wm8960_drive.sh" "${gi}" || { echo ".gitignore no longer ignores install_wm8960_drive.sh"; bad=1; }
    grep -Fxq "${DRV}/WM8960-Audio-HAT*" "${gi}" || { echo ".gitignore no longer ignores the WM8960 bundle"; bad=1; }
    return "${bad}"
}
check ".gitignore frees WhisPlay.py and LICENSE and still ignores the WM8960 bundle" gitignore_ok

exit "${fails}"
