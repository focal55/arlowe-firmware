#!/usr/bin/env bash
# tests/security/test-arlowe-userconf.sh
#
# Self-test for pi-gen/stage-arlowe/03-firstboot/files/arlowe-userconf and its unit.
# Runs unprivileged on macOS and Linux CI; nothing touches the real /boot or /home.
#
# TEST SEAM (arlowe-userconf must implement exactly this):
#   ARLOWE_BOOT_DIR   dir holding userconf.txt and authorized_keys  (default /boot/firmware)
#   ARLOWE_CONFIG     paired marker; if this file exists the unit is paired
#                     (default /etc/arlowe/config.yml)
#   ARLOWE_HOME_ROOT  parent of home dirs; the user's home is ${ARLOWE_HOME_ROOT}/<user>
#                     (default /home)
#   Commands are resolved via PATH, so the test substitutes stubs for useradd,
#   chpasswd, usermod, id, getent and chown. Each logs its argv, one line per call,
#   to ${STUB_LOG}/<cmd>.log. The useradd stub creates ${ARLOWE_HOME_ROOT}/<user>
#   and records the user; the id stub succeeds only for recorded users; `getent passwd
#   <user>` reports home ${ARLOWE_HOME_ROOT}/<user>. The chown stub does not change
#   ownership; the script must call chown with an argument starting "<user>" (e.g.
#   "devuser:devuser") on the .ssh dir and on authorized_keys.
#   Modes are asserted on the real files, so the script must chmod 0700 / 0600.
#   Refusal on a paired unit: exactly one stdout/stderr line naming "arlowe-userconf"
#   and containing "refus".
# shellcheck disable=SC2016,SC2319
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/pi-gen/stage-arlowe/03-firstboot/files/arlowe-userconf"
UNIT="${REPO_ROOT}/pi-gen/stage-arlowe/03-firstboot/files/arlowe-userconf.service"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
PASSED=0
FAILED=0
OUT=""
RC=0

ssh-keygen -q -t ed25519 -N '' -C 'qa-test' -f "${WORK}/k1" >/dev/null
ssh-keygen -q -t ed25519 -N '' -C 'qa-test2' -f "${WORK}/k2" >/dev/null
KEY1="$(cat "${WORK}/k1.pub")"
KEY2="$(cat "${WORK}/k2.pub")"
HASH='$6$saltsalt$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'

BIN="${WORK}/bin"
mkdir -p "${BIN}"
mk_stub() { # <name> <body>
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "${STUB_LOG}/%s.log"\n%s\n' "$1" "$2" > "${BIN}/$1"
    chmod +x "${BIN}/$1"
}
mk_stub useradd 'for a; do u="$a"; done; mkdir -p "${ARLOWE_HOME_ROOT}/${u}"; echo "${u}" >> "${STUB_LOG}/users"'
mk_stub chpasswd 'cat >> "${STUB_LOG}/chpasswd.stdin"'
mk_stub usermod 'exit 0'
mk_stub chown 'exit 0'
mk_stub id 'for a; do u="$a"; done; grep -qx "${u}" "${STUB_LOG}/users" 2>/dev/null'
mk_stub getent 'if [[ "$1" == passwd ]]; then echo "$2:x:1000:1000::${ARLOWE_HOME_ROOT}/$2:/bin/bash"; else exit 0; fi'

mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
count() { if [[ -f "$1" ]]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

# fresh <case>: new sandbox; sets B (boot), H (home root), C (config), L (stub log).
fresh() {
    D="${WORK}/$1"; B="${D}/boot"; H="${D}/home"; C="${D}/etc/config.yml"; L="${D}/log"
    mkdir -p "${B}" "${H}" "${L}" "${D}/etc"
}
userconf() { printf '%s:%s\n' devuser "${HASH}" > "${B}/userconf.txt"; }
run() {
    OUT="$(PATH="${BIN}:${PATH}" STUB_LOG="${L}" ARLOWE_BOOT_DIR="${B}" ARLOWE_CONFIG="${C}" \
        ARLOWE_HOME_ROOT="${H}" bash "${SCRIPT}" 2>&1)"
    RC=$?
}
check() { # <name> <status of the assertion just evaluated>
    if [[ $2 -eq 0 ]]; then echo "[OK]   $1"; PASSED=$((PASSED + 1))
    else echo "[FAIL] $1 (rc=${RC})"; printf '       %s\n' "${OUT//$'\n'/$'\n'       }"; FAILED=$((FAILED + 1)); fi
}
AK() { echo "${H}/devuser/.ssh/authorized_keys"; }

fresh both; userconf; printf '%s\n' "${KEY1}" > "${B}/authorized_keys"; run
[[ ${RC} -eq 0 && "$(count "${L}/useradd.log")" == 1 && "$(cat "${L}/chpasswd.stdin" 2>/dev/null)" == "devuser:${HASH}" ]]
check "[unpaired] userconf + key: rc 0, user created, hash set" $?
[[ "$(cat "$(AK)" 2>/dev/null)" == "${KEY1}" ]]; check "[unpaired] key installed in the user's ~/.ssh/authorized_keys" $?
[[ "$(mode "${H}/devuser/.ssh" 2>/dev/null)" == 700 && "$(mode "$(AK)" 2>/dev/null)" == 600 ]]
check "[unpaired] .ssh is 0700 and authorized_keys is 0600" $?
grep -q '^devuser' "${L}/chown.log" 2>/dev/null && grep -q '\.ssh' "${L}/chown.log" 2>/dev/null
check "[unpaired] .ssh and authorized_keys are chowned to the user" $?
[[ ! -e "${B}/userconf.txt" && ! -e "${B}/authorized_keys" ]]; check "[unpaired] both FAT files are deleted" $?

fresh rerun; userconf; printf '%s\n%s\n' "${KEY1}" "${KEY2}" > "${B}/authorized_keys"; run
userconf; printf '%s\n' "${KEY1}" > "${B}/authorized_keys"; run
[[ ${RC} -eq 0 && "$(grep -cxF "${KEY1}" "$(AK)" 2>/dev/null)" == 1 && "$(grep -cxF "${KEY2}" "$(AK)" 2>/dev/null)" == 1 \
   && "$(count "$(AK)")" == 2 ]]
check "[rerun] same key for an existing user adds no duplicate line, keeps the other key" $?
[[ "$(count "${L}/useradd.log")" == 1 && "$(mode "$(AK)" 2>/dev/null)" == 600 ]]
check "[rerun] existing user is not re-created and the file stays 0600" $?

fresh keyonly; printf '%s\n' "${KEY1}" > "${B}/authorized_keys"; run
[[ ${RC} -eq 0 && ! -e "${L}/useradd.log" && ! -e "${L}/chpasswd.stdin" && -z "$(ls -A "${H}")" && ! -e "${B}/authorized_keys" ]]
check "[key-only] key without userconf.txt: no user, no key installed, file deleted" $?

fresh useronly; userconf; run
[[ ${RC} -eq 0 && "$(count "${L}/useradd.log")" == 1 && ! -e "$(AK)" && ! -e "${B}/userconf.txt" ]]
check "[userconf-only] user created, no authorized_keys written, file deleted" $?

fresh paired; userconf; printf '%s\n' "${KEY1}" > "${B}/authorized_keys"; : > "${C}"; run
[[ ${RC} -eq 0 && ! -e "${L}/useradd.log" && ! -e "${L}/chpasswd.stdin" && ! -e "${L}/usermod.log" && -z "$(ls -A "${H}")" ]]
check "[paired] no user created, no password set, no group change, no key installed" $?
[[ ! -e "${B}/userconf.txt" && ! -e "${B}/authorized_keys" ]]; check "[paired] both FAT files are deleted" $?
[[ "$(printf '%s\n' "${OUT}" | grep -c .)" == 1 && "${OUT}" == *arlowe-userconf* && "${OUT}" == *refus* ]]
check "[paired] exactly one log line, naming arlowe-userconf and the refusal" $?

fresh paired-existing; userconf; printf '%s\n' "${KEY2}" > "${B}/authorized_keys"; : > "${C}"
mkdir -p "${H}/devuser/.ssh"; echo devuser > "${L}/users"; printf '%s\n' "${KEY1}" > "$(AK)"; run
[[ "$(cat "$(AK)")" == "${KEY1}" && ! -e "${L}/chpasswd.stdin" && ! -e "${B}/userconf.txt" ]]
check "[paired-existing] an existing user's password and keys are left untouched, files deleted" $?

fresh paired-keyonly; printf '%s\n' "${KEY1}" > "${B}/authorized_keys"; : > "${C}"; run
[[ ${RC} -eq 0 && ! -e "${B}/authorized_keys" && -z "$(ls -A "${H}")" ]]
check "[paired-keyonly] a lone key file is deleted, nothing installed" $?

fresh neither; run
[[ ${RC} -eq 0 && -z "$(ls -A "${L}")" && -z "$(ls -A "${H}")" && -z "${OUT}" ]]
check "[neither] no files: rc 0, no command run, no output" $?

fresh neither-paired; : > "${C}"; run
[[ ${RC} -eq 0 && -z "$(ls -A "${L}")" ]]; check "[neither-paired] no files on a paired unit: rc 0, no change" $?

# systemd ORs ConditionPathExists lines prefixed with '|'; a plain line would AND with them.
OUT="$(grep '^Condition' "${UNIT}")"
[[ "$(grep -c '^ConditionPathExists=|/boot/firmware/userconf.txt$' <<<"${OUT}")" == 1 \
   && "$(grep -c '^ConditionPathExists=|/boot/firmware/authorized_keys$' <<<"${OUT}")" == 1 \
   && "$(grep -c . <<<"${OUT}")" == 2 ]]
check "[unit] runs when either userconf.txt or authorized_keys exists (OR'd conditions)" $?

echo "${PASSED} passed, ${FAILED} failed"
[[ ${FAILED} -eq 0 ]]
