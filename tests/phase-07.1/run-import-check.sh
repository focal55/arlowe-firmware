#!/usr/bin/env bash
# SC4 gate driver: build the image's package set in a container, then run the
# import-graph checker once per unit under that unit's OWN interpreter and OWN
# declared PYTHONPATH.
#
# Runs the wake-gate suite (plan 07.1-02) in the same container invocation too, so
# the factory-state test is exercised against the image's package set and not only
# against the minimal python3+pytest environment it was written in.
#
# Usage:
#   tests/phase-07.1/run-import-check.sh
#   ARLOWE_DROP_PACKAGES=python3-pil tests/phase-07.1/run-import-check.sh   # watch it fail
#
# Environment:
#   ARLOWE_DROP_PACKAGES   space-separated packages to remove from the derived apt
#                          set. Only for proving the gate has teeth; unset normally.
#   ARLOWE_IMPORT_IMAGE    image tag to build/use.
#   ARLOWE_PLATFORM        container platform. arm64 by default and it matters:
#                          python3-rpi.gpio and python3-spidev have no amd64 build.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

PLATFORM="${ARLOWE_PLATFORM:-linux/arm64}"
DROP="${ARLOWE_DROP_PACKAGES:-}"
IMAGE="${ARLOWE_IMPORT_IMAGE:-arlowe-import-check:bookworm}"
if [[ -n "${DROP}" ]]; then
    # A deliberately crippled image must never be reused as if it were the real
    # one, so it gets its own tag.
    IMAGE="${IMAGE}-dropped"
fi

# Unit directories. Both are shipping unit sources: units/ holds the seven service
# units install-units.sh installs, and the firstboot stage carries its own.
UNIT_DIRS=(units pi-gen/stage-arlowe/03-firstboot/files)
UNIT_ARGS=()
for d in "${UNIT_DIRS[@]}"; do UNIT_ARGS+=(--units "${d}"); done

log() { printf '\n[run-import-check] %s\n' "$*"; }

log "building ${IMAGE} for ${PLATFORM}"
docker build \
    --platform "${PLATFORM}" \
    --build-arg "ARLOWE_DROP_PACKAGES=${DROP}" \
    -f tests/phase-07.1/docker/Dockerfile \
    -t "${IMAGE}" \
    "${REPO_ROOT}"

run_in_container() {
    docker run --rm --platform "${PLATFORM}" \
        -v "${REPO_ROOT}:/repo:ro" -w /repo "${IMAGE}" "$@"
}

# ---------------------------------------------------------------------------
# The unit -> interpreter -> PYTHONPATH table is DERIVED, by the same code that
# does the walking. `--list-units` reads each unit's Exec* line for the
# interpreter (or the entry script's shebang, which is how the system-python
# arlowe-identity-init is covered) and its Environment=PYTHONPATH= for the path.
# Restating the mapping here would be a second source of truth for which venv a
# unit runs under, and those differ per unit by design.
# ---------------------------------------------------------------------------
log "deriving the unit -> interpreter -> PYTHONPATH table from the units"
TABLE="$(run_in_container python3 tests/phase-07.1/import-graph.py \
            "${UNIT_ARGS[@]}" --runtime runtime --repo-root . --list-units)"
printf '%s\n' "${TABLE}"

rc=0
while IFS=$'\t' read -r unit interp pypath; do
    [[ -n "${unit}" ]] || continue
    log "=== ${unit} under ${interp} (PYTHONPATH=${pypath:-<unset>}) ==="
    if ! docker run --rm --platform "${PLATFORM}" \
            -v "${REPO_ROOT}:/repo:ro" -w /repo \
            -e "PYTHONPATH=${pypath}" "${IMAGE}" \
            "${interp}" -c 'import sys; sys.exit(0)' 2>/dev/null; then
        printf '[run-import-check] FAIL %s: interpreter %s is not runnable in the image\n' \
            "${unit}" "${interp}" >&2
        rc=1
        continue
    fi
    if ! docker run --rm --platform "${PLATFORM}" \
            -v "${REPO_ROOT}:/repo:ro" -w /repo \
            -e "PYTHONPATH=${pypath}" "${IMAGE}" \
            python3 tests/phase-07.1/import-graph.py \
                "${UNIT_ARGS[@]}" --runtime runtime --repo-root . \
                --unit "${unit}" --python "${interp}"; then
        rc=1
    fi
done <<< "${TABLE}"

# ---------------------------------------------------------------------------
# Plan 07.1-02's wake-gate suite, in the same container.
#
# It is stdlib-only by construction and was verified in a container carrying only
# python3 + python3-pytest. Running it here as well answers a different question:
# whether it still passes with the image's FULL package set present. A module that
# is importable on the device but not in the minimal environment could change what
# the suite exercises, and nothing would have noticed.
#
# PYTHONPATH=runtime, not runtime/lib: `voice` is a PEP 420 namespace package under
# runtime/. runtime/voice/tests deliberately has no __init__.py (07.1-02 decision 1)
# so it cannot collide with runtime/lib/tests' top-level `tests` package.
# ---------------------------------------------------------------------------
#
# -p no:cacheprovider because the repo is bind-mounted read-only: the checker only
# reads, and a test run that can write into the working tree is a test run that can
# change what the next one sees.
log "=== wake-gate suite (07.1-02) against the image's package set ==="
if ! run_in_container env PYTHONPATH=runtime PYTHONDONTWRITEBYTECODE=1 \
        python3 -m pytest runtime/voice/tests/ -q -p no:cacheprovider; then
    rc=1
fi

if [[ "${rc}" -ne 0 ]]; then
    log "FAIL: see the per-unit reports above"
else
    log "OK: every import reachable from a unit entry point resolves under that unit's interpreter"
fi
exit "${rc}"
