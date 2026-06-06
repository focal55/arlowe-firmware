#!/bin/bash
# Diagnostic: extract the axcl deb to a temp dir and print any udev rules
# it would install. Used at planning/audit time to confirm 90-arlowe-axera.rules
# doesn't conflict with the deb's postinst. NOT invoked by install scripts.
#
# Purpose:
#   When Phase 6's pi-gen build installs axcl_host_aarch64_V3.10.2.deb, the
#   deb's postinst may install its own /etc/udev/rules.d/* files for the Axera
#   devices. If those rules conflict with our 90-arlowe-axera.rules (e.g., they
#   chown to `video` group instead of our `arlowe` group), we need to know at
#   plan time, not at Phase 6 build time.
#
# Usage:
#   bash extract-axcl-udev-from-deb.sh [path/to/axcl_host.deb]
#   Defaults to inspecting third_party/axcl/<pinned-deb-name> per manifest.yml.
#
# Exit codes:
#   0 — ran successfully (deb inspected; findings printed to stdout)
#   1 — usage error or unexpected condition
#   2 — deb not present at the resolved path (user-supplied-file Strategy C case)
#
# Requires: dpkg-deb (Debian/Ubuntu), mktemp, find, grep.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

DEB_PATH="${1:-}"

if [[ -z "${DEB_PATH}" ]]; then
    # Resolve from third_party/axcl/manifest.yml.
    MANIFEST="${REPO_ROOT}/third_party/axcl/manifest.yml"
    if [[ ! -f "${MANIFEST}" ]]; then
        echo "[extract-axcl-udev] manifest not found at ${MANIFEST}" >&2
        echo "Pass the deb path explicitly: bash extract-axcl-udev-from-deb.sh /path/to/axcl_host.deb" >&2
        exit 1
    fi
    # manifest.yml has key `filename:` (not `file:`); parse that.
    DEB_NAME=$(grep -E '^\s+filename:' "${MANIFEST}" | head -1 | awk '{print $2}' | tr -d '"')
    if [[ -z "${DEB_NAME}" ]]; then
        echo "[extract-axcl-udev] could not parse filename from ${MANIFEST}" >&2
        echo "Manifest content:" >&2
        cat "${MANIFEST}" >&2
        exit 1
    fi
    DEB_PATH="${REPO_ROOT}/third_party/axcl/${DEB_NAME}"
fi

if [[ ! -f "${DEB_PATH}" ]]; then
    echo "[extract-axcl-udev] axcl deb not present at: ${DEB_PATH}"
    echo ""
    echo "Per third_party/axcl/manifest.yml (Strategy C: user-supplied), the deb"
    echo "is not redistributed in this repo. Obtain it from Axera and place it at"
    echo "the path above (see third_party/axcl/INSTALL.md), then re-run this script."
    echo ""
    echo "Plan 03-03 ships provision/udev/90-arlowe-axera.rules with the assumption"
    echo "that the deb does NOT ship conflicting rules. Run this diagnostic once the"
    echo "deb is available to confirm. Plan 03-05 hardware verification will catch"
    echo "any remaining conflict."
    exit 2
fi

# Ensure dpkg-deb is available.
if ! command -v dpkg-deb >/dev/null 2>&1; then
    echo "[extract-axcl-udev] dpkg-deb not found; install dpkg on the host" >&2
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

echo "[extract-axcl-udev] inspecting: ${DEB_PATH}"
echo ""

dpkg-deb -x "${DEB_PATH}" "${TMP}/contents"
dpkg-deb -e "${DEB_PATH}" "${TMP}/control"

echo "=== Searching for udev rules in deb contents ==="
udev_files=$(find "${TMP}/contents" -path '*udev*' -type f 2>/dev/null)
if [[ -n "${udev_files}" ]]; then
    while IFS= read -r f; do
        echo "--- ${f} ---"
        cat "${f}"
        echo ""
    done <<< "${udev_files}"
else
    echo "(none found)"
fi

echo ""
echo "=== Searching control scripts (postinst, postrm, prerm, preinst) for udev/chown ==="
for script in "${TMP}/control/"{postinst,postrm,prerm,preinst}; do
    if [[ -f "${script}" ]]; then
        echo "--- $(basename "${script}") ---"
        grep -nE 'udev|chown|chmod|MKNOD|/dev/' "${script}" || echo "(none)"
        echo ""
    fi
done

echo ""
echo "=== Summary ==="
RULE_COUNT=$(find "${TMP}/contents" -path '*udev*' -type f 2>/dev/null | wc -l)
echo "udev rule files found in deb: ${RULE_COUNT}"
echo ""
if [[ "${RULE_COUNT}" -eq 0 ]]; then
    echo "Decision: deb ships no udev rules — provision/udev/90-arlowe-axera.rules"
    echo "          has no conflict. Ship as-is."
else
    echo "Decision: review the rules above."
    echo "  - If the deb's rules match our group (arlowe) and mode (0660): redundant but harmless."
    echo "  - If they conflict (different group or mode): keep ours (90- loads after typical 60s)"
    echo "    and add a comment in 90-arlowe-axera.rules explaining the override."
    echo "  - If they conflict on device path: raise a CHECKPOINT before the Phase 6 image build."
fi
