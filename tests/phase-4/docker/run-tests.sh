#!/bin/bash
# Phase 4 Docker test harness.
# Reuses the phase-3 Dockerfile (do NOT edit tests/phase-3/docker/run-tests.sh —
# that file belongs to plan 03 and editing it would break file-disjointness).
#
# Validator EXECUTION (running arlowe_config_validate / pytest) is verified on
# the provisioned Pi/staging unit and in 04-01's repo-root pytest run, NOT in
# this Docker testbed. Here we assert install SHAPE only (mode/owner/presence).
# The phase-3 Dockerfile already provides python3, so the image build stays cheap
# and avoids a divergent dep set (no pip-install of jsonschema/PyYAML needed).
#
# Auto-discovery design (mirrors plan 03):
#   - Runs install-arlowe-user.sh first (prerequisite for all other installers).
#   - Loops over scripts/provision/install-arlowe-*.sh (sorted), skipping any
#     with 'staging' in the name (those target the dev-Pi side-by-side install).
#   - Invokes units/install-units.sh if present.
#   - Loops over tests/phase-4/assertions/*.sh and executes each.
#
# Usage:
#   bash tests/phase-4/docker/run-tests.sh
#
# Options:
#   PHASE_4_TESTBED_KEEP=1   Leave container running for debugging instead of --rm.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
IMAGE="arlowe-phase4-testbed"

echo "=== Phase 4 testbed: building image (reusing phase-3 Dockerfile) ==="
docker build -t "${IMAGE}" "${REPO_ROOT}/tests/phase-3/docker"

# Harness body executed inside the container.
HARNESS='
set -euo pipefail
REPO=/arlowe-firmware

echo "--- installing provision scripts (auto-discovery) ---"
USER_SCRIPT="${REPO}/scripts/provision/install-arlowe-user.sh"
if [[ -f "${USER_SCRIPT}" ]]; then
    echo "  running install-arlowe-user.sh (prerequisite)"
    bash "${USER_SCRIPT}"
fi

for script in $(ls "${REPO}/scripts/provision/install-arlowe-"*.sh 2>/dev/null | sort); do
    basename_script="$(basename "${script}")"
    if echo "${basename_script}" | grep -q "staging"; then
        echo "  skipping ${basename_script} (staging variant)"
        continue
    fi
    if [[ "${basename_script}" == "install-arlowe-user.sh" ]]; then
        continue
    fi
    if echo "${basename_script}" | grep -q "install-arlowe-cli"; then
        echo "  pre-staging CLI marker files for ${basename_script}"
        mkdir -p /opt/arlowe/runtime/cli
        for cmd in face speak stt record boot-check purge-logs run-logrotate wake-train; do
            src="${REPO}/runtime/cli/${cmd}"
            dst="/opt/arlowe/runtime/cli/${cmd}"
            if [[ -f "${src}" ]]; then
                cp "${src}" "${dst}"
            else
                touch "${dst}"
            fi
            chmod 0755 "${dst}"
            chown root:arlowe "${dst}" 2>/dev/null || true
        done
    fi
    echo "  running ${basename_script}"
    bash "${script}"
done

echo "--- running units/install-units.sh (if present) ---"
if [[ -f "${REPO}/units/install-units.sh" ]]; then
    bash "${REPO}/units/install-units.sh"
else
    echo "  units/install-units.sh not present (skipping)"
fi

echo "--- running phase-4 assertion scripts ---"
failed=0
for assertion in $(ls "${REPO}/tests/phase-4/assertions/"*.sh 2>/dev/null | sort); do
    echo "  running $(basename "${assertion}")"
    if bash "${assertion}"; then
        echo "  $(basename "${assertion}"): PASS"
    else
        echo "  $(basename "${assertion}"): FAIL" >&2
        failed=$((failed + 1))
    fi
done

if [[ "${failed}" -gt 0 ]]; then
    echo "=== FAIL: ${failed} assertion script(s) failed ===" >&2
    exit 1
fi
echo "=== all phase-4 assertions passed ==="
'

echo "=== Phase 4 testbed: running harness ==="

if [[ "${PHASE_4_TESTBED_KEEP:-0}" == "1" ]]; then
    container_id=$(docker run -d --privileged \
        --tmpfs /run --tmpfs /tmp \
        --entrypoint /bin/bash \
        -v "${REPO_ROOT}:/arlowe-firmware:ro" \
        "${IMAGE}" \
        -c "${HARNESS}")
    echo "Container started (PHASE_4_TESTBED_KEEP=1): ${container_id}"
    echo "Attach with: docker exec -it ${container_id} bash"
else
    docker run --rm --privileged \
        --tmpfs /run --tmpfs /tmp \
        --entrypoint /bin/bash \
        -v "${REPO_ROOT}:/arlowe-firmware:ro" \
        "${IMAGE}" \
        -c "${HARNESS}"
fi
