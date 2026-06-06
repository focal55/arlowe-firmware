#!/bin/bash
# Phase 3 Docker test harness.
# Builds the testbed image, runs install scripts and assertion scripts inside
# a privileged debian:bookworm-slim container.
#
# Auto-discovery design (important for parallel Wave 2 plans):
#   - Loops over scripts/provision/install-arlowe-*.sh (sorted), skipping any
#     with 'staging' in the name. Plans 03-02/03/04 just drop their installers
#     in scripts/provision/ and this harness picks them up automatically.
#   - Invokes units/install-units.sh if it exists (plan 03-02 owns that file).
#   - Pre-stages CLI marker files if install-arlowe-cli.sh exists (plan 03-04).
#   - Loops over tests/phase-3/assertions/*.sh (sorted) and bash-executes each.
#
# Usage:
#   bash tests/phase-3/docker/run-tests.sh
#
# Options:
#   PHASE_3_TESTBED_KEEP=1   Leave container running for debugging instead of --rm.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
IMAGE="arlowe-phase3-testbed"

echo "=== Phase 3 testbed: building image ==="
docker build -t "${IMAGE}" "${SCRIPT_DIR}"

# Harness body executed inside the container.
# Written as a heredoc so variable expansion happens on the host for path
# substitution, then the whole string is passed to docker as a single -c argument.
HARNESS='
set -euo pipefail
REPO=/arlowe-firmware

echo "--- installing provision scripts (auto-discovery) ---"
# install-arlowe-user.sh always runs first — every other provision script
# depends on the arlowe user existing before it can chown paths.
USER_SCRIPT="${REPO}/scripts/provision/install-arlowe-user.sh"
if [[ -f "${USER_SCRIPT}" ]]; then
    echo "  running install-arlowe-user.sh (prerequisite)"
    bash "${USER_SCRIPT}"
fi

for script in $(ls "${REPO}/scripts/provision/install-arlowe-"*.sh 2>/dev/null | sort); do
    basename_script="$(basename "${script}")"
    # Skip staging variants — those target the dev-Pi side-by-side install, not the testbed.
    if echo "${basename_script}" | grep -q "staging"; then
        echo "  skipping ${basename_script} (staging variant)"
        continue
    fi
    # Skip user script — already ran above as prerequisite.
    if [[ "${basename_script}" == "install-arlowe-user.sh" ]]; then
        continue
    fi
    # Pre-stage CLI markers before invoking the CLI installer so it can symlink to them.
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
    echo "  units/install-units.sh not present (plan 03-02 owns; skipping)"
fi

echo "--- running assertion scripts ---"
failed=0
for assertion in $(ls "${REPO}/tests/phase-3/assertions/"*.sh 2>/dev/null | sort); do
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
echo "=== all assertions passed ==="
'

echo "=== Phase 3 testbed: running harness ==="

if [[ "${PHASE_3_TESTBED_KEEP:-0}" == "1" ]]; then
    # Debug mode: start detached, print container ID for docker exec.
    # --entrypoint overrides the Dockerfile ENTRYPOINT (/sbin/init) so our
    # harness body runs directly rather than as an argument to init.
    container_id=$(docker run -d --privileged \
        --tmpfs /run --tmpfs /tmp \
        --entrypoint /bin/bash \
        -v "${REPO_ROOT}:/arlowe-firmware:ro" \
        "${IMAGE}" \
        -c "${HARNESS}")
    echo "Container started (PHASE_3_TESTBED_KEEP=1): ${container_id}"
    echo "Attach with: docker exec -it ${container_id} bash"
else
    docker run --rm --privileged \
        --tmpfs /run --tmpfs /tmp \
        --entrypoint /bin/bash \
        -v "${REPO_ROOT}:/arlowe-firmware:ro" \
        "${IMAGE}" \
        -c "${HARNESS}"
fi
