#!/usr/bin/env bash
# tests/security/test-login-gate.sh
#
# Self-test for scripts/lib/login-gate.sh over fabricated rootfs trees under
# `mktemp -d`. Plain bash and POSIX tools only, so it runs on the build host, CI
# and a developer Mac.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${REPO_ROOT}/scripts/lib/login-gate.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
PASSED=0
FAILED=0

# shellcheck source=scripts/lib/login-gate.sh
source "${LIB}" 2>/dev/null || true

HASH='$y$j9T$saltsaltsalt$0123456789abcdefghijklmnopqrstuvwxyzABCDEFG'

# good <case>: R is a rootfs that ships no default login, as the fixed build leaves it.
good() {
    R="${WORK}/$1/rootfs"
    mkdir -p "${R}/etc/sudoers.d" "${R}/etc/ssh/sshd_config.d"
    printf 'root:!:19000:0:99999:7:::\ndaemon:*:19000:0:99999:7:::\npi:!:19000:0:99999:7:::\n' > "${R}/etc/shadow"
    printf '# User privilege specification\nroot\tALL=(ALL:ALL) ALL\n%%sudo\tALL=(ALL:ALL) ALL\n@includedir /etc/sudoers.d\n' > "${R}/etc/sudoers"
    printf 'Include /etc/ssh/sshd_config.d/*.conf\n#PasswordAuthentication yes\nUsePAM yes\n' > "${R}/etc/ssh/sshd_config"
    printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitEmptyPasswords no\n' \
        > "${R}/etc/ssh/sshd_config.d/00-arlowe-key-only.conf"
}
# shipped <case>: the state build A shipped.
shipped() {
    good "$1"
    printf 'root:%s:19000:0:99999:7:::\npi:%s:19000:0:99999:7:::\n' "${HASH}" "${HASH}" > "${R}/etc/shadow"
    printf 'pi ALL=(ALL) NOPASSWD: ALL\n' > "${R}/etc/sudoers.d/010_pi-nopasswd"
    rm -f "${R}/etc/ssh/sshd_config.d/00-arlowe-key-only.conf"
    printf 'Include /etc/ssh/sshd_config.d/*.conf\nPasswordAuthentication yes\n' > "${R}/etc/ssh/sshd_config"
}
run() { OUT="$(verify_no_default_login "${R}" 2>&1)"; RC=$?; }
check() { # <name> <expected rc> [output substring]
    if [[ ${RC} -eq $2 && ( -z "${3:-}" || "${OUT}" == *"$3"* ) ]]; then
        echo "[OK]   $1"; PASSED=$((PASSED + 1))
    else
        echo "[FAIL] $1: rc=${RC}, want ${2}${3:+ with '$3'}"; printf '       %s\n' "${OUT//$'\n'/$'\n'       }"
        FAILED=$((FAILED + 1))
    fi
}

good clean; run
check "[clean] locked accounts, no NOPASSWD, key-only sshd: rc 0" 0 "[OK]"

shipped shipped; run
check "[shipped-state] pi + hash + NOPASSWD + password auth: rc 1" 1
if [[ "${OUT}" == *"pi"* && "${OUT}" == *"010_pi-nopasswd"* && "${OUT}" == *"PasswordAuthentication"* ]]; then RC=0; else RC=1; fi
check "[shipped-state-named] the report names the account, the sudoers file and the sshd setting" 0

for locked in '!' '*' '!*' '!$y$j9T$saltsalt$hash'; do
    good locked; printf 'pi:%s:19000:0:99999:7:::\n' "${locked}" > "${R}/etc/shadow"; run
    check "[shadow-locked] '${locked}' is not a usable password: rc 0" 0
done
good hashed; printf 'pi:%s:19000:0:99999:7:::\n' "${HASH}" >> "${R}/etc/shadow"; run
check "[shadow-hash] a usable hash: rc 1, account named" 1 "pi"
good rootpw; printf 'root:%s:19000:0:99999:7:::\n' '$6$s$h' > "${R}/etc/shadow"; run
check "[shadow-root] root with a hash: rc 1, root named" 1 "root"
good emptypw; printf 'pi::19000:0:99999:7:::\n' > "${R}/etc/shadow"; run
check "[shadow-empty] an empty hash logs in without a password: rc 1" 1 "pi"

good nopw-main; printf 'pi ALL=(ALL) NOPASSWD: ALL\n' >> "${R}/etc/sudoers"; run
check "[sudoers-main] NOPASSWD in /etc/sudoers: rc 1" 1 "NOPASSWD"
good nopw-d; printf '%%sudo ALL=(ALL) NOPASSWD:ALL\n' > "${R}/etc/sudoers.d/90-anything"; run
check "[sudoers-d] NOPASSWD in any sudoers.d file: rc 1, file named" 1 "90-anything"
good nopw-comment; printf '# pi ALL=(ALL) NOPASSWD: ALL\n' > "${R}/etc/sudoers.d/91-note"; run
check "[sudoers-comment] a commented NOPASSWD is not a grant: rc 0" 0
good noauth; printf 'Defaults !authenticate\n' > "${R}/etc/sudoers.d/92-noauth"; run
check "[sudoers-noauth] Defaults !authenticate is the same grant: rc 1" 1 "92-noauth"

good ssh-none; rm "${R}/etc/ssh/sshd_config.d/00-arlowe-key-only.conf"; run
check "[sshd-unset] no explicit PasswordAuthentication no (default is yes): rc 1" 1 "PasswordAuthentication"
good ssh-main-yes; printf 'PasswordAuthentication yes\n' >> "${R}/etc/ssh/sshd_config"; run
check "[sshd-yes-main] a yes in sshd_config: rc 1" 1 "PasswordAuthentication"
good ssh-drop-yes; printf 'PasswordAuthentication yes\n' > "${R}/etc/ssh/sshd_config.d/99-yes.conf"; run
check "[sshd-yes-dropin] a yes in a drop-in, even a later one: rc 1" 1 "99-yes.conf"
good ssh-kbd; printf 'PasswordAuthentication no\nKbdInteractiveAuthentication yes\n' > "${R}/etc/ssh/sshd_config.d/00-arlowe-key-only.conf"; run
check "[sshd-kbd] keyboard-interactive on: rc 1" 1 "KbdInteractiveAuthentication"
good ssh-empty; printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitEmptyPasswords yes\n' > "${R}/etc/ssh/sshd_config.d/00-arlowe-key-only.conf"; run
check "[sshd-empty] PermitEmptyPasswords yes: rc 1" 1 "PermitEmptyPasswords"

good link; mv "${R}/etc/ssh/sshd_config.d/00-arlowe-key-only.conf" "${R}/etc/ssh/real.conf"
ln -s /etc/ssh/real.conf "${R}/etc/ssh/sshd_config.d/00-arlowe-key-only.conf"; run
check "[symlink-in-rootfs] an absolute symlink resolves inside the rootfs, not on the host: rc 0" 0
good link-bad; printf 'pi ALL=(ALL) NOPASSWD: ALL\n' > "${R}/etc/real-sudoers"
ln -s /etc/real-sudoers "${R}/etc/sudoers.d/010_pi-nopasswd"; run
check "[symlink-grant] a NOPASSWD reached through an absolute symlink: rc 1" 1 "NOPASSWD"
good dangling; ln -s /etc/nowhere "${R}/etc/sudoers.d/dead"; run
check "[symlink-dangling] a link that resolves to nothing cannot be checked: rc 2" 2
good noshadow; rm "${R}/etc/shadow"; run
check "[no-shadow] no /etc/shadow: rc 2, the gate cannot test" 2

echo "${PASSED} passed, ${FAILED} failed"
[[ ${FAILED} -eq 0 && ${PASSED} -gt 0 ]]
