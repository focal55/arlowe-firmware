#!/usr/bin/env bash
# scripts/lib/pigen-overlay.sh
#
# Apply the tracked arlowe overlay (overlays/pi-gen/) onto a provisioned upstream
# pi-gen tree, asserting that every entry actually landed.
#
# Why this exists: scripts/build-image.sh re-clones upstream pi-gen at PIGEN_REF
# and restores only config/ and stage-arlowe/. Several upstream-owned files carry
# build inputs we need pinned. Editing them inside pi-gen/ is erased on the next
# re-provision -- and erased SILENTLY, which is the failure shape this whole
# mechanism exists to make impossible.
#
# A `sed -i` patch step was rejected: it becomes a no-op the day upstream's text
# changes, which is the same silent-green defect. A whole-file copy plus a digest
# assertion cannot no-op -- either the bytes are there or the build stops.
#
# MANIFEST format -- one tab-separated record per entry, `#` lines are comments:
#
#     path<TAB>mode<TAB>upstream_sha256<TAB>overlay_sha256
#
#   path             relative to the pi-gen root
#   mode             octal, asserted after the copy (see failure mode 4)
#   upstream_sha256  digest of the upstream file at PIGEN_REF, or the literal
#                    string NEW when the entry has no upstream counterpart
#   overlay_sha256   digest of our overlay file
#
# Four distinct failure modes, each a hard stop naming the offending path:
#
#   1. Upstream drift     the target is neither pristine-upstream nor our own
#                         prior output. PIGEN_REF moved under the pin.
#   2. NEW collision      upstream grew a file we intended to add.
#   3. Copy did not land  the installed bytes do not match overlay_sha256.
#   4. Mode did not land  pi-gen's run_stage/run_sub_stage guard with `[ -x ]`,
#                         so a run script that lands without its exec bit is
#                         skipped in TOTAL silence -- pi-gen logs nothing at all.
#
# Rules 1 and 2 both tolerate an already-overlaid tree on purpose. The build
# host's pi-gen tree persists across builds, so every build after the first
# applies over our own previous output. An applier that demanded pristine
# upstream digests would fail every second build.
#
# Consequence worth stating plainly: the upstream-drift alarm is a RE-CLONE path
# alarm. On a cached tree the applier sees overlay_sha256 and accepts it. What
# trips rule 1 is a PIGEN_REF bump, not an ordinary build.
#
# Sourceable: defines functions only, no top-level side effects.
#
# Host requirements: GNU coreutils (sha256sum, stat -c, install -D). This runs on
# the arm64 Linux build host and in CI; it is not expected to run on macOS.

_pigen_overlay_ok() {
    printf '\033[0;32m[OK]\033[0m   %s\n' "$*"
}

_pigen_overlay_fail() {
    printf '\033[0;31m[FAIL]\033[0m %s\n' "$*" >&2
}

_pigen_overlay_sha256() {
    sha256sum "$1" | awk '{print $1}'
}

# apply_pigen_overlay <pi_gen_dir> <overlay_dir>
#
# Returns 0 when every MANIFEST entry is installed and verified, 1 otherwise.
apply_pigen_overlay() {
    local pi_gen_dir="${1:-}"
    local overlay_dir="${2:-}"

    if [[ -z "${pi_gen_dir}" || -z "${overlay_dir}" ]]; then
        _pigen_overlay_fail "apply_pigen_overlay: usage: apply_pigen_overlay <pi_gen_dir> <overlay_dir>"
        return 1
    fi

    if [[ ! -d "${pi_gen_dir}" ]]; then
        _pigen_overlay_fail "apply_pigen_overlay: pi-gen tree not found: ${pi_gen_dir}"
        return 1
    fi

    local manifest="${overlay_dir}/MANIFEST"
    if [[ ! -f "${manifest}" ]]; then
        _pigen_overlay_fail "apply_pigen_overlay: overlay MANIFEST not found: ${manifest}"
        return 1
    fi

    local path mode upstream overlay extra
    local src dst actual actual_mode
    local applied=0

    while IFS=$'\t' read -r path mode upstream overlay extra; do
        case "${path}" in ''|'#'*) continue;; esac

        if [[ -z "${mode}" || -z "${upstream}" || -z "${overlay}" || -n "${extra}" ]]; then
            _pigen_overlay_fail "MANIFEST record for '${path}' is malformed."
            _pigen_overlay_fail "Expected exactly 4 tab-separated fields: path mode upstream_sha256 overlay_sha256"
            return 1
        fi

        src="${overlay_dir}/${path}"
        dst="${pi_gen_dir}/${path}"

        if [[ ! -f "${src}" ]]; then
            _pigen_overlay_fail "Overlay source missing: ${src}"
            _pigen_overlay_fail "The MANIFEST lists ${path} but no such file exists under ${overlay_dir}."
            _pigen_overlay_fail "If the file looks present on disk, check that it is TRACKED by git -- an"
            _pigen_overlay_fail "untracked overlay file is absent from every CI checkout."
            return 1
        fi

        actual=""
        if [[ -f "${dst}" ]]; then
            actual="$(_pigen_overlay_sha256 "${dst}")"
        fi

        # --- pre-copy assertions -------------------------------------------
        if [[ "${upstream}" == "NEW" ]]; then
            # Failure mode 2: upstream grew a file we intended to add. A file
            # hashing to overlay_sha256 is our own prior apply and is fine.
            if [[ -n "${actual}" && "${actual}" != "${overlay}" ]]; then
                _pigen_overlay_fail "Unexpected pre-existing file: ${path}"
                _pigen_overlay_fail "The MANIFEST records this entry as NEW, but the pi-gen tree already"
                _pigen_overlay_fail "carries a file at that path with different content."
                _pigen_overlay_fail "Overwriting it blindly would hide whatever upstream put there."
                _pigen_overlay_fail "Read ${dst}, decide whether the overlay is still correct, then record"
                _pigen_overlay_fail "its upstream digest in the MANIFEST instead of NEW."
                return 1
            fi
        else
            # Failure mode 1: the target is neither pristine upstream nor our
            # own prior output.
            if [[ -z "${actual}" ]]; then
                _pigen_overlay_fail "Overlay target missing from the pi-gen tree: ${path}"
                _pigen_overlay_fail "The MANIFEST records an upstream digest for this path, so upstream"
                _pigen_overlay_fail "pi-gen at PIGEN_REF is expected to ship it. It is not there."
                _pigen_overlay_fail "Upstream most likely removed or moved the file at the current"
                _pigen_overlay_fail "PIGEN_REF. Re-read the upstream tree and re-record this entry."
                return 1
            fi
            if [[ "${actual}" != "${upstream}" && "${actual}" != "${overlay}" ]]; then
                _pigen_overlay_fail "Upstream pi-gen changed under the pin: ${path}"
                _pigen_overlay_fail "  expected upstream: ${upstream}"
                _pigen_overlay_fail "  or our overlay:    ${overlay}"
                _pigen_overlay_fail "  found:             ${actual}"
                _pigen_overlay_fail "PIGEN_REF has moved, or this pi-gen tree was edited by hand."
                _pigen_overlay_fail "The overlay was written against the recorded upstream version; applying"
                _pigen_overlay_fail "it now would silently revert whatever upstream changed."
                _pigen_overlay_fail "Re-read the upstream file, decide whether the overlay still carries the"
                _pigen_overlay_fail "right change, update the overlay if needed, and re-record the digest."
                _pigen_overlay_fail "Do NOT delete this check -- it is the only thing that notices the revert."
                return 1
            fi
        fi

        # --- copy ----------------------------------------------------------
        if ! install -m "${mode}" -D "${src}" "${dst}"; then
            _pigen_overlay_fail "Failed to install overlay entry: ${path}"
            return 1
        fi

        # --- post-copy assertions ------------------------------------------
        # Failure mode 3: the copy did not land.
        actual="$(_pigen_overlay_sha256 "${dst}")"
        if [[ "${actual}" != "${overlay}" ]]; then
            _pigen_overlay_fail "Overlay entry did not land: ${path}"
            _pigen_overlay_fail "  expected: ${overlay}"
            _pigen_overlay_fail "  found:    ${actual}"
            _pigen_overlay_fail "Either the MANIFEST's overlay_sha256 is stale or the copy was clobbered."
            return 1
        fi

        # Failure mode 4: the mode did not land. pi-gen skips a non-executable
        # run script without logging anything.
        actual_mode="$(stat -c %a "${dst}")"
        if [[ "${actual_mode}" != "${mode}" ]]; then
            _pigen_overlay_fail "Overlay entry landed with the wrong mode: ${path}"
            _pigen_overlay_fail "  expected: ${mode}"
            _pigen_overlay_fail "  found:    ${actual_mode}"
            _pigen_overlay_fail "pi-gen guards run scripts with [ -x ] and skips them in silence."
            return 1
        fi

        _pigen_overlay_ok "overlay ${path} (mode ${mode})"
        applied=$(( applied + 1 ))
    done < "${manifest}"

    if (( applied == 0 )); then
        _pigen_overlay_fail "Overlay MANIFEST holds no entries: ${manifest}"
        _pigen_overlay_fail "An empty overlay would let an unpinned build pass as though it were pinned."
        return 1
    fi

    _pigen_overlay_ok "overlay applied: ${applied} entries verified in ${pi_gen_dir}"
    return 0
}
