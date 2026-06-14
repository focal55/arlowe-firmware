#!/usr/bin/env bash
# shellcheck disable=SC2059
set -euo pipefail

# Hash-check gate for Phase 6 image build.
# Verifies pinned third-party dependencies before proceeding with image build.
#
# Checks:
#   1. axcl_host_aarch64_V3.10.2.deb SHA-256 matches third_party/axcl/manifest.yml
#   2. third_party/ax-llm submodule is initialized at the pinned commit
#   3. Model artifacts (Qwen LLM, Whisper STT, Piper TTS) in third_party/models/manifest.yml
#   4. WhisPlay driver source (WhisPlay.py + LICENSE) is locatable
#
# Usage: scripts/verify-third-party.sh [--help]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MANIFEST="${REPO_ROOT}/third_party/axcl/manifest.yml"
MODELS_MANIFEST="${REPO_ROOT}/third_party/models/manifest.yml"
AX_LLM_DIR="${REPO_ROOT}/third_party/ax-llm"
PINNED_AXLLM_COMMIT="df75c34ca2ed8fe55e7576204e4da9c5b5f88ad8"

# install_to paths in the manifest are image-absolute: /opt/arlowe/models/<subpath>.
# The gate strips this prefix to get the subpath, then searches under the configured roots.
MODELS_IMAGE_PREFIX="/opt/arlowe/models"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--help]

Verifies pinned third-party dependencies before image build.

Checks:
  1. axcl_host_aarch64_V3.10.2.deb SHA-256 matches third_party/axcl/manifest.yml
  2. third_party/ax-llm submodule is initialized and at the pinned commit
  3. Model artifacts (Qwen LLM, Whisper STT, Piper TTS) per third_party/models/manifest.yml
  4. WhisPlay driver source (WhisPlay.py + LICENSE) is locatable

Model artifact search order (per artifact, using install_to subpath from manifest):
  - \$ARLOWE_MODELS_DIR/<install_to-subpath>
  - third_party/models/<install_to-subpath>
  - /var/cache/arlowe-build/models/<install_to-subpath>

The install_to subpath is derived by stripping the image-side prefix
(${MODELS_IMAGE_PREFIX}) from each manifest's install_to field.
This ensures the gate locates artifacts at the same relative path the
runtime units read — no separate "search name" that can drift from install_to.

WhisPlay driver search order:
  - \$ARLOWE_WHISPLAY_SRC/WhisPlay.py
  - third_party/whisplay-driver/WhisPlay.py
  - /var/cache/arlowe-build/whisplay-driver/WhisPlay.py

See also:
  third_party/axcl/INSTALL.md
  third_party/axcl/manifest.yml
  third_party/axcl/DISTRIBUTION-RIGHTS.md
  third_party/models/manifest.yml
  third_party/models/INSTALL.md
  third_party/whisplay-driver/INSTALL.md
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

all_ok=true

# ---------------------------------------------------------------------------
# Helper: compute a deterministic digest over a directory.
# Walks all regular files under $1 in sorted order, hashes each, then hashes
# the combined output. Reproducible across runs on the same tree.
# ---------------------------------------------------------------------------
dir_sha256() {
  local dir="$1"
  find "${dir}" -type f | LC_ALL=C sort | xargs sha256sum | sha256sum | awk '{print $1}'
}

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
# Check 3: Model artifacts (Qwen LLM, Whisper STT, Piper TTS)
#
# Path scheme (unified — B3 fix):
#   Each manifest entry has an install_to field with the image-absolute path
#   (e.g. /opt/arlowe/models/whisper/small.en). The gate strips MODELS_IMAGE_PREFIX
#   to derive the relative subpath (e.g. whisper/small.en), then searches:
#     $ARLOWE_MODELS_DIR/<subpath>
#     third_party/models/<subpath>
#     /var/cache/arlowe-build/models/<subpath>
#   This matches INSTALL.md staging instructions exactly.
#
# Directory artifacts with real SHA pins (B2 fix):
#   A real (non-placeholder) pin on a directory artifact is verified by computing
#   a deterministic directory digest (sorted find -type f | xargs sha256sum | sha256sum).
#   A real pin with no verifiable target (missing primary_file and not a verifiable
#   directory) HARD-FAILS — WARN is only for TODO placeholders.
# ---------------------------------------------------------------------------
if [[ ! -f "${MODELS_MANIFEST}" ]]; then
  printf "${RED}[FAIL]${NC} third_party/models/manifest.yml  not found\n"
  echo >&2 "  Expected at: ${MODELS_MANIFEST}"
  all_ok=false
else
  # Emit tab-delimited fields to survive spaces in any future install_to values (S2 fix).
  model_keys=$(python3 -c "
import yaml
with open('${MODELS_MANIFEST}') as f:
    m = yaml.safe_load(f)
for key in m.get('models', {}):
    entry = m['models'][key]
    fields = [key, entry.get('name',''), entry.get('sha256',''), entry.get('install_to','')]
    print('\t'.join(fields))
" 2>/dev/null) || {
    echo >&2 "ERROR: failed to parse ${MODELS_MANIFEST} (is python3-yaml installed?)"
    exit 1
  }

  while IFS=$'\t' read -r model_key model_name model_sha model_install; do
    [[ -z "${model_key}" ]] && continue

    # Derive the relative subpath from install_to by stripping the image prefix.
    # install_to: /opt/arlowe/models/whisper/small.en  →  subpath: whisper/small.en
    if [[ "${model_install}" == "${MODELS_IMAGE_PREFIX}"/* ]]; then
      install_subpath="${model_install#"${MODELS_IMAGE_PREFIX}"/}"
    else
      # install_to does not start with the expected prefix — fall back to model name.
      install_subpath="${model_name}"
    fi

    # Search for the artifact using the install_to subpath.
    artifact_path=""

    if [[ -n "${ARLOWE_MODELS_DIR:-}" ]]; then
      candidate="${ARLOWE_MODELS_DIR}/${install_subpath}"
      if [[ -e "${candidate}" ]]; then
        artifact_path="${candidate}"
      fi
    fi

    if [[ -z "${artifact_path}" ]]; then
      candidate="${REPO_ROOT}/third_party/models/${install_subpath}"
      if [[ -e "${candidate}" ]]; then
        artifact_path="${candidate}"
      fi
    fi

    if [[ -z "${artifact_path}" ]]; then
      candidate="/var/cache/arlowe-build/models/${install_subpath}"
      if [[ -e "${candidate}" ]]; then
        artifact_path="${candidate}"
      fi
    fi

    # Check if the SHA pin is a TODO placeholder.
    is_placeholder=false
    if [[ "${model_sha}" == TODO_SHA256* ]]; then
      is_placeholder=true
    fi

    if [[ -z "${artifact_path}" ]]; then
      printf "${RED}[FAIL]${NC} %-50s not found\n" "${model_name}"
      echo >&2 "  Set ARLOWE_MODELS_DIR=<dir> or stage artifact at:"
      echo >&2 "    third_party/models/${install_subpath}"
      echo >&2 "    /var/cache/arlowe-build/models/${install_subpath}"
      echo >&2 "  See third_party/models/INSTALL.md for sourcing instructions."
      all_ok=false

    elif [[ "${is_placeholder}" == "true" ]]; then
      # Placeholder pin — warn and print actual hash if computable, never fail.
      if [[ -f "${artifact_path}" ]]; then
        actual_hash=$(sha256sum "${artifact_path}" | awk '{print $1}')
        printf "${YELLOW}[WARN]${NC}  %-50s sha256 pin is TODO placeholder\n" "${model_name}"
        printf "         actual hash: %s\n" "${actual_hash}"
        printf "         Record this in third_party/models/manifest.yml to close the TODO.\n"
      elif [[ -d "${artifact_path}" ]]; then
        actual_hash=$(dir_sha256 "${artifact_path}")
        printf "${YELLOW}[WARN]${NC}  %-50s sha256 pin is TODO placeholder\n" "${model_name}"
        printf "         actual dir digest: %s\n" "${actual_hash}"
        printf "         Record this in third_party/models/manifest.yml to close the TODO.\n"
      else
        printf "${YELLOW}[WARN]${NC}  %-50s sha256 pin is TODO placeholder; artifact present but unreadable\n" "${model_name}"
      fi

    else
      # Real SHA pin — must verify; no degradation to WARN.
      if [[ -f "${artifact_path}" ]]; then
        actual_sha256=$(sha256sum "${artifact_path}" | awk '{print $1}')
        if [[ "${actual_sha256}" == "${model_sha}" ]]; then
          printf "${GREEN}[OK]${NC}   %-50s sha256 matches\n" "${model_name}"
        else
          printf "${RED}[FAIL]${NC} %-50s sha256 mismatch\n" "${model_name}"
          echo >&2 "  Expected: ${model_sha}"
          echo >&2 "  Actual:   ${actual_sha256}"
          all_ok=false
        fi
      elif [[ -d "${artifact_path}" ]]; then
        actual_sha256=$(dir_sha256 "${artifact_path}")
        if [[ "${actual_sha256}" == "${model_sha}" ]]; then
          printf "${GREEN}[OK]${NC}   %-50s dir digest matches\n" "${model_name}"
        else
          printf "${RED}[FAIL]${NC} %-50s dir digest mismatch\n" "${model_name}"
          echo >&2 "  Expected: ${model_sha}"
          echo >&2 "  Actual:   ${actual_sha256}"
          echo >&2 "  Digest is sha256(sorted find -type f | xargs sha256sum | sha256sum)"
          all_ok=false
        fi
      else
        # Present as a path but neither file nor directory — treat as FAIL,
        # same as a real pin with no verifiable target.
        printf "${RED}[FAIL]${NC} %-50s real sha256 pin present but artifact is not a file or directory\n" "${model_name}"
        echo >&2 "  Cannot verify ${artifact_path} — check staging."
        all_ok=false
      fi
    fi
  done <<< "${model_keys}"
fi

# ---------------------------------------------------------------------------
# Check 4: WhisPlay driver source
# ---------------------------------------------------------------------------
whisplay_dir=""

if [[ -n "${ARLOWE_WHISPLAY_SRC:-}" ]]; then
  if [[ -f "${ARLOWE_WHISPLAY_SRC}/WhisPlay.py" ]]; then
    whisplay_dir="${ARLOWE_WHISPLAY_SRC}"
  fi
fi

if [[ -z "${whisplay_dir}" ]]; then
  if [[ -f "${REPO_ROOT}/third_party/whisplay-driver/WhisPlay.py" ]]; then
    whisplay_dir="${REPO_ROOT}/third_party/whisplay-driver"
  fi
fi

if [[ -z "${whisplay_dir}" ]]; then
  if [[ -f "/var/cache/arlowe-build/whisplay-driver/WhisPlay.py" ]]; then
    whisplay_dir="/var/cache/arlowe-build/whisplay-driver"
  fi
fi

if [[ -z "${whisplay_dir}" ]]; then
  printf "${RED}[FAIL]${NC} WhisPlay.py  not found\n"
  echo >&2 "  Set ARLOWE_WHISPLAY_SRC=/path/to/whisplay-driver or place at:"
  echo >&2 "    third_party/whisplay-driver/WhisPlay.py"
  echo >&2 "    /var/cache/arlowe-build/whisplay-driver/WhisPlay.py"
  echo >&2 "  See third_party/whisplay-driver/INSTALL.md for sourcing instructions."
  all_ok=false
else
  printf "${GREEN}[OK]${NC}   %-50s present (Apache 2.0)\n" "WhisPlay.py"

  # LICENSE must also be present for attribution compliance
  if [[ ! -f "${whisplay_dir}/LICENSE" ]]; then
    printf "${RED}[FAIL]${NC} WhisPlay LICENSE  not found at ${whisplay_dir}/LICENSE\n"
    echo >&2 "  Copy the Apache 2.0 LICENSE from the PiSugar/Whisplay repo alongside WhisPlay.py."
    echo >&2 "  See third_party/whisplay-driver/INSTALL.md"
    all_ok=false
  else
    printf "${GREEN}[OK]${NC}   %-50s present\n" "WhisPlay LICENSE"
  fi
fi

# ---------------------------------------------------------------------------
# Check 5: WM8960 audio HAT redistribution rights — non-blocking warning
# ---------------------------------------------------------------------------
printf "${YELLOW}[WARN]${NC}  %-50s redistribution rights unresolved\n" "WM8960 audio HAT"
echo "         The Waveshare WM8960 HAT driver bundle in the Whisplay repo has no"
echo "         standalone license file. Treated as fetch-at-build (not bundled)."
echo "         Resolve before distributing a production image."

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
