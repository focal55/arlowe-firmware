#!/usr/bin/env bash
# scripts/lib/login-gate.sh
#
# Default-login check over a built rootfs. Sourced, not executed.
#
#   verify_no_default_login <rootfs>
#
# The image is paired, not logged into. It must ship no account that can log in
# with a password, no passwordless sudo, and an sshd that refuses passwords, so a
# device on a LAN (or inside Wi-Fi range of the Phase 8 setup hotspot) is not one
# well-known credential away from root. pi-gen creates the first user, sets its
# password, writes a NOPASSWD sudoers rule and enables ssh; the export step that
# would tidy that is skipped (SKIP_IMAGES=1), so the build must prove it is gone.
#
# Every file is read INSIDE the rootfs. Symlinks are resolved against the rootfs,
# never the host: an absolute link's target read from the host is the build host's
# file, which is how a gate ends up passing on the wrong machine.
#
# Written for bash 3.2 and up so the fixture self-test runs on a developer Mac.
#
# RETURN CODES: 0 pass, 1 at least one FAIL, 2 could not test. Prints its own
# [OK]/[FAIL]/[ERROR] lines and never exits. Never prints a password hash.

# _lg_resolve <rootfs> <path in rootfs>: the host path of that file, with every
# symlink on the way followed inside the rootfs. Nonzero on a symlink loop.
_lg_resolve() {
    local root="$1" rest="${2#/}" cur="" comp target hops=0
    while [[ -n "${rest}" ]]; do
        comp="${rest%%/*}"
        if [[ "${rest}" == */* ]]; then rest="${rest#*/}"; else rest=""; fi
        case "${comp}" in
            "" | .) continue ;;
            ..) cur="${cur%/*}"; continue ;;
        esac
        if [[ -L "${root}${cur}/${comp}" ]]; then
            (( ++hops > 40 )) && return 1
            target="$(readlink "${root}${cur}/${comp}")"
            if [[ "${target}" == /* ]]; then
                cur=""; rest="${target#/}${rest:+/${rest}}"
            else
                rest="${target}${rest:+/${rest}}"
            fi
        else
            cur="${cur}/${comp}"
        fi
    done
    printf '%s' "${root}${cur}"
}

# _lg_file <rootfs> <path in rootfs>: host path of a regular file, else an [ERROR]
# on stderr and return 1.
_lg_file() {
    local host
    if ! host="$(_lg_resolve "$1" "$2")" || [[ ! -f "${host}" ]]; then
        echo "[ERROR] $2 does not resolve to a file inside the rootfs; it cannot be checked" >&2
        return 1
    fi
    printf '%s' "${host}"
}

# _lg_dir_entries <rootfs> <dir in rootfs>: entry names, one per line. A missing
# directory has no entries.
_lg_dir_entries() {
    local host
    host="$(_lg_resolve "$1" "$2")" || return 1
    [[ -d "${host}" ]] || return 0
    ls -A "${host}" | LC_ALL=C sort
}

_lg_check_shadow() {
    local root="$1" host bad user
    host="$(_lg_file "${root}" /etc/shadow)" || return 2
    # Usable means anything but a locked marker: an empty field logs in with no
    # password at all, so it counts.
    bad="$(awk -F: '$2 !~ /^[!*]/ { print $1 }' "${host}")"
    if [[ -n "${bad}" ]]; then
        while IFS= read -r user; do
            echo "[FAIL] /etc/shadow: account '${user}' has a usable password (not locked with ! or *)"
        done <<< "${bad}"
        return 1
    fi
    return 0
}

_lg_check_sudoers() {
    local root="$1" rc=0 name host vpath hits
    local -a files=(/etc/sudoers)
    while IFS= read -r name; do
        [[ -n "${name}" ]] && files+=("/etc/sudoers.d/${name}")
    done < <(_lg_dir_entries "${root}" /etc/sudoers.d)
    for vpath in "${files[@]}"; do
        host="$(_lg_file "${root}" "${vpath}")" || { rc=2; continue; }
        hits="$(awk '/^[[:space:]]*#/ { next } /NOPASSWD|![[:space:]]*authenticate/ { print }' "${host}")"
        if [[ -n "${hits}" ]]; then
            echo "[FAIL] ${vpath}: passwordless sudo (NOPASSWD or !authenticate):"
            printf '         %s\n' "${hits//$'\n'/$'\n'         }"
            (( rc == 2 )) || rc=1
        fi
    done
    return "${rc}"
}

# _lg_sshd_flatten <rootfs> <path in rootfs> <depth>: the ordered stream of sshd
# directives, one "<file><TAB><line>" per line, each Include replaced by the files
# it names. Only a glob in the last path component is supported, which is all
# sshd_config.d needs.
_lg_sshd_flatten() {
    local root="$1" vpath="$2" depth="$3" host line first arg dir pat f dhost
    host="$(_lg_file "${root}" "${vpath}")" || return 2
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%$'\r'}"
        [[ "${line}" =~ ^[[:space:]]*(#|$) ]] && continue
        read -r first arg <<< "${line}"
        if [[ "$(tr '[:upper:]' '[:lower:]' <<< "${first}")" == include ]]; then
            (( depth < 5 )) || { echo "[ERROR] sshd Include nesting too deep at ${vpath}" >&2; return 2; }
            [[ "${arg}" == /* ]] || arg="/etc/ssh/${arg}"
            dir="${arg%/*}"; pat="${arg##*/}"
            dhost="$(_lg_resolve "${root}" "${dir}")" || return 2
            [[ -d "${dhost}" ]] || continue
            while IFS= read -r f; do
                # shellcheck disable=SC2254
                case "${f}" in ${pat}) _lg_sshd_flatten "${root}" "${dir}/${f}" $((depth + 1)) || return 2 ;; esac
            done < <(ls -A "${dhost}" | LC_ALL=C sort)
        else
            printf '%s\t%s\n' "${vpath}" "${line}"
        fi
    done < "${host}"
}

_lg_check_sshd() {
    local root="$1" flat rc=0 out
    flat="$(_lg_sshd_flatten "${root}" /etc/ssh/sshd_config 0)" || return 2
    # A `yes` anywhere fails, Match blocks included. The first occurrence of
    # PasswordAuthentication and KbdInteractiveAuthentication outside a Match
    # block is the one sshd uses, and it must be an explicit `no`: unset means yes.
    out="$(awk -F'\t' '
        { split($2, w, /[[:space:]]+/); key = tolower(w[1]); val = tolower(w[2]); file = $1 }
        file != prev { inmatch = 0; prev = file }
        key == "match" { inmatch = 1 }
        key == "challengeresponseauthentication" { key = "kbdinteractiveauthentication" }
        key == "passwordauthentication" || key == "kbdinteractiveauthentication" || key == "permitemptypasswords" {
            if (val == "yes") { print "[FAIL] " file ": " w[1] " is yes"; bad = 1 }
            if (!inmatch && !(key in first)) first[key] = val
        }
        END {
            if (first["passwordauthentication"] != "no") { print "[FAIL] sshd: PasswordAuthentication is not explicitly set to no (unset means yes)"; bad = 1 }
            if (first["kbdinteractiveauthentication"] != "no") { print "[FAIL] sshd: KbdInteractiveAuthentication is not explicitly set to no (unset means yes)"; bad = 1 }
            exit bad ? 1 : 0
        }' <<< "${flat}")" || rc=1
    [[ -n "${out}" ]] && echo "${out}"
    return "${rc}"
}

verify_no_default_login() {
    local root="$1" rc=0 step step_rc
    for step in _lg_check_shadow _lg_check_sudoers _lg_check_sshd; do
        step_rc=0
        "${step}" "${root}" || step_rc=$?
        if (( step_rc == 2 || rc == 2 )); then rc=2; else rc=$(( rc | step_rc )); fi
    done
    case "${rc}" in
        0) echo "[OK] no account has a usable password, no sudo rule skips the password, sshd refuses passwords." ;;
        1) echo "[FAIL] default login present; the image would ship a credential (see the lines above)." ;;
        *) echo "[ERROR] the default-login gate could not read the rootfs; it did not pass." ;;
    esac
    return "${rc}"
}
