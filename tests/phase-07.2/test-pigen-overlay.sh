#!/usr/bin/env bash
# tests/phase-07.2/test-pigen-overlay.sh
#
# Self-test for scripts/lib/pigen-overlay.sh.
#
# Every fixture is synthesised here at runtime under `mktemp -d` and removed on
# exit. Nothing is committed under tests/phase-07.2/ except this script, and
# nothing here touches the network -- the fixture is a fabricated pi-gen tree
# with fabricated upstream content, not a clone. What is under test is the
# APPLIER's logic, which is content-agnostic.
#
# Two of these cases are load-bearing and the rest are scaffolding:
#
#   [idempotence]   the second consecutive apply on an already-overlaid tree.
#                   The build host's pi-gen tree persists, so every build after
#                   the first overlays our own previous output: overlaid files
#                   hash to overlay_sha256 rather than upstream_sha256, and the
#                   NEW entry already exists. An applier that demanded pristine
#                   upstream digests passes its first run and fails every
#                   single one after it.
#
#   [mode-source]   the installed mode is driven by the MANIFEST, not inherited
#                   from the overlay source file. pi-gen guards run scripts with
#                   `[ -x ]` and skips a non-executable one without logging
#                   anything at all, so a lost exec bit is invisible until
#                   first boot.
#
# Runs on Linux (GNU sha256sum, stat -c, install -D), same as the build host.


# This suite needs GNU coreutils: it uses `stat -c` and GNU `sed -i` semantics.
# It runs on the arm64 build host and in CI (ubuntu-24.04-arm), not on macOS --
# BSD stat has no -c and BSD sed -i takes a mandatory suffix argument. Fail with
# that sentence rather than five confusing per-case failures.
if ! stat -c %a . >/dev/null 2>&1; then
    echo "SKIP: this suite requires GNU coreutils (stat -c). Run it on the build host or in CI." >&2
    exit 0
fi

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=scripts/lib/pigen-overlay.sh
source "${REPO_ROOT}/scripts/lib/pigen-overlay.sh"

PASSED=0
FAILED=0

pass() { printf '[PASS] %s\n' "$1"; PASSED=$(( PASSED + 1 )); }
fail() { printf '[FAIL] %s -- %s\n' "$1" "${2:-}"; FAILED=$(( FAILED + 1 )); }

sha() { sha256sum "$1" | awk '{print $1}'; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ---------------------------------------------------------------------------
# Fixture: a fake pi-gen tree plus a fake overlay tree and MANIFEST.
#
# Entry shapes mirror the real overlay: two 755 run scripts with upstream
# counterparts, one 644 data file with an upstream counterpart, and one 644 NEW
# file with none.
#
# make_fixture <dir>  =>  <dir>/pigen and <dir>/overlay
# ---------------------------------------------------------------------------
make_fixture() {
    local root="$1"
    local pg="${root}/pigen" ov="${root}/overlay"
    local p

    mkdir -p "${pg}/stage0/00-configure-apt/files" \
             "${ov}/stage0/00-configure-apt/files"

    # Fabricated upstream content.
    printf '#!/bin/bash -e\nbootstrap rolling-mirror\n' > "${pg}/stage0/prerun.sh"
    printf '#!/bin/bash -e\ninstall -m 644 files/sources.list /etc/apt/\n' \
        > "${pg}/stage0/00-configure-apt/00-run.sh"
    printf 'deb http://rolling.example/debian RELEASE main\n' \
        > "${pg}/stage0/00-configure-apt/files/sources.list"
    chmod 755 "${pg}/stage0/prerun.sh" "${pg}/stage0/00-configure-apt/00-run.sh"
    chmod 644 "${pg}/stage0/00-configure-apt/files/sources.list"

    # Fabricated overlay content: the same files, changed.
    printf '#!/bin/bash -e\nbootstrap pinned-snapshot\n' > "${ov}/stage0/prerun.sh"
    printf '#!/bin/bash -e\ninstall -m 644 files/sources.list /etc/apt/\ninstall -m 644 files/99pinned /etc/apt/apt.conf.d/\n' \
        > "${ov}/stage0/00-configure-apt/00-run.sh"
    printf 'deb http://snapshot.example/archive/debian/TIMESTAMP RELEASE main\n' \
        > "${ov}/stage0/00-configure-apt/files/sources.list"
    printf 'Acquire::Check-Valid-Until "false";\n' \
        > "${ov}/stage0/00-configure-apt/files/99pinned"

    # Deliberately 644 on an entry the MANIFEST declares 755. A checkout that
    # lost the exec bit must still produce an executable run script; the
    # [mode-source] case below is what proves it.
    chmod 644 "${ov}/stage0/prerun.sh"
    chmod 755 "${ov}/stage0/00-configure-apt/00-run.sh"
    chmod 644 "${ov}/stage0/00-configure-apt/files/sources.list" \
              "${ov}/stage0/00-configure-apt/files/99pinned"

    {
        printf '# synthetic fixture manifest\n'
        for p in stage0/prerun.sh stage0/00-configure-apt/00-run.sh; do
            printf '%s\t755\t%s\t%s\n' "$p" "$(sha "${pg}/${p}")" "$(sha "${ov}/${p}")"
        done
        p=stage0/00-configure-apt/files/sources.list
        printf '%s\t644\t%s\t%s\n' "$p" "$(sha "${pg}/${p}")" "$(sha "${ov}/${p}")"
        p=stage0/00-configure-apt/files/99pinned
        printf '%s\t644\tNEW\t%s\n' "$p" "$(sha "${ov}/${p}")"
    } > "${ov}/MANIFEST"
}

# Every overlay entry in the tree hashes to its recorded overlay_sha256.
all_entries_landed() {
    local pg="$1" ov="$2" p m _upstream o
    while IFS=$'\t' read -r p m _upstream o; do
        case "$p" in ''|'#'*) continue;; esac
        [[ -f "${pg}/${p}" ]] || return 1
        [[ "$(sha "${pg}/${p}")" == "$o" ]] || return 1
    done < "${ov}/MANIFEST"
    return 0
}

# ---------------------------------------------------------------------------
# [happy-path] a pristine tree takes the overlay and every entry lands
# ---------------------------------------------------------------------------
R="${WORK}/happy"; make_fixture "$R"
if apply_pigen_overlay "$R/pigen" "$R/overlay" >/dev/null 2>&1 \
   && all_entries_landed "$R/pigen" "$R/overlay"; then
    pass "happy-path"
else
    fail "happy-path" "applier returned non-zero or an entry did not land"
fi

# ---------------------------------------------------------------------------
# [upstream-drift] a third digest -- neither pristine upstream nor our overlay
# -- must stop the build and name the file. This is the PIGEN_REF-bump alarm.
# ---------------------------------------------------------------------------
R="${WORK}/drift"; make_fixture "$R"
printf '# upstream grew a line\n' >> "$R/pigen/stage0/00-configure-apt/files/sources.list"
ERR="$(apply_pigen_overlay "$R/pigen" "$R/overlay" 2>&1 >/dev/null)"
RC=$?
if (( RC != 0 )) && [[ "$ERR" == *"stage0/00-configure-apt/files/sources.list"* ]]; then
    pass "upstream-drift"
else
    fail "upstream-drift" "rc=${RC}, stderr did not name the drifted path"
fi

# ---------------------------------------------------------------------------
# [new-collision] upstream grew a file the MANIFEST records as NEW. Overwriting
# blindly would hide whatever upstream put there.
# ---------------------------------------------------------------------------
R="${WORK}/collision"; make_fixture "$R"
printf 'Acquire::Something "upstream-put-this-here";\n' \
    > "$R/pigen/stage0/00-configure-apt/files/99pinned"
ERR="$(apply_pigen_overlay "$R/pigen" "$R/overlay" 2>&1 >/dev/null)"
RC=$?
if (( RC != 0 )) && [[ "$ERR" == *"99pinned"* ]]; then
    pass "new-collision"
else
    fail "new-collision" "rc=${RC}, stderr did not name the colliding path"
fi

# ---------------------------------------------------------------------------
# [mode-source] the installed mode comes from the MANIFEST, not from the
# overlay source file -- which the fixture deliberately leaves at 644.
# ---------------------------------------------------------------------------
R="${WORK}/mode"; make_fixture "$R"
if apply_pigen_overlay "$R/pigen" "$R/overlay" >/dev/null 2>&1; then
    SRC_MODE="$(stat -c %a "$R/overlay/stage0/prerun.sh")"
    DST_MODE="$(stat -c %a "$R/pigen/stage0/prerun.sh")"
    if [[ "${DST_MODE}" == "755" && "${SRC_MODE}" == "644" ]]; then
        pass "mode-source"
    else
        fail "mode-source" "source=${SRC_MODE} installed=${DST_MODE}, wanted 644 -> 755"
    fi
else
    fail "mode-source" "applier returned non-zero"
fi

# ---------------------------------------------------------------------------
# [mode-assertion-teeth] failure mode 4 is not dead code. A MANIFEST mode that
# `stat -c %a` will never render (leading zero) must be rejected rather than
# quietly accepted -- the same comparison is what catches a lost exec bit.
# ---------------------------------------------------------------------------
R="${WORK}/modeteeth"; make_fixture "$R"
sed -i 's|^stage0/prerun.sh\t755\t|stage0/prerun.sh\t0755\t|' "$R/overlay/MANIFEST"
ERR="$(apply_pigen_overlay "$R/pigen" "$R/overlay" 2>&1 >/dev/null)"
RC=$?
if (( RC != 0 )) && [[ "$ERR" == *"stage0/prerun.sh"* ]]; then
    pass "mode-assertion-teeth"
else
    fail "mode-assertion-teeth" "rc=${RC}, a mode mismatch was not rejected"
fi

# ---------------------------------------------------------------------------
# [idempotence] the case that breaks every build after the first if rules 1
# and 2 do not tolerate an already-overlaid tree.
# ---------------------------------------------------------------------------
R="${WORK}/idem"; make_fixture "$R"
if apply_pigen_overlay "$R/pigen" "$R/overlay" >/dev/null 2>&1; then
    if apply_pigen_overlay "$R/pigen" "$R/overlay" >/dev/null 2>&1 \
       && all_entries_landed "$R/pigen" "$R/overlay"; then
        pass "idempotence"
    else
        fail "idempotence" "second apply on an already-overlaid tree failed"
    fi
else
    fail "idempotence" "first apply failed"
fi

# ---------------------------------------------------------------------------
_exec_bit() { [[ -x "$1" ]] && echo x || echo -; }
_exec_bit_of_mode() { case "$1" in *[1357]) echo x;; *) echo -;; esac; }

# [real-manifest] the shipped overlay's own digests and modes are not stale.
# Nothing else catches a hand-edited overlay file whose digest was not
# re-recorded until a build runs, hours in.
# ---------------------------------------------------------------------------
REAL_STALE=""
while IFS=$'\t' read -r p m _upstream o; do
    case "$p" in ''|'#'*) continue;; esac
    f="${REPO_ROOT}/overlays/pi-gen/${p}"
    if [[ ! -f "$f" ]]; then
        REAL_STALE="${REAL_STALE} missing:${p}"
    elif [[ "$(sha "$f")" != "$o" ]]; then
        REAL_STALE="${REAL_STALE} digest:${p}"
    elif [[ "$(_exec_bit "$f")" != "$(_exec_bit_of_mode "$m")" ]]; then
        # Compare ONLY the executable bit. git tracks 100644 vs 100755 and nothing
        # else; the group/other bits of a checked-out file come from the checking-out
        # user's umask. A umask of 0002 yields 775/664 where 0022 yields 755/644, so
        # comparing the full mode makes this test pass or fail on an environment
        # property rather than on the overlay being stale. The MANIFEST mode is still
        # the mode the applier INSTALLS -- that is the lost-exec-bit defence and is
        # asserted by [mode-source] and [mode-assertion-teeth] against installed files.
        REAL_STALE="${REAL_STALE} execbit:${p}"
    fi
done < "${REPO_ROOT}/overlays/pi-gen/MANIFEST"
if [[ -z "${REAL_STALE}" ]]; then
    pass "real-manifest"
else
    fail "real-manifest" "stale entries:${REAL_STALE}"
fi

printf '\n%d passed, %d failed\n' "${PASSED}" "${FAILED}"
(( FAILED == 0 ))
