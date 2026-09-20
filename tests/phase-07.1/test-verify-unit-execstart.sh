#!/usr/bin/env bash
# tests/phase-07.1/test-verify-unit-execstart.sh
#
# Self-test for scripts/lib/verify-unit-execstart.sh.
#
# Every fixture rootfs is built here at runtime under `mktemp -d` and removed on
# exit. Nothing is committed under tests/phase-07.1/ except this script.
#
# Two of these cases are load-bearing and everything else is scaffolding:
#
#   [prefix-image]  reproduces the rootfs this phase exists to repair — the real
#                   shipping units over the empty /opt/arlowe tree that
#                   scripts/provision/install-arlowe-fs.sh leaves behind — and
#                   proves verify_unit_execstart names each missing venv
#                   interpreter and the dashboard entry point.
#   [node18-trap]   takes a rootfs where EVERY path resolves, pins a Node 18.20.4
#                   at the dashboard unit's own ExecStart path, and proves
#                   verify_unit_runtime_versions fails it. That is the exact shape
#                   of the image on the bench today: nothing is missing, and the
#                   dashboard still cannot start.
#   [unit-read-escape]
#                   proves the gate reads UNIT FILES inside the rootfs. Seven of
#                   the fifteen units on a real rootfs are `systemctl enable`
#                   aliases — symlinks with absolute targets — and following one
#                   on the build host is a gate that can false-PASS as easily as
#                   it false-failed.
#
# The fixture rootfs used to be synthetic in a way that hid both: no apt-installed
# units and no dpkg database, so neither the alias-symlink shape nor the ownership
# split had anything to act on. [apt-owned-scope] and its two companions carry a
# real (if minimal) dpkg database for that reason — the ownership lookup under test
# runs against dpkg itself, not a stub.
#
# No assertion here depends on a COUNT of failures. An earlier draft of this phase
# said "five venv-python lines", which is wrong on both readings — three distinct
# interpreter paths across seven Exec* stanzas — and a count assertion turns a
# miscount into a green test. The assertions name paths.
#
# Runs on every pull request via .github/workflows/pr-checks.yml. No arm64 runner
# and no chroot are required: the version cases go through ARLOWE_VERSION_PROBE
# stubs and the path cases are pure filesystem.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/lib/verify-unit-execstart.sh"

# The interpreter arlowe-dashboard.service names, READ FROM THE UNIT rather than
# restated here. The fixtures below copy the repo's real units/*.service, so a
# hardcoded path silently decouples the test from the thing under test: this file
# used to say /usr/bin/node, and when plan 07.1-04 repointed the unit at the
# vendored Node prefix, seven cases failed for a reason that had nothing to do
# with the behaviour they cover. Derive it, and the test follows the unit.
DASH_NODE="$(awk -F'[= ]' '/^ExecStart=/{print $2; exit}' \
    "${REPO_ROOT}/units/arlowe-dashboard.service")"
if [[ -z "${DASH_NODE}" ]]; then
    echo "cannot read ExecStart from units/arlowe-dashboard.service" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$(( FAILURES + 1 )); }

assert_rc() {  # assert_rc <want> <got> <case>
    if [[ "$2" == "$1" ]]; then pass "$3 (exit $2)"; else bad "$3 (expected exit $1, got $2)"; fi
}
assert_out() {  # assert_out <file> <needle> <case>
    if grep -qF -- "$2" "$1"; then pass "$3"; else bad "$3 — output did not contain: $2"; fi
}
assert_no_out() {  # assert_no_out <file> <needle> <case>
    if grep -qF -- "$2" "$1"; then bad "$3 — output unexpectedly contained: $2"; else pass "$3"; fi
}

# run_gate <fn> <rootfs> <label>  -> sets RC, and OUT to a captured stdout+stderr file
run_gate() {
    OUT="${WORK}/out-$3.log"
    "$1" "$2" >"${OUT}" 2>&1
    RC=$?
}

evidence() {  # evidence <label> <file>
    printf '\n----- evidence: %s -----\n' "$1"
    cat "$2"
    printf -- '----- end evidence: %s -----\n\n' "$1"
}

mkexec() { mkdir -p "$(dirname "$1")"; printf '#!/bin/sh\nexit 0\n' > "$1"; chmod 0755 "$1"; }
mkfile() { mkdir -p "$(dirname "$1")"; : > "$1"; }

new_rootfs() {
    local r="${WORK}/$1"
    mkdir -p "${r}/etc/systemd/system"
    printf '%s\n' "${r}"
}

# A fixture unit with an arbitrary body. write_unit <rootfs> <name> <line>...
write_unit() {
    local r="$1" n="$2"; shift 2
    write_unit_at "${r}/etc/systemd/system/${n}.service" "${n}" "$@"
}

# The same body at an arbitrary path, so a fixture can put a unit somewhere an
# alias symlink points at. write_unit_at <path> <name> <line>...
write_unit_at() {
    local p="$1" n="$2"; shift 2
    mkdir -p "$(dirname "${p}")"
    { printf '[Unit]\nDescription=fixture %s\n\n[Service]\n' "${n}"
      printf '%s\n' "$@"
    } > "${p}"
}

# A minimal but REAL dpkg database, so the ownership lookup under test runs
# against dpkg itself rather than a stub. dpkg -S needs both an info/<pkg>.list
# and a status stanza marking the package installed; a .list alone finds
# nothing. add_dpkg_pkg <rootfs> <pkg> <owned-path>...
add_dpkg_pkg() {
    local r="$1" pkg="$2"; shift 2
    mkdir -p "${r}/var/lib/dpkg/info"
    printf 'Package: %s\nStatus: install ok installed\nMaintainer: fixture <fixture@invalid>\nArchitecture: all\nVersion: 1.0\nDescription: fixture\n\n' \
        "${pkg}" >> "${r}/var/lib/dpkg/status"
    printf '%s\n' "$@" > "${r}/var/lib/dpkg/info/${pkg}.list"
}

# ---------------------------------------------------------------------------
# Version probe stub. Stands in for `chroot <rootfs> <path> --version` so the
# fixtures can pin an interpreter version without shipping an arm64 binary.
# ---------------------------------------------------------------------------
PROBE_STUB="${WORK}/probe-stub.sh"
cat > "${PROBE_STUB}" <<'STUB'
#!/usr/bin/env bash
# $1 = rootfs, $2 = resolved absolute path inside it
case "$2" in
    */node)    printf '%s\n' "${STUB_NODE_VERSION:-v20.19.0}" ;;
    */python*) printf 'Python %s\n' "${STUB_PYTHON_VERSION:-3.11.2}" ;;
    *)         exit 1 ;;
esac
STUB
chmod 0755 "${PROBE_STUB}"
export STUB_NODE_VERSION STUB_PYTHON_VERSION

# ===========================================================================
# [prefix-image] — the rootfs this phase exists to repair
#
# Real shipping units over the tree install-arlowe-fs.sh leaves: the runtime
# subdirectories and /opt/arlowe/venvs exist but are EMPTY. Node and touch are
# present (packages installed them); the two first-party entry points that really
# do exist today are present; nothing else is.
# ===========================================================================
PREFIX="$(new_rootfs prefix-image)"
cp "${REPO_ROOT}"/units/*.service "${PREFIX}/etc/systemd/system/"
mkdir -p "${PREFIX}/opt/arlowe/runtime/voice" \
         "${PREFIX}/opt/arlowe/runtime/face" \
         "${PREFIX}/opt/arlowe/runtime/stt" \
         "${PREFIX}/opt/arlowe/runtime/llm" \
         "${PREFIX}/opt/arlowe/runtime/dashboard" \
         "${PREFIX}/opt/arlowe/runtime/cli" \
         "${PREFIX}/opt/arlowe/venvs"
mkexec "${PREFIX}${DASH_NODE}"
mkexec "${PREFIX}/bin/touch"
mkexec "${PREFIX}/opt/arlowe/runtime/llm/run_api.sh"
mkexec "${PREFIX}/opt/arlowe/runtime/cli/identity"

run_gate verify_unit_execstart "${PREFIX}" prefix-image
evidence "prefix-image / verify_unit_execstart" "${OUT}"
assert_rc 1 "${RC}" "[prefix-image] pre-fix rootfs FAILS verify_unit_execstart"
# Three distinct interpreter paths spanning seven Exec* stanzas, plus the
# dashboard entry point. Named individually; never counted.
assert_out "${OUT}" '/opt/arlowe/venvs/voice/bin/python' \
    "[prefix-image] names the voice venv interpreter (arlowe-voice + arlowe-face, 4 stanzas)"
assert_out "${OUT}" '/opt/arlowe/venvs/llm/bin/python' \
    "[prefix-image] names the llm venv interpreter (qwen-tokenizer, 2 stanzas)"
assert_out "${OUT}" '/opt/arlowe/venvs/stt/bin/python' \
    "[prefix-image] names the stt venv interpreter (whisper-stt, 1 stanza)"
assert_out "${OUT}" '/opt/arlowe/runtime/dashboard/server.js' \
    "[prefix-image] names the dashboard entry point"
# qwen-api execs run_api.sh, which touches no Python. It must NOT be implicated.
assert_no_out "${OUT}" 'FAIL qwen-api' \
    "[prefix-image] does not implicate qwen-api, whose ExecStart is a shell wrapper that exists"

# ===========================================================================
# [repaired-image] — same units, targets present
# ===========================================================================
FIXED="$(new_rootfs repaired-image)"
cp -a "${PREFIX}/." "${FIXED}/"
for venv in voice llm stt; do mkexec "${FIXED}/opt/arlowe/venvs/${venv}/bin/python"; done
mkfile "${FIXED}/opt/arlowe/runtime/dashboard/server.js"
mkfile "${FIXED}/opt/arlowe/runtime/stt/stt_server.py"
mkfile "${FIXED}/opt/arlowe/runtime/llm/qwen2.5_tokenizer_uid.py"

run_gate verify_unit_execstart "${FIXED}" repaired-image
assert_rc 0 "${RC}" "[repaired-image] every Exec* target present PASSES verify_unit_execstart"

# ===========================================================================
# [node18-trap] — every path resolves; the interpreter is the wrong one
# ===========================================================================
export ARLOWE_VERSION_PROBE="${PROBE_STUB}"
STUB_NODE_VERSION='v18.20.4'
STUB_PYTHON_VERSION='3.11.2'

run_gate verify_unit_runtime_versions "${FIXED}" node18-trap
evidence "node18-trap / verify_unit_runtime_versions" "${OUT}"
assert_rc 1 "${RC}" "[node18-trap] bookworm Node 18.20.4 at the dashboard ExecStart path FAILS"
assert_out "${OUT}" 'arlowe-dashboard' "[node18-trap] names the arlowe-dashboard unit"
assert_out "${OUT}" "${DASH_NODE}"    "[node18-trap] names the ExecStart path"
assert_out "${OUT}" '18.20.4'          "[node18-trap] names the observed version"
assert_out "${OUT}" '20.9.0'           "[node18-trap] names the declared floor"

STUB_NODE_VERSION='v20.19.0'
run_gate verify_unit_runtime_versions "${FIXED}" node20-ok
assert_rc 0 "${RC}" "[node20-ok] Node 20.19.0 at the same path PASSES"

# ===========================================================================
# [python-floor] — the same assertion on the venv interpreters
# ===========================================================================
STUB_PYTHON_VERSION='3.11.2'
run_gate verify_unit_runtime_versions "${FIXED}" python-ok
assert_rc 0 "${RC}" "[python-floor] Python 3.11.2 in every venv PASSES"

STUB_PYTHON_VERSION='3.9.2'
run_gate verify_unit_runtime_versions "${FIXED}" python-old
assert_rc 1 "${RC}" "[python-floor] Python 3.9.2 in the venvs FAILS"
assert_out "${OUT}" '/opt/arlowe/venvs/stt/bin/python' "[python-floor] names the venv interpreter path"
assert_out "${OUT}" 'whisper-stt' "[python-floor] names the unit"
assert_out "${OUT}" '3.11.0' "[python-floor] names the declared floor"
STUB_PYTHON_VERSION='3.11.2'

# ===========================================================================
# [dangling-symlink] — the F7 #21 shape, plus proof the gate is not reading the
# build host's filesystem through an absolute symlink target.
# ===========================================================================
DANGLE="$(new_rootfs dangling-symlink)"
mkdir -p "${DANGLE}/usr/local/sbin" "${DANGLE}/opt/arlowe/runtime/cli"
ln -s /opt/arlowe/runtime/cli/nonexistent "${DANGLE}/usr/local/sbin/arlowe-x"
write_unit "${DANGLE}" arlowe-x 'ExecStart=/usr/local/sbin/arlowe-x'
run_gate verify_unit_execstart "${DANGLE}" dangling-symlink
assert_rc 1 "${RC}" "[dangling-symlink] a dangling absolute symlink FAILS"
assert_out "${OUT}" '/usr/local/sbin/arlowe-x' "[dangling-symlink] names the ExecStart token"
assert_out "${OUT}" '/opt/arlowe/runtime/cli/nonexistent' "[dangling-symlink] names where the chain ends"

# /bin/ls exists on every Linux build host and nowhere in this fixture. If the
# gate resolved absolute symlink targets against the HOST's root instead of
# re-rooting them, this case would pass and the gate would be worthless.
ESCAPE="$(new_rootfs host-escape)"
mkdir -p "${ESCAPE}/usr/local/sbin"
ln -s /bin/ls "${ESCAPE}/usr/local/sbin/arlowe-escape"
write_unit "${ESCAPE}" arlowe-escape 'ExecStart=/usr/local/sbin/arlowe-escape'
run_gate verify_unit_execstart "${ESCAPE}" host-escape
assert_rc 1 "${RC}" "[host-escape] an absolute symlink to a host path absent from the rootfs FAILS"

# ===========================================================================
# [resolving-symlink] — the re-rooting works in the passing direction too
# ===========================================================================
LINKOK="$(new_rootfs resolving-symlink)"
mkexec "${LINKOK}/opt/arlowe/runtime/cli/real"
mkdir -p "${LINKOK}/usr/local/sbin"
ln -s /opt/arlowe/runtime/cli/real "${LINKOK}/usr/local/sbin/arlowe-y"
write_unit "${LINKOK}" arlowe-y 'ExecStart=/usr/local/sbin/arlowe-y'
run_gate verify_unit_execstart "${LINKOK}" resolving-symlink
assert_rc 0 "${RC}" "[resolving-symlink] an absolute symlink resolving inside the rootfs PASSES"

# ===========================================================================
# [interpolation] — unresolvable tokens are SKIPped explicitly, never silently
# ===========================================================================
INTERP="$(new_rootfs interpolation)"
mkexec "${INTERP}/usr/bin/env"
# shellcheck disable=SC2016  # the ${FOO} is systemd's, and must reach the unit file unexpanded
write_unit "${INTERP}" arlowe-interp 'ExecStart=/usr/bin/env ${FOO}/bin/thing'
run_gate verify_unit_execstart "${INTERP}" interpolation
assert_rc 0 "${RC}" "[interpolation] an interpolated argument does not fail the gate"
assert_out "${OUT}" 'SKIP arlowe-interp' "[interpolation] the token is reported as an explicit SKIP"
assert_out "${OUT}" '1 skip(s)' "[interpolation] the skip is counted in the summary line"

# ===========================================================================
# [tolerated] — a '-' prefixed stanza WARNs rather than FAILs, and is printed
# ===========================================================================
TOLER="$(new_rootfs tolerated)"
mkexec "${TOLER}/opt/arlowe/runtime/cli/real"
write_unit "${TOLER}" arlowe-tol \
    'ExecStartPre=-/opt/arlowe/missing' \
    'ExecStart=/opt/arlowe/runtime/cli/real'
run_gate verify_unit_execstart "${TOLER}" tolerated
assert_rc 0 "${RC}" "[tolerated] a '-' prefixed missing target does not fail the gate"
assert_out "${OUT}" 'WARN' "[tolerated] it is still reported, as a WARN"
assert_out "${OUT}" '/opt/arlowe/missing' "[tolerated] the WARN names the missing target"

# ===========================================================================
# [no-units] — an empty expectation set is the defect class this gate closes
# ===========================================================================
EMPTY="$(new_rootfs no-units)"
run_gate verify_unit_execstart "${EMPTY}" no-units
assert_rc 1 "${RC}" "[no-units] a rootfs with zero units FAILS"
assert_out "${OUT}" 'an empty unit set cannot be a pass' "[no-units] with its own distinct message"

# ===========================================================================
# [allowlisted-undeclared] — a first-party entry point with no version floor is
# named, not gated. No probe override here: a rootfs whose every interpreter is
# allowlisted must need no chroot at all.
# ===========================================================================
unset ARLOWE_VERSION_PROBE
ALLOW="$(new_rootfs allowlisted-undeclared)"
mkexec "${ALLOW}/opt/arlowe/runtime/llm/run_api.sh"
write_unit "${ALLOW}" qwen-api 'ExecStart=/opt/arlowe/runtime/llm/run_api.sh'
run_gate verify_unit_runtime_versions "${ALLOW}" allowlisted-undeclared
assert_rc 0 "${RC}" "[allowlisted-undeclared] an EXPECTED_UNDECLARED entry PASSES without a probe"
assert_out "${OUT}" 'UNDECLARED qwen-api: /opt/arlowe/runtime/llm/run_api.sh' \
    "[allowlisted-undeclared] it is reported by name"

# ===========================================================================
# [unlisted-interpreter] — the load-bearing half of that pair. A new interpreter
# must not be able to arrive as one more line in an already-green category.
# ===========================================================================
PERL="$(new_rootfs unlisted-interpreter)"
mkexec "${PERL}/usr/bin/perl"
mkfile "${PERL}/opt/arlowe/runtime/x.pl"
write_unit "${PERL}" arlowe-perl 'ExecStart=/usr/bin/perl /opt/arlowe/runtime/x.pl'
run_gate verify_unit_runtime_versions "${PERL}" unlisted-interpreter
evidence "unlisted-interpreter / verify_unit_runtime_versions" "${OUT}"
assert_rc 1 "${RC}" "[unlisted-interpreter] an interpreter in neither table FAILS"
assert_out "${OUT}" '/usr/bin/perl' "[unlisted-interpreter] names the interpreter"
assert_out "${OUT}" 'arlowe-perl' "[unlisted-interpreter] names the unit"

# ===========================================================================
# [usrmerge] — the allowlist matches the LITERAL token, not the resolved path.
# Bookworm ships /bin as a symlink to usr/bin, so /bin/touch resolves to
# /usr/bin/touch; keying on the resolved path would make the allowlist disagree
# with what a reviewer reads in the unit file.
# ===========================================================================
USRM="$(new_rootfs usrmerge)"
mkexec "${USRM}/usr/bin/touch"
ln -s usr/bin "${USRM}/bin"
write_unit "${USRM}" arlowe-firstboot 'ExecStartPost=/bin/touch /var/lib/arlowe/.firstboot-done'
run_gate verify_unit_execstart "${USRM}" usrmerge-paths
assert_rc 0 "${RC}" "[usrmerge] the path gate traverses /bin -> usr/bin"
run_gate verify_unit_runtime_versions "${USRM}" usrmerge-versions
assert_rc 0 "${RC}" "[usrmerge] /bin/touch is allowlisted on its literal token"
assert_out "${OUT}" 'UNDECLARED arlowe-firstboot: /bin/touch' \
    "[usrmerge] the report shows the literal token, not /usr/bin/touch"

# ===========================================================================
# [unprobeable] — a test that cannot be performed is a HARD ERROR. Not a SKIP,
# not a PASS. The message must blame emulation, not chroot: build-image.yml
# installs qemu-user-static on the arm64 runner, so a cross-arch probe would
# SUCCEED and report a version that is not the device's.
# ===========================================================================
FOREIGN="$(new_rootfs unprobeable)"
mkexec "${FOREIGN}/usr/bin/node"
mkfile "${FOREIGN}/opt/arlowe/runtime/dashboard/server.js"
mkdir -p "${FOREIGN}/var/lib/dpkg"
printf 's390x\n' > "${FOREIGN}/var/lib/dpkg/arch"
write_unit "${FOREIGN}" arlowe-dashboard 'ExecStart=/usr/bin/node /opt/arlowe/runtime/dashboard/server.js'
run_gate verify_unit_runtime_versions "${FOREIGN}" unprobeable
assert_rc 2 "${RC}" "[unprobeable] a foreign-architecture rootfs is a HARD ERROR, distinct from FAIL"
assert_out "${OUT}" 'refusing to probe a s390x rootfs' "[unprobeable] names both architectures"
assert_out "${OUT}" 'under emulation — version results would not be the device' \
    "[unprobeable] blames emulation rather than implying chroot is broken"
assert_no_out "${OUT}" 'OK' "[unprobeable] nothing is reported as passing"

# ===========================================================================
# [permission-wall] — an unsearchable directory is a HARD ERROR, not a FAIL.
# install-arlowe-fs.sh creates /opt/arlowe 0750 root:arlowe, so an unprivileged
# run against a real rootfs hits this on every target in the tree. Reporting it
# as "missing" would be a gate failing for the wrong reason on every build.
# Skipped when running as root, where the mode is unenforceable.
# ===========================================================================
if [[ "$(id -u)" == "0" ]]; then
    printf 'SKIP: [permission-wall] not meaningful as root (mode bits do not apply)\n'
else
    DENY="$(new_rootfs permission-wall)"
    mkexec "${DENY}/opt/arlowe/runtime/cli/thing"
    write_unit "${DENY}" arlowe-deny 'ExecStart=/opt/arlowe/runtime/cli/thing'
    chmod 0640 "${DENY}/opt/arlowe"
    run_gate verify_unit_execstart "${DENY}" permission-wall
    chmod 0755 "${DENY}/opt/arlowe"
    assert_rc 2 "${RC}" "[permission-wall] an unsearchable directory is a HARD ERROR"
    assert_out "${OUT}" 'cannot search inside the rootfs' "[permission-wall] names the denial"
    assert_no_out "${OUT}" 'missing in rootfs' "[permission-wall] does not report the target as missing"
fi

# ===========================================================================
# [probe-override-is-loud] — an exported ARLOWE_VERSION_PROBE announces itself,
# so an accidental export cannot make a build's gate quietly lie.
# ===========================================================================
export ARLOWE_VERSION_PROBE="${PROBE_STUB}"
run_gate verify_unit_runtime_versions "${FIXED}" probe-override-is-loud
assert_out "${OUT}" 'ARLOWE_VERSION_PROBE is set' "[probe-override-is-loud] the override is announced"
assert_out "${OUT}" 'STUBBED, not measured' "[probe-override-is-loud] the results are marked as stubbed"
unset ARLOWE_VERSION_PROBE

# ===========================================================================
# [unit-read-escape] — THE load-bearing case of this fix.
#
# Seven of the fifteen units on a real rootfs are `systemctl enable` dbus
# aliases: symlinks in /etc/systemd/system whose target is ABSOLUTE
# (sshd.service -> /lib/systemd/system/ssh.service). Reading the glob entry
# directly hands that absolute path to the kernel, which follows it on the BUILD
# HOST — so the gate parsed the host's trixie units and judged a bookworm rootfs
# by them.
#
# The fixture makes the two readings disagree on purpose. The alias points at
# /bin/ls, which exists on every build host as a BINARY carrying no Exec*
# stanzas, and inside the rootfs is a real unit naming a target that is absent.
#   escaping to the host -> zero stanzas parsed -> the gate PASSES, silently
#   reading rootfs-relative -> the missing target is named -> the gate FAILS
# The false-PASS is the direction that matters: a host that happens to carry
# what the image lacks would make this gate report clean, which is the exact
# class it exists to catch.
# ===========================================================================
ESCREAD="$(new_rootfs unit-read-escape)"
write_unit_at "${ESCREAD}/bin/ls" arlowe-aliased \
    'ExecStart=/opt/arlowe/runtime/cli/rootfs-only-target'
ln -s /bin/ls "${ESCREAD}/etc/systemd/system/dbus-org.fixture.Aliased.service"
run_gate verify_unit_execstart "${ESCREAD}" unit-read-escape
evidence "unit-read-escape / verify_unit_execstart" "${OUT}"
assert_rc 1 "${RC}" "[unit-read-escape] an absolute alias is read inside the rootfs, not on the host"
assert_out "${OUT}" '/opt/arlowe/runtime/cli/rootfs-only-target' \
    "[unit-read-escape] names the target the ROOTFS unit declares"
assert_out "${OUT}" 'dbus-org.fixture.Aliased' \
    "[unit-read-escape] reports it under the INSTALLED alias name, which is what systemd loads"

# ===========================================================================
# [apt-owned-scope] — version floors are a claim about software WE chose.
#
# Built to the real rootfs's shape: usrmerged (/lib -> usr/lib, /bin -> usr/bin),
# the unit reached through an absolute alias symlink, and dpkg recording the
# target under its pre-merge /lib spelling while the rootfs resolves it to
# /usr/lib. The usrmerge twin lookup is load-bearing here — without it the
# ownership query misses every apt unit on a bookworm rootfs and the scoping
# silently does nothing.
#
# /bin/kill has no floor and never will: it is sshd's, not ours. Before this
# fix that was a FAIL, one of six on the 07.2 build.
# ===========================================================================
OWNED="$(new_rootfs apt-owned-scope)"
ln -s usr/lib "${OWNED}/lib"
ln -s usr/bin "${OWNED}/bin"
mkexec "${OWNED}/usr/sbin/arlowe-fixture-daemon"
mkexec "${OWNED}/usr/bin/kill"
# shellcheck disable=SC2016  # $MAINPID is systemd's, and must reach the unit file unexpanded
write_unit_at "${OWNED}/usr/lib/systemd/system/arlowe-fixture-daemon.service" arlowe-fixture-daemon \
    'ExecStart=/usr/sbin/arlowe-fixture-daemon' \
    'ExecReload=/bin/kill -HUP $MAINPID'
ln -s /lib/systemd/system/arlowe-fixture-daemon.service \
    "${OWNED}/etc/systemd/system/dbus-org.fixture.Daemon.service"
add_dpkg_pkg "${OWNED}" arlowe-fixture-daemon \
    '/lib/systemd/system/arlowe-fixture-daemon.service' \
    '/usr/sbin/arlowe-fixture-daemon'

# A SECOND apt unit, shipped as a REGULAR FILE straight into /etc/systemd/system.
# Two reasons it is here rather than left implicit:
#
#   * It isolates this defect from the alias-read one. The alias above is
#     dangling from the build host's point of view, so the pre-fix gate dropped
#     it from the glob entirely and "failed" with an empty unit set — a fixture
#     that fails for the wrong reason proves nothing about the right one. This
#     unit is enumerated by the old code and the new alike, so the only thing
#     that changes between them is the scoping.
#   * It is the case that rules out the cheaper signal. On the real rootfs every
#     repo unit is a regular file and every apt unit is a symlink, so file type
#     separates them today — and would separate them wrongly the first time an
#     apt package ships a unit exactly like this one. Ownership is asked of
#     dpkg, so this unit is apt's no matter what shape it arrives in.
mkexec "${OWNED}/usr/sbin/arlowe-fixture-plain"
# shellcheck disable=SC2016  # $MAINPID is systemd's, and must reach the unit file unexpanded
write_unit "${OWNED}" arlowe-fixture-plain \
    'ExecStart=/usr/sbin/arlowe-fixture-plain' \
    'ExecReload=/bin/kill -HUP $MAINPID'
add_dpkg_pkg "${OWNED}" arlowe-fixture-plain \
    '/etc/systemd/system/arlowe-fixture-plain.service' \
    '/usr/sbin/arlowe-fixture-plain'

run_gate verify_unit_runtime_versions "${OWNED}" apt-owned-scope
evidence "apt-owned-scope / verify_unit_runtime_versions" "${OUT}"
assert_rc 0 "${RC}" "[apt-owned-scope] an apt-owned unit naming an unfloored interpreter PASSES"
assert_out "${OUT}" 'SKIP dbus-org.fixture.Daemon: shipped by arlowe-fixture-daemon' \
    "[apt-owned-scope] the alias unit is skipped, named with its owning package"
assert_out "${OUT}" 'SKIP arlowe-fixture-plain: shipped by arlowe-fixture-plain' \
    "[apt-owned-scope] so is the regular-file apt unit — ownership is dpkg's answer, not the file type"
assert_no_out "${OUT}" 'undeclared interpreter' \
    "[apt-owned-scope] /bin/kill is not demanded of a daemon we did not choose"
assert_no_out "${OUT}" 'no dpkg database' \
    "[apt-owned-scope] ownership was derived, not degraded to the fail-closed default"

run_gate verify_unit_execstart "${OWNED}" apt-owned-paths
assert_rc 0 "${RC}" "[apt-owned-scope] the path gate still reads the apt unit and finds its targets"

# ===========================================================================
# [repo-owned-still-gated] — the anti-slip half, and the reason scoping is not
# loosening. Scoping the version gate must not give OUR units a way through it:
# an arlowe unit naming an undeclared interpreter still FAILs, in a rootfs where
# the dpkg database is present and working.
# ===========================================================================
MIXED="$(new_rootfs repo-owned-still-gated)"
cp -a "${OWNED}/." "${MIXED}/"
mkexec "${MIXED}/usr/bin/perl"
mkfile "${MIXED}/opt/arlowe/runtime/x.pl"
write_unit "${MIXED}" arlowe-perl 'ExecStart=/usr/bin/perl /opt/arlowe/runtime/x.pl'

run_gate verify_unit_runtime_versions "${MIXED}" repo-owned-still-gated
evidence "repo-owned-still-gated / verify_unit_runtime_versions" "${OUT}"
assert_rc 1 "${RC}" "[repo-owned-still-gated] an undeclared interpreter in a unit WE ship still FAILS"
assert_out "${OUT}" 'FAIL arlowe-perl' "[repo-owned-still-gated] names our unit"
assert_out "${OUT}" '/usr/bin/perl'    "[repo-owned-still-gated] names the interpreter"
assert_no_out "${OUT}" 'FAIL dbus-org.fixture.Daemon' \
    "[repo-owned-still-gated] and does not implicate the apt alias unit in the same rootfs"
assert_no_out "${OUT}" 'FAIL arlowe-fixture-plain' \
    "[repo-owned-still-gated] nor the apt regular-file unit beside it"

# ===========================================================================
# [path-gate-stays-universal] — a unit naming a binary the rootfs does not carry
# is a real defect whoever shipped it. Both directions asserted: narrowing the
# PATH gate to repo units the way the version gate was narrowed would let an apt
# unit's missing binary through, and that is a bricked service on the device.
# ===========================================================================
MISSING="$(new_rootfs path-gate-stays-universal)"
cp -a "${OWNED}/." "${MISSING}/"
rm -f "${MISSING}/usr/sbin/arlowe-fixture-daemon"
write_unit "${MISSING}" arlowe-ours 'ExecStart=/opt/arlowe/runtime/cli/absent'

run_gate verify_unit_execstart "${MISSING}" path-gate-stays-universal
evidence "path-gate-stays-universal / verify_unit_execstart" "${OUT}"
assert_rc 1 "${RC}" "[path-gate-stays-universal] a missing Exec* target FAILS"
assert_out "${OUT}" 'FAIL arlowe-ours' \
    "[path-gate-stays-universal] our unit's missing binary is named"
assert_out "${OUT}" '/opt/arlowe/runtime/cli/absent' \
    "[path-gate-stays-universal] with the target it declares"
assert_out "${OUT}" 'FAIL dbus-org.fixture.Daemon' \
    "[path-gate-stays-universal] the apt unit's missing binary is named too — ownership does not excuse it"
assert_out "${OUT}" '/usr/sbin/arlowe-fixture-daemon' \
    "[path-gate-stays-universal] with the target it declares"

echo "------------------------------------------------------------"
if (( FAILURES != 0 )); then
    echo "${FAILURES} case(s) failed" >&2
    exit 1
fi
echo "verify-unit-execstart: all cases passed"
