#!/usr/bin/env bash
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

Model artifact search order (per artifact):
  - \$ARLOWE_MODELS_DIR/<artifact-name>/
  - third_party/models/<artifact-name>/
  - /var/cache/arlowe-build/models/<artifact-name>/

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
# ---------------------------------------------------------------------------
if [[ ! -f "${MODELS_MANIFEST}" ]]; then
  printf "${RED}[FAIL]${NC} third_party/models/manifest.yml  not found\n"
  echo >&2 "  Expected at: ${MODELS_MANIFEST}"
  all_ok=false
else
  # Each model entry: name, sha256, install_to
  # Read via python3 (same dependency as axcl check above — no new dep).
  model_count=$(python3 -c "
import yaml
with open('${MODELS_MANIFEST}') as f:
    m = yaml.safe_load(f)
print(len(m.get('models', {})))
" 2>/dev/null) || {
    echo >&2 "ERROR: failed to parse ${MODELS_MANIFEST} (is python3-yaml installed?)"
    exit 1
  }

  model_keys=$(python3 -c "
import yaml
with open('${MODELS_MANIFEST}') as f:
    m = yaml.safe_load(f)
for key in m.get('models', {}):
    entry = m['models'][key]
    print(key, entry.get('name',''), entry.get('sha256',''), entry.get('install_to',''))
" 2>/dev/null)

  while IFS=' ' read -r model_key model_name model_sha model_install; do
    [[ -z "${model_key}" ]] && continue

    # Locate the artifact directory or primary file.
    # For directory-based models (qwen, whisper CTranslate2): check for the dir.
    # For file-based models (piper .onnx): check for the file.
    artifact_path=""

    # Derive a search name from the artifact name (strip version suffixes for dir check)
    search_name="${model_name}"

    if [[ -n "${ARLOWE_MODELS_DIR:-}" ]]; then
      candidate="${ARLOWE_MODELS_DIR}/${search_name}"
      if [[ -e "${candidate}" ]]; then
        artifact_path="${candidate}"
      fi
    fi

    if [[ -z "${artifact_path}" ]]; then
      candidate="${REPO_ROOT}/third_party/models/${search_name}"
      if [[ -e "${candidate}" ]]; then
        artifact_path="${candidate}"
      fi
    fi

    if [[ -z "${artifact_path}" ]]; then
      candidate="/var/cache/arlowe-build/models/${search_name}"
      if [[ -e "${candidate}" ]]; then
        artifact_path="${candidate}"
      fi
    fi

    # Determine the primary verifiable file inside the artifact location.
    # Whisper: model.bin; Piper: the .onnx file itself (install_to path); Qwen: any single large file.
    primary_file=""
    if [[ -n "${artifact_path}" ]]; then
      if [[ -f "${artifact_path}" ]]; then
        # Direct file (piper .onnx path)
        primary_file="${artifact_path}"
      elif [[ -d "${artifact_path}" ]]; then
        # Directory — look for model.bin (faster-whisper CTranslate2)
        if [[ -f "${artifact_path}/model.bin" ]]; then
          primary_file="${artifact_path}/model.bin"
        fi
      fi
    fi

    # Check if the SHA pin is a TODO placeholder
    is_placeholder=false
    if [[ "${model_sha}" == TODO_SHA256* ]]; then
      is_placeholder=true
    fi

    if [[ -z "${artifact_path}" ]]; then
      printf "${RED}[FAIL]${NC} %-50s not found\n" "${model_name}"
      echo >&2 "  Set ARLOWE_MODELS_DIR=<dir> or place artifact at:"
      echo >&2 "    third_party/models/${search_name}/"
      echo >&2 "    /var/cache/arlowe-build/models/${search_name}/"
      echo >&2 "  See third_party/models/INSTALL.md for sourcing instructions."
      all_ok=false
    elif [[ "${is_placeholder}" == "true" ]]; then
      # Placeholder pin — warn, print actual hash if we can compute it
      if [[ -n "${primary_file}" ]]; then
        actual_hash=$(sha256sum "${primary_file}" | awk '{print $1}')
        printf "${YELLOW}[WARN]${NC}  %-50s sha256 pin is TODO placeholder\n" "${model_name}"
        printf "         actual hash of %s:\n" "$(basename "${primary_file}")"
        printf "         %s\n" "${actual_hash}"
        printf "         Record this in third_party/models/manifest.yml to close the TODO.\n"
      else
        printf "${YELLOW}[WARN]${NC}  %-50s sha256 pin is TODO placeholder; artifact present but no primary file found to hash\n" "${model_name}"
      fi
    else
      # Real SHA pin — verify
      if [[ -n "${primary_file}" ]]; then
        actual_sha256=$(sha256sum "${primary_file}" | awk '{print $1}')
        if [[ "${actual_sha256}" == "${model_sha}" ]]; then
          printf "${GREEN}[OK]${NC}   %-50s sha256 matches\n" "${model_name}"
        else
          printf "${RED}[FAIL]${NC} %-50s sha256 mismatch\n" "${model_name}"
          echo >&2 "  Expected: ${model_sha}"
          echo >&2 "  Actual:   ${actual_sha256}"
          all_ok=false
        fi
      else
        printf "${YELLOW}[WARN]${NC}  %-50s present but no primary file found to verify sha256\n" "${model_name}"
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
