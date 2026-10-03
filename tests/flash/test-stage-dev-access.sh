#!/usr/bin/env bash
# tests/flash/test-stage-dev-access.sh
#
# Self-test for scripts/lib/stage-dev-access.sh and the --dev-access wiring in
# scripts/flash-sd.sh. No card involved: a temp dir stands in for the boot partition.
#
# CONTRACT (DEV implements to this):
#   source scripts/lib/stage-dev-access.sh
#   stage_dev_access <boot_dir> <user> <crypt_hash> <pubkey_file>
#     writes <boot_dir>/userconf.txt as the single line "<user>:<hash>" and
#     <boot_dir>/authorized_keys with the key; returns 0.
#     Returns nonzero, writing neither file, when the pubkey file is missing, is a
#     private key (contains "PRIVATE KEY"), does not begin with ssh-ed25519, ssh-rsa,
#     ecdsa-sha2-* or sk-*, or when the hash does not start with '$'.
#   flash-sd.sh --dev-access <user> <pubkey-file>: the pubkey file is validated during
#     argument parsing, before the block-device check and before any write, and the
#     error message names the file.
# shellcheck disable=SC2016,SC2319
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${REPO_ROOT}/scripts/lib/stage-dev-access.sh"
FLASH="${REPO_ROOT}/scripts/flash-sd.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
PASSED=0; FAILED=0
OUT=""; RC=0
ok() { if [[ $1 -eq 0 ]]; then echo "[OK]   $2"; PASSED=$((PASSED+1)); else echo "[FAIL] $2"; echo "  ${OUT//$'\n'/$'\n'  }"; FAILED=$((FAILED+1)); fi; }

# shellcheck disable=SC1090
source "${LIB}" 2>/dev/null || true
stage() {
    if ! declare -F stage_dev_access >/dev/null; then OUT="stage_dev_access is not defined (${LIB})"; RC=127; return; fi
    OUT="$(stage_dev_access "$@" 2>&1)"; RC=$?
}

ssh-keygen -q -t ed25519 -N '' -C 'qa-test' -f "${WORK}/id" >/dev/null
ssh-keygen -q -t rsa -b 2048 -N '' -C 'qa-test' -f "${WORK}/rsa" >/dev/null
ssh-keygen -q -t ecdsa -N '' -C 'qa-test' -f "${WORK}/ec" >/dev/null
HASH='$6$saltsalt$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'
printf 'hello world\n' > "${WORK}/notakey"
sed 's/^ssh-ed25519/x-ssh-ed25519/' "${WORK}/id.pub" > "${WORK}/prefixed"

B="${WORK}/b1"; mkdir -p "${B}"; stage "${B}" devuser "${HASH}" "${WORK}/id.pub"
[[ ${RC} -eq 0 && "$(cat "${B}/userconf.txt" 2>/dev/null)" == "devuser:${HASH}" ]]; ok $? "[happy] userconf.txt is exactly user:hash"
[[ "$(cat "${B}/authorized_keys" 2>/dev/null)" == "$(cat "${WORK}/id.pub")" ]]; ok $? "[happy] authorized_keys holds the public key"

for k in rsa ec; do
    B="${WORK}/b-${k}"; mkdir -p "${B}"; stage "${B}" devuser "${HASH}" "${WORK}/${k}.pub"
    [[ ${RC} -eq 0 && -f "${B}/authorized_keys" ]]; ok $? "[key-type] ${k} public key is accepted"
done

reject() { # <name> <hash> <keyfile>
    B="${WORK}/r-$1"; mkdir -p "${B}"; stage "${B}" devuser "$2" "$3"
    [[ ${RC} -ne 0 && ${RC} -ne 127 && ! -e "${B}/userconf.txt" && ! -e "${B}/authorized_keys" ]]
    ok $? "[reject] $1: nonzero and nothing written"
}
reject private-key "${HASH}" "${WORK}/id"
reject non-key-file "${HASH}" "${WORK}/notakey"
reject missing-file "${HASH}" "${WORK}/nope.pub"
reject plaintext-hash 'hunter2' "${WORK}/id.pub"
reject bad-prefix "${HASH}" "${WORK}/prefixed"

# flash-sd.sh wiring: static, no device.
OUT="$(bash "${FLASH}" --help 2>&1)"; [[ "${OUT}" == *--dev-access* ]]; ok $? "[flash-usage] --help documents --dev-access"
V="$(grep -n 'verify-flash.py' "${FLASH}" | grep -v '^[0-9]*:#' | tail -n1 | cut -d: -f1)"
S="$(grep -n 'stage_dev_access' "${FLASH}" | head -n1 | cut -d: -f1)"
OUT="verify line=${V:-none}, stage line=${S:-none}"
[[ -n "${V}" && -n "${S}" && "${S}" -gt "${V}" ]]; ok $? "[flash-order] staging is called only after the read-back verify"
head -c 4096 /dev/zero > "${WORK}/img"
OUT="$(bash "${FLASH}" "${WORK}/img" /dev/null --yes --dev-access devuser "${WORK}/nope.pub" 2>&1)"; RC=$?
[[ ${RC} -ne 0 && "${OUT}" == *"${WORK}/nope.pub"* ]]; ok $? "[flash-args] a missing pubkey file is refused up front, naming the file"

echo "${PASSED} passed, ${FAILED} failed"
[[ ${FAILED} -eq 0 ]]
