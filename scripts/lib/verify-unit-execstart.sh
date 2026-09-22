#!/usr/bin/env bash
# scripts/lib/verify-unit-execstart.sh
#
# Two build-time gates over a provisioned rootfs, both deriving their
# expectations from the rootfs's OWN unit files rather than from a list anyone
# has to maintain:
#
#   verify_unit_execstart      <rootfs>  every Exec* target resolves inside the rootfs
#   verify_unit_runtime_versions <rootfs>  every named interpreter meets a version floor
#
# THE TWO HAVE DIFFERENT SCOPES, on purpose.
#   * The PATH gate is universal. A unit naming a binary the rootfs does not
#     carry is a real defect whether we wrote the unit or apt did, so every unit
#     in /etc/systemd/system is checked.
#   * The VERSION gate covers units THIS REPO SHIPS. A floor is a claim about
#     software we chose — node from next@16.1.6's engines.node, the venv pythons
#     we create — and we did not choose sshd's /bin/kill. Ownership is derived
#     per unit from the rootfs's dpkg database (see _vue_unit_owner), never from
#     a list here.
#
# NOTHING IN EITHER GATE MAY READ THE BUILD HOST. Seven of the fifteen units on
# a real rootfs are `systemctl enable` aliases — symlinks with absolute targets
# into /lib/systemd/system — so both the executable paths AND the unit files
# themselves resolve through _vue_resolve, which re-roots at <rootfs>. See
# _vue_unit_resolve for what happened when only the former did.
#
# WHY BOTH. scripts/build-image.sh's declared-packages guard (immediately above
# the call site) proves that packages the build DECLARED landed. By construction
# it can never see a dependency nobody declared. These gates invert that: the
# expectation set is globbed from <rootfs>/etc/systemd/system/*.service, so a
# seventh unit extends the gate with no edit here.
#
# The pair is deliberate. A path check cannot tell a Node 20 from a Node 18, and
# pi-gen's stage-arlowe package list installs bookworm's nodejs 18.20.4 at
# /usr/bin/node — exactly the path the arlowe-dashboard unit names. Under an
# existence-only check that unit PASSES and the dashboard still never starts.
#
# WHAT THESE GATES DELIBERATELY DO NOT COVER, so the limit is on the record:
#   * They prove a path exists and is executable. They never prove the binary
#     there can run what it is handed. Module-import resolution (the undeclared
#     Pillow import class) is plan 07.1-05's `unit-import-bookworm` job.
#   * End-to-end runtime behaviour is SC6's hardware checkpoint (plan 07.1-06).
#   * Argument splitting is plain whitespace splitting. systemd's quoted-argument
#     and C-escape syntax is not interpreted; no shipping unit uses it. A quoted
#     path containing a space would be split and could produce a spurious FAIL,
#     which is the fail-closed direction.
#   See docs/architecture/0008-image-runtime-dependency-strategy.md.
#
# RETURN CODES (both functions):
#   0  every assertion passed
#   1  at least one FAIL — a real substrate defect
#   2  HARD ERROR — the gate could not perform its test. Never a pass, never a
#      skip. A gate that reports "clean" because it could not read is worse than
#      no gate at all, and one that reports FAIL because it could not read is
#      worse still: it trains the next reader to ignore it.
#
# PRIVILEGE. scripts/provision/install-arlowe-fs.sh creates /opt/arlowe as
# 0750 root:arlowe. A build-host user is neither root nor in the image's arlowe
# group, so unprivileged existence tests on every Exec* target under that tree
# return false. Both functions detect an unsearchable directory and return the
# HARD ERROR rather than collapsing it into "missing"; scripts/build-image.sh
# therefore invokes them under sudo, for the same reason its `du` runs under sudo.
#
# `-`-PREFIXED STANZAS are reported as WARN, not FAIL. systemd itself tolerates
# their failure (`ExecStartPre=-/opt/arlowe/x` means "run it, ignore the result"),
# so a missing target there is a degraded unit rather than a dead one. They are
# always printed: tolerated is not the same as invisible.
#
# ARCHITECTURE DETECTION (version gate only). The rootfs's architecture is read
# from <rootfs>/var/lib/dpkg/arch, falling back to `dpkg --print-architecture
# --root=<rootfs>` (which reads that same file), falling back to the ELF
# e_machine field of <rootfs>/bin/bash. It is mapped explicitly onto `uname -m`
# (arm64<->aarch64, amd64<->x86_64, armhf<->armv7l): a raw string compare of the
# two vocabularies would hard-error on a correct native build.
#
# ARLOWE_VERSION_PROBE exists for tests/phase-07.1/test-verify-unit-execstart.sh
# ONLY. It replaces the chroot probe with `$ARLOWE_VERSION_PROBE <rootfs> <path>`,
# which is what lets the self-test pin a fake Node 18.20.4 at an ExecStart path
# without committing an arm64 binary. When it is set, this file says so loudly on
# every run — an accidentally-exported variable must not be able to make a build's
# gate quietly lie. scripts/build-image.sh asserts it is unset and aborts if it
# is not; it deliberately does not `unset` it, because normalising the anomaly
# into silence is how the anomaly survives.
#
# Self-tested by tests/phase-07.1/test-verify-unit-execstart.sh, which runs on
# every pull request via .github/workflows/pr-checks.yml.

if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
    printf 'verify-unit-execstart.sh requires bash 4+ (associative arrays); found %s\n' \
        "${BASH_VERSION:-unknown}" >&2
    # shellcheck disable=SC2317  # the exit is reached only when this library is executed rather than sourced
    return 1 2>/dev/null || exit 1
fi

# ---------------------------------------------------------------------------
# DECLARED VERSION FLOORS, keyed by the RESOLVED basename of the interpreter a
# unit names. Keying on the basename rather than on a path means the table
# covers /usr/bin/node, /opt/node/bin/node and /opt/arlowe/venvs/*/bin/python
# alike without enumerating paths. Adding a floor is a one-line edit here; the
# reasoning belongs in the ADR.
#
#   node     20.9.0   next@16.1.6's `engines.node` (runtime/dashboard/package.json).
#                     Bookworm's nodejs is 18.20.4 — see ADR-0008.
#   python3  3.11.0   Bookworm's system python3. The venv interpreters are
#                     created from it and inherit the version.
#   python   3.11.0   Same interpreter; venvs expose both names in bin/.
# ---------------------------------------------------------------------------
declare -A ARLOWE_RUNTIME_FLOOR=(
    [node]='20.9.0'
    [python3]='3.11.0'
    [python]='3.11.0'
)

# ---------------------------------------------------------------------------
# EXPECTED_UNDECLARED — the exact Exec* tokens that legitimately have no version
# floor. Matched on the LITERAL token as written in the unit, BEFORE symlink
# resolution: bookworm is usrmerge, so /bin/touch resolves to /usr/bin/touch, and
# keying on the resolved path would make this list disagree with both what a
# reviewer reads in the unit file and what a diff shows.
#
# An observed undeclared token outside this set is a FAIL, not a printed line.
# Naming is not gating: an already-noisy already-green category is precisely the
# 00-packages-nr shape that produced F7 #18 one layer up, and a genuinely new
# interpreter must not be able to arrive as one more line in a passing list.
# ---------------------------------------------------------------------------
#
# THIS LIST COVERS REPO-SHIPPED UNITS ONLY. The glob is over the rootfs's own
# /etc/systemd/system, which is deliberate — a seventh arlowe unit extends the
# gate with no edit here — but apt puts units there too: `systemctl enable`
# installs dbus alias symlinks, and a real rootfs carries seven of them
# (sshd, wpa_supplicant, bluetooth, avahi-daemon, ModemManager,
# NetworkManager-dispatcher, systemd-timesyncd) beside our eight.
#
# Those seven named interpreters we never chose — sshd's /bin/kill,
# ModemManager's own binary — and the version gate demanded a floor for each,
# producing failures that were real output about nothing. The fix is NOT to
# paste every OS interpreter in here: that converts a guard derived from the
# rootfs into a hand-maintained list, and a hand-maintained list rots into an
# already-green category that the next genuine entry hides inside. It is the
# 00-packages-nr shape that produced F7 #18 one layer up.
#
# Instead _vue_unit_owner derives ownership from the rootfs's dpkg database and
# verify_unit_runtime_versions skips apt-owned units outright. What remains
# below is only what OUR units name, and an undeclared interpreter in one of
# ours is still a FAIL.
ARLOWE_EXPECTED_UNDECLARED=(
    '/bin/touch'                                     # coreutils; firstboot ExecStartPost marker
    '/opt/arlowe/runtime/cli/arlowe-grow-models'     # first-party grow script, firstboot ExecStartPre
    '/opt/arlowe/runtime/cli/arlowe-userconf'        # first-party bash; provisions a login from userconf.txt
    '/opt/arlowe/runtime/cli/boot-check'             # first-party entry point
    '/opt/arlowe/runtime/cli/identity'               # first-party entry point
    '/opt/arlowe/runtime/llm/run_api.sh'             # first-party shell wrapper; execs a venv python itself
    '/opt/arlowe/runtime/recovery/arlowe-recovery.sh' # slot-B recovery unit; first-party shell
)

_VUE_DIRECTIVES='ExecStart ExecStartPre ExecStartPost ExecStop ExecStopPost ExecReload'

_vue_log()  { printf '[%s] %s\n' "$1" "${*:2}"; }
_vue_ok()   { printf '[%s] OK   %s\n' "$1" "${*:2}"; }
_vue_warn() { printf '[%s] WARN %s\n' "$1" "${*:2}" >&2; }
_vue_fail() { printf '[%s] FAIL %s\n' "$1" "${*:2}" >&2; }
_vue_err()  { printf '[%s] ERROR %s\n' "$1" "${*:2}" >&2; }

# errexit shield. Both public functions are sourced into scripts/build-image.sh,
# which runs `set -euo pipefail`. These gates must collect every failure and
# report them together — a gate that aborts on the first one turns one build into
# five — so errexit is suspended for the body and restored on the single exit.
_vue_shield_on() {
    _VUE_ERREXIT=0
    case $- in *e*) _VUE_ERREXIT=1 ;; esac
    set +e
}
_vue_shield_off() {
    if [[ "${_VUE_ERREXIT:-0}" == "1" ]]; then set -e; fi
}

# ---------------------------------------------------------------------------
# Resolve <path> inside <rootfs>, component by component, following symlinks
# WITHOUT ever escaping the rootfs. An absolute symlink target is re-rooted at
# <rootfs>; letting the OS follow it would silently test the BUILD HOST's
# filesystem, which is the failure mode where a gate passes because the host
# happens to have what the image is missing.
#
# Prints the final rootfs-relative absolute path on stdout in every case, so the
# caller can name where a dangling chain ends.
#   0  final target exists
#   1  final target does not exist (a dangling symlink lands here — F7 #21)
#   2  symlink loop / depth exceeded
#   3  a directory on the way is not searchable by this user, so absence cannot
#      be distinguished from denial. NEVER collapsed into 1: reporting a
#      permission wall as a missing file is a FAIL for the wrong reason, and a
#      gate that fails for the wrong reason is indistinguishable from one that
#      works until the day it matters.
# ---------------------------------------------------------------------------
_vue_resolve() {
    local rootfs="$1" rest="${2#/}"
    local resolved='' comp target steps=0

    while [[ -n "${rest}" ]]; do
        steps=$(( steps + 1 ))
        if (( steps > 256 )); then
            printf '%s\n' "${resolved}/${rest}"
            return 2
        fi

        comp="${rest%%/*}"
        if [[ "${comp}" == "${rest}" ]]; then rest=''; else rest="${rest#*/}"; fi

        case "${comp}" in
            ''|.)  continue ;;
            ..)    resolved="${resolved%/*}"; continue ;;
        esac

        # A directory we cannot search makes every child test false.
        # install-arlowe-fs.sh creates /opt/arlowe 0750 root:arlowe, so an
        # unprivileged caller hits this on every Exec* target in the tree.
        if [[ -d "${rootfs}${resolved:-/}" && ! -x "${rootfs}${resolved:-/}" ]]; then
            printf '%s\n' "${resolved}/${comp}"
            return 3
        fi

        if [[ -L "${rootfs}${resolved}/${comp}" ]]; then
            target="$(readlink "${rootfs}${resolved}/${comp}" 2>/dev/null)"
            if [[ -z "${target}" ]]; then
                printf '%s\n' "${resolved}/${comp}"
                return 1
            fi
            if [[ "${target}" == /* ]]; then
                resolved=''
                rest="${target#/}${rest:+/${rest}}"
            else
                rest="${target}${rest:+/${rest}}"
            fi
            continue
        fi

        resolved="${resolved}/${comp}"
    done

    printf '%s\n' "${resolved:-/}"
    [[ -e "${rootfs}${resolved:-/}" ]] || return 1
    return 0
}

# ---------------------------------------------------------------------------
# Emit "<Directive>\t<command line>" for every Exec* assignment in a unit file.
#
#   * systemd line continuations (trailing `\`) are joined before parsing.
#   * An EMPTY assignment (`ExecStart=`) is systemd's reset syntax — skipped.
#   * Leading whitespace on a directive line is allowed by systemd and stripped.
#
# Factored out because both gates parse the same stanzas. Two copies of a systemd
# line parser is precisely the drift this phase exists to eliminate.
# ---------------------------------------------------------------------------
_vue_exec_stanzas() {
    local unit="$1"
    local line acc='' directive value

    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%$'\r'}"
        if [[ -z "${acc}" ]]; then
            acc="${line#"${line%%[![:space:]]*}"}"
        else
            acc="${acc} ${line#"${line%%[![:space:]]*}"}"
        fi

        if [[ "${acc}" == *\\ ]]; then
            acc="${acc%\\}"
            continue
        fi

        directive="${acc%%=*}"
        if [[ "${directive}" != "${acc}" && " ${_VUE_DIRECTIVES} " == *" ${directive} "* ]]; then
            value="${acc#*=}"
            value="${value#"${value%%[![:space:]]*}"}"
            [[ -n "${value}" ]] && printf '%s\t%s\n' "${directive}" "${value}"
        fi
        acc=''
    done < "${unit}"
}

# Strip systemd's Exec* prefix characters (@ - : + ! |) from a command line.
# Prints "<tolerate>\t<stripped command line>" where <tolerate> is 1 when a `-`
# prefix was present, meaning systemd ignores this stanza's failure.
_vue_strip_prefixes() {
    local value="$1" tolerate=0 ch
    while [[ -n "${value}" ]]; do
        ch="${value:0:1}"
        case "${ch}" in
            '-') tolerate=1; value="${value:1}" ;;
            '@'|':'|'+'|'!'|'|') value="${value:1}" ;;
            *) break ;;
        esac
    done
    printf '%s\t%s\n' "${tolerate}" "${value}"
}

# A token systemd resolves at unit-load time cannot be resolved statically.
_vue_is_interpolated() {
    [[ "$1" == *'$'* || "$1" == *'%'* ]]
}

# Glob the rootfs's own installed units. NOT the repo's unit source directory: the
# rootfs also carries arlowe-firstboot.service, which
# pi-gen/stage-arlowe/03-firstboot/00-run-chroot.sh writes directly and which
# never passes through the repo's unit source directory, and the slot-B rootfs carries
# arlowe-recovery.service. A repo-side list would miss both.
#
# `-e` alone is wrong here: it FOLLOWS symlinks, so an alias whose absolute
# target is absent from the build host would be dropped from the unit set
# silently — a unit that vanishes from the expectation set rather than failing.
# `-L` catches the entry as a directory entry regardless of where it points.
_vue_unit_files() {
    local rootfs="$1" f
    for f in "${rootfs}/etc/systemd/system/"*.service; do
        [[ -e "${f}" || -L "${f}" ]] && printf '%s\n' "${f}"
    done
    return 0
}

# ---------------------------------------------------------------------------
# Resolve the UNIT FILE ITSELF rootfs-relative, before anything reads it.
#
# Found by the plan 07.2 full build, which produced a correct rootfs and then
# failed twelve assertions, every one of them false. `systemctl enable` installs
# dbus aliases into /etc/systemd/system as symlinks with ABSOLUTE targets:
#
#     sshd.service -> /lib/systemd/system/ssh.service
#
# and seven of the fifteen units on a real rootfs are that shape. Reading
# "${rootfs}/etc/systemd/system/sshd.service" hands that absolute target to the
# kernel, which follows it on the BUILD HOST. The gate parsed the host's trixie
# unit files and judged the bookworm rootfs by them — it read the host's
# NetworkManager 1.52.1 ExecStart=/usr/libexec/nm-dispatcher and reported it
# missing, while the rootfs's own unit correctly names
# /usr/lib/NetworkManager/nm-dispatcher, present at 68024 bytes.
#
# The false-FAIL was the visible half. The false-PASS is the worse one and the
# same bug: a build host that happens to carry what the image lacks would make
# this gate report clean, which is the exact class it exists to catch.
#
# _vue_resolve already re-roots absolute targets for EXECUTABLE paths. This puts
# the unit-file read under the same rule. Prints the rootfs-RELATIVE resolved
# path, like _vue_resolve, and returns _vue_resolve's code.
# ---------------------------------------------------------------------------
_vue_unit_resolve() {
    local rootfs="$1" unit="$2"
    _vue_resolve "${rootfs}" "${unit#"${rootfs}"}"
}

# ---------------------------------------------------------------------------
# OWNERSHIP — did apt ship this unit, or do we?
#
# Derived from the rootfs's OWN dpkg database, deliberately not from a list in
# this file. A hit means a Debian package shipped the file and apt owns its
# version; a miss means it arrived some other way, which for this image means
# install-arlowe-fs.sh or pi-gen's stage-arlowe wrote it.
#
# QUERY THE RESOLVED TARGET, NOT THE GLOB ENTRY. Verified against the real built
# rootfs: `dpkg -S /etc/systemd/system/sshd.service` finds nothing, and neither
# does the same query for one of ours — those dbus aliases are created by
# `systemctl enable` in a postinst and are shipped in no .deb at all, so the
# glob entry separates nothing. The alias's TARGET is shipped, and
# `dpkg -S /lib/systemd/system/ssh.service` answers openssh-server. On the real
# rootfs this splits all fifteen units correctly: eight ours, seven apt's.
#
# USRMERGE TWIN. Bookworm's dpkg records openssh-server's unit as
# /lib/systemd/system/ssh.service, while _vue_resolve — traversing the rootfs's
# own /lib -> usr/lib symlink — produces /usr/lib/systemd/system/ssh.service.
# Both spellings name one file; the database records whichever the package was
# built with, so every candidate is queried in both. Without this the lookup
# misses every apt unit on a bookworm rootfs and the scoping silently does
# nothing.
#
# FAILURE MODE, stated rather than discovered later. UNOWNED IS THE DEFAULT:
# anything dpkg cannot account for is treated as ours and gets the full version
# gate. So a future apt package whose unit dpkg does not record would be held to
# our floors and could FAIL as an undeclared interpreter. That is the
# fail-closed direction and it is the one to be wrong in — it costs a human one
# look, where the opposite default would let a repo-shipped unit slip the floor
# gate with no sound at all. A rootfs carrying no dpkg database degrades to
# "every unit is ours", announced once on stderr rather than assumed.
#
#   0  a Debian package owns this unit (package name on stdout)
#   1  no package owns it — this repo ships it
# ---------------------------------------------------------------------------
_vue_usrmerge_twin() {
    case "$1" in
        /usr/bin/*|/usr/sbin/*|/usr/lib/*) printf '%s\n' "${1#/usr}" ;;
        /bin/*|/sbin/*|/lib/*)             printf '/usr%s\n' "$1" ;;
    esac
}

_vue_dpkg_owner() {
    local admindir="$1" path="$2" line owned
    # dpkg-query reads * ? [ as glob metacharacters, so a unit path carrying one
    # would match more than it names. Refuse the query rather than trust it.
    case "${path}" in *'*'*|*'?'*|*'['*) return 1 ;; esac
    # Exact-match the returned path too: dpkg prints "<pkg>: <path>", and a
    # diversion line or a partial match must not be read as ownership.
    while IFS= read -r line; do
        owned="${line##*: }"
        if [[ "${owned}" == "${path}" ]]; then
            printf '%s\n' "${line%%:*}"
            return 0
        fi
    done < <(dpkg --admindir="${admindir}" -S "${path}" 2>/dev/null)
    return 1
}

# _vue_unit_owner <rootfs> <literal-unit-path> <resolved-unit-path>
_vue_unit_owner() {
    local rootfs="$1" lit="$2" res="$3"
    local admindir="${rootfs}/var/lib/dpkg" cand owner
    [[ -d "${admindir}" ]] || return 1
    for cand in "${lit}" "$(_vue_usrmerge_twin "${lit}")" \
                "${res}" "$(_vue_usrmerge_twin "${res}")"; do
        [[ -n "${cand}" ]] || continue
        if owner="$(_vue_dpkg_owner "${admindir}" "${cand}")"; then
            printf '%s\n' "${owner}"
            return 0
        fi
    done
    return 1
}

# _vue_hard_permission <tag> <unit> <token> <blocked-path>
_vue_hard_permission() {
    _vue_err "$1" "$2: cannot search inside the rootfs as far as $4 (blocked resolving $3) as $(id -un 2>/dev/null || printf 'uid %s' "$(id -u)"). install-arlowe-fs.sh creates /opt/arlowe 0750 root:arlowe — run this gate with the privilege the rootfs requires, the way build-image.sh's du does."
}

# An unreadable unit directory produces an EMPTY glob, which would otherwise be
# reported as "zero units" — a FAIL for a permission reason. Hard-error instead.
#   0 readable   2 present but unreadable
_vue_unit_dir_readable() {
    local rootfs="$1" tag="$2"
    local dir="${rootfs}/etc/systemd/system"
    [[ -d "${dir}" ]] || return 0
    if [[ ! -r "${dir}" || ! -x "${dir}" ]]; then
        _vue_err "${tag}" "cannot read ${dir} as $(id -un 2>/dev/null || printf 'uid %s' "$(id -u)") — the unit set cannot be enumerated. Run this gate with the privilege the rootfs requires; reporting 'no units' here would be a pass-shaped lie."
        return 2
    fi
    return 0
}

# ===========================================================================
# GATE 1 — every Exec* target resolves inside the rootfs
# ===========================================================================
verify_unit_execstart() {
    local rootfs="${1:?verify_unit_execstart: <rootfs> required}"
    rootfs="${rootfs%/}"

    _vue_shield_on
    local tag='unit-execstart'
    local rc=0 fails=0 skips=0 warns=0 checked=0 units=0 hard=0
    local unit name directive value tolerate stripped unit_rel urc
    local -a tokens
    local token exe resolved rrc

    if ! _vue_unit_dir_readable "${rootfs}" "${tag}"; then
        _vue_shield_off
        return 2
    fi

    local -a unit_files=()
    while IFS= read -r unit; do
        [[ -n "${unit}" ]] && unit_files+=( "${unit}" )
    done < <(_vue_unit_files "${rootfs}")

    if (( ${#unit_files[@]} == 0 )); then
        _vue_fail "${tag}" "no unit files found under ${rootfs}/etc/systemd/system/ — an empty unit set cannot be a pass"
        _vue_shield_off
        return 1
    fi

    for unit in "${unit_files[@]}"; do
        units=$(( units + 1 ))
        # The name stays the INSTALLED one. sshd.service is what systemd loads
        # and what a reader greps for, even though its body lives in ssh.service.
        name="$(basename "${unit}" .service)"

        unit_rel="$(_vue_unit_resolve "${rootfs}" "${unit}")"; urc=$?
        if (( urc == 3 )); then
            _vue_hard_permission "${tag}" "${name}" "${unit#"${rootfs}"}" "${unit_rel}"
            hard=1
            continue
        fi
        if (( urc != 0 )) || [[ ! -f "${rootfs}${unit_rel}" || ! -r "${rootfs}${unit_rel}" ]]; then
            _vue_fail "${tag}" "${name}: the unit file does not resolve to a readable file inside the rootfs (chain ends at ${unit_rel}) — its Exec* stanzas cannot be read, and following that link on the build host would test the host instead"
            fails=$(( fails + 1 ))
            continue
        fi

        while IFS=$'\t' read -r directive value; do
            IFS=$'\t' read -r tolerate stripped < <(_vue_strip_prefixes "${value}")
            [[ -n "${stripped}" ]] || continue

            # shellcheck disable=SC2206  # deliberate whitespace splitting of a systemd command line
            tokens=( ${stripped} )
            (( ${#tokens[@]} )) || continue
            exe="${tokens[0]}"

            # (c) UNRESOLVABLE — env interpolation or a systemd specifier.
            if _vue_is_interpolated "${exe}"; then
                printf '[%s] SKIP %s: %s (env/specifier interpolation)\n' "${tag}" "${name}" "${exe}"
                skips=$(( skips + 1 ))
                continue
            fi

            # (a) EXECUTABLE
            if [[ "${exe}" != /* ]]; then
                _vue_fail "${tag}" "${name}: ${directive} executable is not absolute: ${exe} (systemd requires an absolute path)"
                fails=$(( fails + 1 ))
                continue
            fi

            checked=$(( checked + 1 ))
            resolved="$(_vue_resolve "${rootfs}" "${exe}")"; rrc=$?
            if (( rrc == 3 )); then
                _vue_hard_permission "${tag}" "${name}" "${exe}" "${resolved}"
                hard=1
                continue
            fi
            if (( rrc == 2 )); then
                _vue_fail "${tag}" "${name}: ${directive} symlink loop resolving ${exe}"
                fails=$(( fails + 1 ))
                continue
            fi
            if (( rrc != 0 )); then
                local detail="${exe}"
                [[ "${resolved}" != "${exe}" ]] && detail="${exe} (symlink chain ends at ${resolved})"
                if (( tolerate )); then
                    _vue_warn "${tag}" "${name}: ${directive} is '-' prefixed (failure tolerated); target missing in rootfs: ${detail}"
                    warns=$(( warns + 1 ))
                else
                    _vue_fail "${tag}" "${name}: ${directive} executable missing in rootfs: ${detail}"
                    fails=$(( fails + 1 ))
                fi
                continue
            fi
            if [[ ! -x "${rootfs}${resolved}" ]]; then
                if (( tolerate )); then
                    _vue_warn "${tag}" "${name}: ${directive} is '-' prefixed (failure tolerated); target not executable: ${exe}"
                    warns=$(( warns + 1 ))
                else
                    _vue_fail "${tag}" "${name}: ${directive} executable is not executable: ${exe}"
                    fails=$(( fails + 1 ))
                fi
                continue
            fi

            # (b) SCRIPT ARGUMENTS — existence only. An interpreter argument need
            # not carry the execute bit.
            for token in "${tokens[@]:1}"; do
                if _vue_is_interpolated "${token}"; then
                    printf '[%s] SKIP %s: %s (env/specifier interpolation)\n' "${tag}" "${name}" "${token}"
                    skips=$(( skips + 1 ))
                    continue
                fi
                [[ "${token}" == /* ]] || continue
                case "${token}" in
                    *.py|*.js|*.sh|/opt/arlowe/*) ;;
                    *) continue ;;
                esac

                checked=$(( checked + 1 ))
                resolved="$(_vue_resolve "${rootfs}" "${token}")"; rrc=$?
                if (( rrc == 3 )); then
                    _vue_hard_permission "${tag}" "${name}" "${token}" "${resolved}"
                    hard=1
                    continue
                fi
                if (( rrc != 0 )); then
                    if (( tolerate )); then
                        _vue_warn "${tag}" "${name}: ${directive} is '-' prefixed (failure tolerated); argument file missing in rootfs: ${token}"
                        warns=$(( warns + 1 ))
                    else
                        _vue_fail "${tag}" "${name}: ${directive} argument file missing in rootfs: ${token}"
                        fails=$(( fails + 1 ))
                    fi
                fi
            done
        done < <(_vue_exec_stanzas "${rootfs}${unit_rel}")
    done

    if (( hard )); then
        _vue_err "${tag}" "the gate could not read parts of ${rootfs}, so absence cannot be distinguished from denial. This is neither a pass nor a FAIL."
        _vue_shield_off
        return 2
    fi

    _vue_log "${tag}" "${units} unit(s), ${checked} target(s) checked, ${fails} failure(s), ${warns} warning(s), ${skips} skip(s)"
    if (( fails > 0 )); then
        _vue_fail "${tag}" "${fails} Exec* target(s) named by units are absent from the rootfs"
        rc=1
    else
        _vue_ok "${tag}" "every Exec* target named by a unit resolves inside ${rootfs}"
    fi

    _vue_shield_off
    return "${rc}"
}

# ===========================================================================
# GATE 2 — every named interpreter meets a declared version floor
# ===========================================================================

# Map a dpkg architecture onto its `uname -m` spelling.
_vue_uname_for_dpkg_arch() {
    case "$1" in
        arm64)   printf 'aarch64\n' ;;
        amd64)   printf 'x86_64\n' ;;
        armhf)   printf 'armv7l\n' ;;
        armel)   printf 'armv6l\n' ;;
        i386)    printf 'i686\n' ;;
        riscv64) printf 'riscv64\n' ;;
        *)       printf '%s\n' "$1" ;;
    esac
}

# Best-effort ELF e_machine read, used only when the rootfs carries no dpkg data.
_vue_arch_from_elf() {
    local f="$1" machine
    [[ -r "${f}" ]] || return 1
    machine="$(od -An -tu2 -j18 -N2 "${f}" 2>/dev/null | tr -d '[:space:]')"
    case "${machine}" in
        183) printf 'arm64\n' ;;
        62)  printf 'amd64\n' ;;
        40)  printf 'armhf\n' ;;
        3)   printf 'i386\n' ;;
        243) printf 'riscv64\n' ;;
        *)   return 1 ;;
    esac
}

_vue_rootfs_arch() {
    local rootfs="$1" arch=''
    if [[ -r "${rootfs}/var/lib/dpkg/arch" ]]; then
        arch="$(head -n1 "${rootfs}/var/lib/dpkg/arch" 2>/dev/null | tr -d '[:space:]')"
    fi
    if [[ -z "${arch}" ]] && command -v dpkg >/dev/null 2>&1; then
        arch="$(dpkg --root="${rootfs}" --print-architecture 2>/dev/null | tr -d '[:space:]')"
    fi
    if [[ -z "${arch}" ]]; then
        arch="$(_vue_arch_from_elf "${rootfs}/bin/bash")" || arch=''
    fi
    [[ -n "${arch}" ]] || return 1
    printf '%s\n' "${arch}"
}

# Establish that a native chroot probe is possible. Called lazily, immediately
# before the first real probe, so a rootfs whose every interpreter is allowlisted
# needs no chroot at all. Caches into _VUE_PROBE_READY.
#   0 ready   2 hard error
_vue_ensure_probe_ready() {
    local rootfs="$1" tag="$2"
    [[ "${_VUE_PROBE_READY:-}" == "1" ]] && return 0
    [[ "${_VUE_PROBE_READY:-}" == "2" ]] && return 2

    local rarch harch want
    if ! rarch="$(_vue_rootfs_arch "${rootfs}")"; then
        _vue_err "${tag}" "cannot determine the architecture of ${rootfs} (no dpkg data, no readable /bin/bash) — refusing to report a version result this gate did not measure"
        _VUE_PROBE_READY=2
        return 2
    fi
    harch="$(uname -m)"
    want="$(_vue_uname_for_dpkg_arch "${rarch}")"

    # binfmt makes the obvious wording wrong: .github/workflows/build-image.yml
    # installs qemu-user-static and binfmt-support even on the arm64 runner, so a
    # cross-arch `chroot ... --version` can SUCCEED under emulation. The chroot is
    # not broken; the RESULT would not be the device's.
    if [[ "${harch}" != "${want}" ]]; then
        _vue_err "${tag}" "refusing to probe a ${rarch} rootfs from a ${harch} host under emulation — version results would not be the device's"
        _VUE_PROBE_READY=2
        return 2
    fi

    if ! command -v chroot >/dev/null 2>&1 && ! [[ -x /usr/sbin/chroot ]]; then
        _vue_err "${tag}" "chroot is unavailable on this host; the interpreter versions in ${rootfs} cannot be measured"
        _VUE_PROBE_READY=2
        return 2
    fi

    _VUE_PROBE_READY=1
    return 0
}

# Run <abs-path> --version inside the rootfs and echo the raw output.
_vue_raw_probe() {
    local rootfs="$1" path="$2"
    if [[ -n "${ARLOWE_VERSION_PROBE:-}" ]]; then
        "${ARLOWE_VERSION_PROBE}" "${rootfs}" "${path}" 2>/dev/null
        return $?
    fi
    if [[ "${EUID:-$(id -u)}" == "0" ]]; then
        chroot "${rootfs}" "${path}" --version 2>/dev/null
        return $?
    fi
    sudo chroot "${rootfs}" "${path}" --version 2>/dev/null
    return $?
}

# Pull the first dotted-numeric version out of a --version line. Node prints
# "v18.20.4"; python prints "Python 3.11.2".
_vue_parse_version() {
    local raw="$1" first tok
    first="${raw%%$'\n'*}"
    for tok in ${first}; do
        tok="${tok#v}"
        if [[ "${tok}" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
            printf '%s\n' "${tok}"
            return 0
        fi
    done
    return 1
}

verify_unit_runtime_versions() {
    local rootfs="${1:?verify_unit_runtime_versions: <rootfs> required}"
    rootfs="${rootfs%/}"

    _vue_shield_on
    local tag='unit-versions'
    local rc=0 fails=0 skips=0 probes=0 undeclared=0 hard=0
    local unit name directive value stripped exe resolved rrc base lit_base
    local unit_rel urc owner_pkg
    local floor raw got allowed entry
    local -a tokens unit_files=()
    local -A seen_version=()

    _VUE_PROBE_READY=''

    if [[ -n "${ARLOWE_VERSION_PROBE:-}" ]]; then
        _vue_warn "${tag}" "ARLOWE_VERSION_PROBE is set (${ARLOWE_VERSION_PROBE}) — interpreter versions below are STUBBED, not measured."
        _vue_warn "${tag}" "That override exists only for tests/phase-07.1/test-verify-unit-execstart.sh. scripts/build-image.sh asserts it is unset."
    fi

    if ! command -v dpkg >/dev/null 2>&1; then
        _vue_err "${tag}" "dpkg is required for --compare-versions and is not on this host; version floors cannot be evaluated"
        _vue_shield_off
        return 2
    fi

    if ! _vue_unit_dir_readable "${rootfs}" "${tag}"; then
        _vue_shield_off
        return 2
    fi

    if [[ ! -d "${rootfs}/var/lib/dpkg" ]]; then
        _vue_warn "${tag}" "${rootfs} carries no dpkg database, so unit ownership cannot be derived — every unit is held to the version floors as if this repo shipped it. That is the fail-closed direction, and it is said here rather than assumed."
    fi

    while IFS= read -r unit; do
        [[ -n "${unit}" ]] && unit_files+=( "${unit}" )
    done < <(_vue_unit_files "${rootfs}")

    if (( ${#unit_files[@]} == 0 )); then
        _vue_fail "${tag}" "no unit files found under ${rootfs}/etc/systemd/system/ — an empty unit set cannot be a pass"
        _vue_shield_off
        return 1
    fi

    for unit in "${unit_files[@]}"; do
        name="$(basename "${unit}" .service)"

        unit_rel="$(_vue_unit_resolve "${rootfs}" "${unit}")"; urc=$?
        if (( urc == 3 )); then
            _vue_hard_permission "${tag}" "${name}" "${unit#"${rootfs}"}" "${unit_rel}"
            hard=1
            continue
        fi
        if (( urc != 0 )) || [[ ! -f "${rootfs}${unit_rel}" || ! -r "${rootfs}${unit_rel}" ]]; then
            # verify_unit_execstart owns the FAIL for this — it reaches the same
            # conclusion from the same resolve and reporting it twice would
            # double-count one defect. Say it and move on.
            printf '[%s] SKIP %s: unit file does not resolve to a readable file inside the rootfs (chain ends at %s) — see the unit-execstart gate\n' \
                "${tag}" "${name}" "${unit_rel}"
            skips=$(( skips + 1 ))
            continue
        fi

        # SCOPE. Version floors are a claim about software WE chose: node from
        # next@16.1.6's engines.node, the venv pythons we create. apt chose
        # sshd's /bin/kill and ModemManager's binary, and holding those to our
        # table produced six failures about nothing on the 07.2 build. The path
        # gate above stays universal — a unit naming a binary the rootfs lacks
        # is a real defect whoever shipped it — but the floors stop here.
        if owner_pkg="$(_vue_unit_owner "${rootfs}" "${unit#"${rootfs}"}" "${unit_rel}")"; then
            printf '[%s] SKIP %s: shipped by %s — apt owns its interpreter versions, not ARLOWE_RUNTIME_FLOOR\n' \
                "${tag}" "${name}" "${owner_pkg}"
            skips=$(( skips + 1 ))
            continue
        fi

        while IFS=$'\t' read -r directive value; do
            # The '-' tolerance flag is irrelevant here: systemd tolerating a
            # stanza's FAILURE says nothing about whether the interpreter it
            # names is the right version when it does run.
            IFS=$'\t' read -r _ stripped < <(_vue_strip_prefixes "${value}")
            [[ -n "${stripped}" ]] || continue
            # shellcheck disable=SC2206  # deliberate whitespace splitting of a systemd command line
            tokens=( ${stripped} )
            (( ${#tokens[@]} )) || continue
            exe="${tokens[0]}"

            if _vue_is_interpolated "${exe}"; then
                printf '[%s] SKIP %s: %s (env/specifier interpolation)\n' "${tag}" "${name}" "${exe}"
                skips=$(( skips + 1 ))
                continue
            fi
            [[ "${exe}" == /* ]] || continue   # gate 1 owns the non-absolute FAIL

            resolved="$(_vue_resolve "${rootfs}" "${exe}")"; rrc=$?
            if (( rrc == 3 )); then
                _vue_hard_permission "${tag}" "${name}" "${exe}" "${resolved}"
                hard=1
                continue
            fi
            if (( rrc != 0 )); then
                _vue_fail "${tag}" "${name}: cannot resolve ${exe} inside the rootfs, so its version cannot be established"
                fails=$(( fails + 1 ))
                continue
            fi
            base="${resolved##*/}"
            floor="${ARLOWE_RUNTIME_FLOOR[${base}]:-}"

            # Fall back to the basename of the LITERAL token when the resolved
            # one carries no floor.
            #
            # Why this is needed, found by plan 07.1-04's integration run against
            # a real built rootfs: a venv interpreter is a symlink chain.
            #     /opt/arlowe/venvs/voice/bin/python
            #       -> python3 -> /usr/bin/python3 -> /usr/bin/python3.11
            # so the RESOLVED basename is `python3.11`, which is not a key in
            # ARLOWE_RUNTIME_FLOOR, and all seven venv stanzas reported as
            # undeclared interpreters — while the table's own comment above
            # states it covers "/opt/arlowe/venvs/*/bin/python". The lookup and
            # the documented intent disagreed; the fixture self-test could not
            # see it because its interpreters are stubs, not symlinked venvs.
            #
            # Keying on the literal basename loses NO detection power: it selects
            # which floor APPLIES, while the probe below still measures the
            # resolved binary. The /usr/bin/node-is-really-18.20.4 trap is caught
            # exactly as before — `node` floors at 20.9.0 and the probe returns
            # 18.20.4. Resolved-first keeps a path that resolves to a more
            # specific declared name honouring that name.
            if [[ -z "${floor}" ]]; then
                lit_base="${exe##*/}"
                floor="${ARLOWE_RUNTIME_FLOOR[${lit_base}]:-}"
            fi

            if [[ -z "${floor}" ]]; then
                # No declared floor. The LITERAL token — not the resolved path —
                # must be on the allowlist.
                allowed=0
                for entry in "${ARLOWE_EXPECTED_UNDECLARED[@]}"; do
                    [[ "${exe}" == "${entry}" ]] && { allowed=1; break; }
                done
                if (( allowed )); then
                    printf '[%s] UNDECLARED %s: %s\n' "${tag}" "${name}" "${exe}"
                    undeclared=$(( undeclared + 1 ))
                else
                    _vue_fail "${tag}" "${name}: ${exe} is an undeclared interpreter — it has no version floor in ARLOWE_RUNTIME_FLOOR and is not in EXPECTED_UNDECLARED. Declare a floor or add it to the allowlist with a reason."
                    fails=$(( fails + 1 ))
                fi
                continue
            fi

            if [[ -n "${seen_version[${resolved}]:-}" ]]; then
                got="${seen_version[${resolved}]}"
            else
                if [[ -z "${ARLOWE_VERSION_PROBE:-}" ]]; then
                    if ! _vue_ensure_probe_ready "${rootfs}" "${tag}"; then
                        _vue_shield_off
                        return 2
                    fi
                fi
                probes=$(( probes + 1 ))
                if ! raw="$(_vue_raw_probe "${rootfs}" "${resolved}")" || [[ -z "${raw}" ]]; then
                    _vue_fail "${tag}" "${name}: ${exe} did not answer --version inside the rootfs; its version cannot be established"
                    fails=$(( fails + 1 ))
                    continue
                fi
                if ! got="$(_vue_parse_version "${raw}")"; then
                    _vue_fail "${tag}" "${name}: ${exe} emitted an unparseable --version: ${raw%%$'\n'*}"
                    fails=$(( fails + 1 ))
                    continue
                fi
                seen_version["${resolved}"]="${got}"
            fi

            if dpkg --compare-versions "${got}" ge "${floor}"; then
                _vue_ok "${tag}" "${name}: ${exe} reports ${got} (floor ${floor})"
            else
                _vue_fail "${tag}" "${name}: ${exe} reports ${got}, below the declared floor ${floor} — the unit would start and the service would not work"
                fails=$(( fails + 1 ))
            fi
        done < <(_vue_exec_stanzas "${rootfs}${unit_rel}")
    done

    if (( hard )); then
        _vue_err "${tag}" "the gate could not read parts of ${rootfs}, so absence cannot be distinguished from denial. This is neither a pass nor a FAIL."
        _vue_shield_off
        return 2
    fi

    _vue_log "${tag}" "${probes} interpreter(s) probed, ${undeclared} allowlisted undeclared, ${fails} failure(s), ${skips} skip(s)"
    if (( fails > 0 )); then
        _vue_fail "${tag}" "${fails} interpreter version assertion(s) failed"
        rc=1
    else
        _vue_ok "${tag}" "every interpreter named by a unit meets its declared floor in ${rootfs}"
    fi

    _vue_shield_off
    return "${rc}"
}
