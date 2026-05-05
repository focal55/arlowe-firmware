#!/usr/bin/env bash
set -euo pipefail

# Hash-check gate for Phase 6 image build.
# Verifies pinned third-party dependencies before proceeding with image build.
#
# Checks:
#   1. axcl_host_aarch64_V3.10.2.deb SHA-256 matches third_party/axcl/manifest.yml
#   2. third_party/ax-llm submodule is initialized at the pinned commit
#
# Usage: scripts/verify-third-party.sh [--help]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MANIFEST="${REPO_ROOT}/third_party/axcl/manifest.yml"
AX_LLM_DIR="${REPO_ROOT}/third_party/ax-llm"
PINNED_AXLLM_COMMIT="df75c34ca2ed8fe55e7576204e4da9c5b5f88ad8"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--help]

Verifies pinned third-party dependencies before image build.

Checks:
  1. axcl_host_aarch64_V3.10.2.deb SHA-256 matches third_party/axcl/manifest.yml
  2. third_party/ax-llm submodule is initialized and at the pinned commit

The .deb file is located via (in order):
  - \$AXCL_DEB environment variable
  - third_party/axcl/axcl_host_aarch64_V3.10.2.deb
  - /var/cache/arlowe-build/axcl_host_aarch64_V3.10.2.deb

If none exist, the script exits non-zero and points at INSTALL.md.

See also:
  third_party/axcl/INSTALL.md
  third_party/axcl/manifest.yml
  third_party/axcl/DISTRIBUTION-RIGHTS.md
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

all_ok=true

# ---------------------------------------------------------------------------
# Read expected SHA-256 from manifest.yml
# ---------------------------------------------------------------------------
if [[ ! -f "${MANIFEST}" ]]; then
  echo >&2 "ERROR: manifest not found at ${MANIFEST}"
  exit 1
fi

expected_sha256=$(python3 -c "
import yaml, sys
with open('${MANIFEST}') as f:
    m = yaml.safe_load(f)
print(m['axcl']['sha256'])
" 2>/dev/null) || {
  echo >&2 "ERROR: failed to parse ${MANIFEST} (is python3-yaml installed?)"
  exit 1
}

expected_filename=$(python3 -c "
import yaml
with open('${MANIFEST}') as f:
    m = yaml.safe_load(f)
print(m['axcl']['filename'])
" 2>/dev/null)

# ---------------------------------------------------------------------------
# Locate the .deb file
# ---------------------------------------------------------------------------
deb_path=""

if [[ -n "${AXCL_DEB:-}" ]]; then
  deb_path="${AXCL_DEB}"
elif [[ -f "${REPO_ROOT}/third_party/axcl/${expected_filename}" ]]; then
  deb_path="${REPO_ROOT}/third_party/axcl/${expected_filename}"
elif [[ -f "/var/cache/arlowe-build/${expected_filename}" ]]; then
  deb_path="/var/cache/arlowe-build/${expected_filename}"
fi

# ---------------------------------------------------------------------------
# Check 1: axcl .deb SHA-256
# ---------------------------------------------------------------------------
if [[ -z "${deb_path}" ]]; then
  printf "${RED}[FAIL]${NC} %s  not found\n" "${expected_filename}"
  echo >&2 "  See third_party/axcl/INSTALL.md for sourcing instructions."
  echo >&2 "  Set AXCL_DEB=/path/to/${expected_filename} or place it at"
  echo >&2 "  /var/cache/arlowe-build/${expected_filename}"
  all_ok=false
else
  actual_sha256=$(sha256sum "${deb_path}" | awk '{print $1}')
  if [[ "${actual_sha256}" == "${expected_sha256}" ]]; then
    printf "${GREEN}[OK]${NC}   %-50s sha256 matches\n" "${expected_filename}"
  else
    printf "${RED}[FAIL]${NC} %-50s sha256 mismatch\n" "${expected_filename}"
    echo >&2 "  Expected: ${expected_sha256}"
    echo >&2 "  Actual:   ${actual_sha256}"
    all_ok=false
  fi
fi

# ---------------------------------------------------------------------------
# Check 2: ax-llm submodule at pinned commit
# ---------------------------------------------------------------------------
if [[ ! -d "${AX_LLM_DIR}/.git" ]] && [[ ! -f "${AX_LLM_DIR}/.git" ]]; then
  printf "${RED}[FAIL]${NC} third_party/ax-llm  submodule not initialized\n"
  echo >&2 "  Run: git submodule update --init third_party/ax-llm"
  all_ok=false
else
  actual_commit=$(git -C "${AX_LLM_DIR}" rev-parse HEAD 2>/dev/null || echo "unknown")
  short_pin="${PINNED_AXLLM_COMMIT:0:8}"
  if [[ "${actual_commit}" == "${PINNED_AXLLM_COMMIT}" ]]; then
    printf "${GREEN}[OK]${NC}   %-50s @ %s\n" "third_party/ax-llm" "${short_pin}"
  else
    printf "${RED}[FAIL]${NC} %-50s commit mismatch\n" "third_party/ax-llm"
    echo >&2 "  Expected: ${PINNED_AXLLM_COMMIT}"
    echo >&2 "  Actual:   ${actual_commit}"
    echo >&2 "  Run: git -C third_party/ax-llm checkout ${PINNED_AXLLM_COMMIT}"
    all_ok=false
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ "${all_ok}" == "true" ]]; then
  printf "${GREEN}All checks passed.${NC}\n"
  exit 0
else
  printf "${RED}One or more checks failed.${NC}\n"
  exit 1
fi
