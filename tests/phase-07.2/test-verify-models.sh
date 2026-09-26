#!/usr/bin/env bash
# tests/phase-07.2/test-verify-models.sh
#
# Self-test for scripts/lib/verify-models.py. Fixtures are tiny files under
# `mktemp -d`; no real model is read.
#
# [placeholder] is the load-bearing case: a TODO digest used to WARN, and all
# four model pins stayed TODO from June to September with every image shipping
# its models unchecked.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFY="${REPO_ROOT}/scripts/lib/verify-models.py"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0

sha() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

# make_tree <root>: two models, one a directory of two files, one a single file
make_tree() {
    mkdir -p "$1/llm" "$1/tts"
    printf 'weights' > "$1/llm/a.bin"
    printf 'more'    > "$1/llm/b.bin"
    printf 'voice'   > "$1/tts/v.onnx"
}

# write_manifest <root> <out> [digest override for llm/b.bin]
write_manifest() {
    local root="$1" out="$2" b_sha="${3:-}"
    [[ -n "${b_sha}" ]] || b_sha="$(sha "${root}/llm/b.bin")"
    cat > "${out}" <<EOF
models:
  llm:
    install_to: "/opt/arlowe/models/llm"
    files:
      - filename: "llm/a.bin"
        sha256: "$(sha "${root}/llm/a.bin")"
      - filename: "llm/b.bin"
        sha256: "${b_sha}"
  tts:
    install_to: "/opt/arlowe/models/tts"
    files:
      - filename: "tts/v.onnx"
        sha256: "$(sha "${root}/tts/v.onnx")"
EOF
}

# expect <name> <rc> <substring or ''> -- <verify-models args...>
expect() {
    local name="$1" want_rc="$2" needle="$3"; shift 4
    local out rc
    out="$(python3 "${VERIFY}" "$@" 2>&1)"
    rc=$?
    if [[ ${rc} -eq ${want_rc} && ( -z "${needle}" || "${out}" == *"${needle}"* ) ]]; then
        echo "[OK]   ${name}"
        PASSED=$((PASSED + 1))
    else
        echo "[FAIL] ${name}: wanted rc=${want_rc}${needle:+ mentioning \"${needle}\"}, got rc=${rc}"
        printf '       %s\n' "${out//$'\n'/$'\n'       }"
        FAILED=$((FAILED + 1))
    fi
}

r="${WORK}/good"; make_tree "${r}"; write_manifest "${r}" "${WORK}/good.yml"
expect "[good] every listed file matches" 0 "" -- --manifest "${WORK}/good.yml" --root "${r}" --exact

r="${WORK}/mismatch"; make_tree "${r}"; write_manifest "${r}" "${WORK}/mismatch.yml"
printf 'tampered' > "${r}/llm/b.bin"
expect "[mismatch] a changed file fails and is named" 1 "llm/b.bin: sha256 mismatch" -- \
    --manifest "${WORK}/mismatch.yml" --root "${r}"

r="${WORK}/missing"; make_tree "${r}"; write_manifest "${r}" "${WORK}/missing.yml"
rm "${r}/tts/v.onnx"
expect "[missing] an absent listed file fails" 1 "tts/v.onnx: missing" -- \
    --manifest "${WORK}/missing.yml" --root "${r}"

r="${WORK}/placeholder"; make_tree "${r}"
write_manifest "${r}" "${WORK}/placeholder.yml" "TODO_SHA256__capture_later"
expect "[placeholder] a TODO digest fails instead of warning" 1 "placeholder digest" -- \
    --manifest "${WORK}/placeholder.yml" --root "${r}"

r="${WORK}/extra"; make_tree "${r}"; write_manifest "${r}" "${WORK}/extra.yml"
printf 'stray' > "${r}/llm/notes.txt"
mkdir -p "${r}/lost+found"; printf 'x' > "${r}/lost+found/f"
expect "[extra-exact] an unlisted file in the shipped tree fails" 1 "llm/notes.txt: not in the manifest" -- \
    --manifest "${WORK}/extra.yml" --root "${r}" --exact
expect "[extra-lookup] without --exact an unlisted file is not this check's business" 0 "" -- \
    --manifest "${WORK}/extra.yml" --root "${r}"

r="${WORK}/one-model"; make_tree "${r}"; write_manifest "${r}" "${WORK}/one.yml"
rm "${r}/llm/a.bin"
expect "[one-model] --model checks only that entry" 0 "" -- \
    --manifest "${WORK}/one.yml" --root "${r}" --model tts

echo
echo "${PASSED} passed, ${FAILED} failed"
(( FAILED == 0 ))
