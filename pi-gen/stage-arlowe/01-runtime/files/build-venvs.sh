#!/bin/bash
# Populate /opt/arlowe/venvs/{voice,llm,stt} inside the pi-gen chroot.
#
# Runs as root, INSIDE the rootfs chroot, from 00-run-chroot.sh. It is the step
# that closes the gap plan 07.1-04 exists for: four shipping units name a venv
# interpreter in their Exec* stanzas and, until this script existed, nothing in
# the image pipeline ever created one. `grep -rn venv pi-gen/stage-arlowe/`
# returned only the apt package name.
#
# WHY --system-site-packages (ADR-0008, not a local style choice).
# Every compiled extension Debian packages -- numpy, scipy, scikit-learn, joblib,
# Pillow, PyAudio -- is installed by the apt layer in
# pi-gen/stage-arlowe/00-packages/00-packages-nr and SHARED into all three venvs.
# The venvs carry only the pip residue Debian does not package. Two consequences,
# both load-bearing:
#   1. Nothing has to compile under the emulated cross-arch chroot, so the build
#      behaves the same on the native-arm64 CI runner and on the build host.
#   2. One numpy exists in the image. The system-python consumers
#      (arlowe-identity-init, boot-check) and the venv consumers agree about array
#      layout. constraints.txt pins numpy to the apt candidate precisely so pip
#      cannot install a second one over the top.
# Do not drop --system-site-packages without amending ADR-0008.
#
# REQUIREMENT FILES. Resolved through exactly one variable. Its DEFAULT is the
# path the chroot really receives; the override exists so plan 07.1-05's test
# container can invoke this same script instead of forking it. A fixture path
# baked in here would produce a script that passes its container verify and fails
# every real build, so there is no second path anywhere below.
#
# The files arrive because host-side 01-runtime/00-run.sh stages
# `pi-gen/stage-arlowe/01-runtime/files` into ${CHROOT_REPO}. If you move this
# directory, move that staging-loop entry in the same commit.
set -euo pipefail

ARLOWE_VENV_REQ_DIR="${ARLOWE_VENV_REQ_DIR:-/root/arlowe-build/repo/pi-gen/stage-arlowe/01-runtime/files/venv-requirements}"
ARLOWE_VENV_ROOT="${ARLOWE_VENV_ROOT:-/opt/arlowe/venvs}"

VENVS=(voice llm stt)

log()  { printf '[build-venvs] %s\n' "$*"; }
fail() { printf '[build-venvs] ERROR: %s\n' "$*" >&2; exit 1; }

# Distribution names declared in a requirements file, one per line: comments and
# blank lines dropped, the version specifier stripped. Used to derive which
# `pip check` complaints a --no-deps install is EXPECTED to produce, so that set
# is computed from the pinned files rather than restated in a second list here.
req_packages() {
    sed 's/#.*//' "$1" | tr -d '[:blank:]' | grep -v '^$' | sed 's/[<>=!~[].*//'
}

# ---------------------------------------------------------------------------
# Gate the inputs before touching pip.
#
# A pip invocation against a nonexistent `-r` path fails with a message that
# reads like a network problem, which is how a staging mistake becomes an hour
# of debugging the wrong layer. Name the resolved directory in the failure.
# ---------------------------------------------------------------------------
[[ -d "${ARLOWE_VENV_REQ_DIR}" ]] \
    || fail "requirement directory not found: ${ARLOWE_VENV_REQ_DIR} (host-side 00-run.sh must stage pi-gen/stage-arlowe/01-runtime/files into the chroot)"

# Five files, not four: the voice venv is installed in two passes. See below.
for req in constraints.txt voice.txt voice-nodeps.txt llm.txt stt.txt; do
    [[ -f "${ARLOWE_VENV_REQ_DIR}/${req}" ]] \
        || fail "missing requirement file: ${ARLOWE_VENV_REQ_DIR}/${req}"
done

getent group arlowe >/dev/null 2>&1 \
    || fail "group 'arlowe' not found; install-arlowe-user.sh must run first"

command -v python3 >/dev/null 2>&1 || fail "python3 not found in the chroot"
python3 -c 'import venv' 2>/dev/null || fail "python3-venv not installed (declare it in 00-packages-nr)"

log "requirement dir: ${ARLOWE_VENV_REQ_DIR}"
log "venv root:       ${ARLOWE_VENV_ROOT}"
log "base python:     $(python3 --version 2>&1)"

install -d -o root -g arlowe -m 0755 "${ARLOWE_VENV_ROOT}"

CONSTRAINTS="${ARLOWE_VENV_REQ_DIR}/constraints.txt"

# Keep pip quiet about its own upgrades and off the network cache. --no-cache-dir
# also keeps ~/.cache/pip out of the image, which the reproducibility cleanup
# would otherwise have to chase.
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_ROOT_USER_ACTION=ignore

for name in "${VENVS[@]}"; do
    venv="${ARLOWE_VENV_ROOT}/${name}"
    log "=== creating ${venv} (--system-site-packages) ==="

    rm -rf "${venv}"
    python3 -m venv --system-site-packages "${venv}" \
        || fail "venv creation failed for ${name}"

    log "--- installing ${name}.txt ---"
    "${venv}/bin/pip" install --no-cache-dir \
        -r "${ARLOWE_VENV_REQ_DIR}/${name}.txt" -c "${CONSTRAINTS}" \
        || fail "pip install failed for ${name} (-r ${ARLOWE_VENV_REQ_DIR}/${name}.txt)"

    # -----------------------------------------------------------------------
    # A venv with a companion <name>-nodeps.txt takes a SECOND pass, and skipping
    # it is the easiest way to break this script silently. Today only voice has
    # one; the condition is on the FILE, not on the name, so adding a second one
    # is a file drop rather than an edit here.
    #
    # noisereduce==3.0.3 declares matplotlib, which drags contourpy, cycler,
    # fonttools, kiwisolver, pyparsing, python-dateutil and six. voice_client.py
    # calls only nr.reduce_noise(), which touches none of it: measured at 170 MB
    # with the declared chain versus 96 MB without, and both A and B slots carry
    # the venv, so it is ~148 MB of card.
    #
    # It is a separate FILE rather than a comment in voice.txt because `--no-deps`
    # is not a valid requirements-file directive -- pip rejects it outright with
    # "no such option: --no-deps". It is a command-line flag applying to the whole
    # invocation, so the packages that need it must be installed separately from
    # the packages that must keep their resolver.
    #
    # Running only the first pass yields a voice venv where `import noisereduce`
    # raises ModuleNotFoundError, and every path gate in the build still passes.
    # -----------------------------------------------------------------------
    nodeps_req="${ARLOWE_VENV_REQ_DIR}/${name}-nodeps.txt"
    if [[ -f "${nodeps_req}" ]]; then
        log "--- installing ${name}-nodeps.txt (--no-deps) ---"
        "${venv}/bin/pip" install --no-cache-dir --no-deps \
            -r "${nodeps_req}" -c "${CONSTRAINTS}" \
            || fail "pip install failed for ${name}-nodeps (-r ${nodeps_req})"
    fi
done

# ---------------------------------------------------------------------------
# Ownership and permissions, matching the rest of /opt/arlowe.
#
# install-arlowe-fs.sh uses root:arlowe 0755 throughout. The units run as
# User=arlowe under ProtectSystem=strict, so the interpreters must be executable
# by that user and NOTHING under the venv root may be writable at runtime --
# a writable interpreter tree under a service account is a privilege-escalation
# surface, and the units never need to write here.
# ---------------------------------------------------------------------------
log "=== setting ownership root:arlowe and stripping non-owner write bits ==="
chown -R root:arlowe "${ARLOWE_VENV_ROOT}"
chmod 0755 "${ARLOWE_VENV_ROOT}"
# g+rX,o+rX preserves the execute bit on directories and on already-executable
# files without granting it to plain data files; go-w removes every non-owner
# write bit pip may have left behind.
chmod -R g+rX,o+rX,go-w "${ARLOWE_VENV_ROOT}"

# ---------------------------------------------------------------------------
# Assert here, in-script. Do NOT defer this to plan 07.1-03's outer gate: that
# gate runs late in the build, and a venv that failed to install should stop the
# build at the step that produced it, not four steps later in a different script.
# ---------------------------------------------------------------------------
log "=== verifying ==="
_rc=0
check_out=""; tolerated_subjects=""; unexpected=""; subject=""; line=""
for name in "${VENVS[@]}"; do
    venv="${ARLOWE_VENV_ROOT}/${name}"

    if [[ ! -x "${venv}/bin/python" ]]; then
        printf '[build-venvs] FAIL %s: %s/bin/python missing or not executable\n' "${name}" "${venv}" >&2
        _rc=1
        continue
    fi

    # -----------------------------------------------------------------------
    # pip check, with ONE narrow tolerance that is derived, not hand-written.
    #
    # The --no-deps pass above deliberately omits dependencies that pip still has
    # a metadata record of, so pip check necessarily complains about them:
    #
    #     noisereduce 3.0.3 requires matplotlib, which is not installed.
    #
    # That line is the ADR-0008 decision working as recorded, not a defect. But
    # "ignore pip check on the voice venv" would throw away the gate entirely, and
    # a hand-maintained list of tolerated strings is a second place to forget.
    #
    # So the tolerated SUBJECTS are computed from <name>-nodeps.txt itself: a
    # complaint is tolerated only when the package MAKING it is one we installed
    # with --no-deps. A complaint about any other package -- including a genuinely
    # broken resolve in the same venv -- is still a hard failure, and a future
    # noisereduce bump that acquires a real new dependency shows up as a new
    # subject rather than disappearing into an allowlist.
    #
    # Tolerated is not invisible: every tolerated line is printed.
    # -----------------------------------------------------------------------
    check_out="$("${venv}/bin/pip" check 2>&1)" || true
    tolerated_subjects=''
    if [[ -f "${ARLOWE_VENV_REQ_DIR}/${name}-nodeps.txt" ]]; then
        tolerated_subjects="$(req_packages "${ARLOWE_VENV_REQ_DIR}/${name}-nodeps.txt")"
    fi

    unexpected=''
    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        [[ "${line}" == "No broken requirements found."* ]] && continue
        subject="${line%% *}"
        if [[ -n "${tolerated_subjects}" ]] \
           && printf '%s\n' "${tolerated_subjects}" | grep -qixF "${subject}"; then
            printf '[build-venvs] EXPECTED %s: %s (installed --no-deps per ADR-0008)\n' "${name}" "${line}"
            continue
        fi
        unexpected+="${line}"$'\n'
    done <<< "${check_out}"

    if [[ -n "${unexpected}" ]]; then
        printf '[build-venvs] FAIL %s: pip check reports broken dependencies:\n%s' "${name}" "${unexpected}" >&2
        _rc=1
    else
        log "${name}: pip check clean (modulo the --no-deps edges above)"
    fi

    # FROZEN.txt is the on-device record of what was installed. A support engineer
    # reading a failed device should not have to reconstruct it from the build log
    # of an image that shipped months ago. --local excludes the shared apt modules,
    # so this file is exactly the venv's own residue.
    "${venv}/bin/pip" freeze --local > "${venv}/FROZEN.txt"
    chown root:arlowe "${venv}/FROZEN.txt"
    chmod 0644 "${venv}/FROZEN.txt"

    log "--- ${name} FROZEN.txt ---"
    cat "${venv}/FROZEN.txt"
    log "--- ${name} interpreter: $("${venv}/bin/python" --version 2>&1) ---"
done

[[ "${_rc}" -eq 0 ]] || fail "one or more venvs failed verification"

log "venv sizes:"
du -sh "${ARLOWE_VENV_ROOT}"/* "${ARLOWE_VENV_ROOT}"
log "complete"
