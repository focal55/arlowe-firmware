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
#   5. Node.js tarball SHA-256 matches third_party/node/manifest.yml (ADR-0008)
#   6. WM8960 audio HAT redistribution rights (non-blocking warning)
#   7. Pinned kernel debs SHA-256 match third_party/kernel/manifest.yml (ADR-0009)
#
# Usage: scripts/verify-third-party.sh [--help]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MANIFEST="${REPO_ROOT}/third_party/axcl/manifest.yml"
MODELS_MANIFEST="${REPO_ROOT}/third_party/models/manifest.yml"
NODE_MANIFEST="${REPO_ROOT}/third_party/node/manifest.yml"
KERNEL_MANIFEST="${REPO_ROOT}/third_party/kernel/manifest.yml"
AX_LLM_DIR="${REPO_ROOT}/third_party/ax-llm"

# Written by check 7 once all pinned kernel debs verify: the single directory
# holding them. scripts/build-image.sh reads this, exports it as
# ARLOWE_KERNEL_CACHE and forwards it across the sudo boundary into pi-gen.
# A file rather than an environment export because this script runs as a CHILD
# of build-image.sh and cannot mutate its parent's environment.
KERNEL_CACHE_FILE="${REPO_ROOT}/build/.arlowe-kernel-cache"
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
  5. Node.js tarball SHA-256 matches third_party/node/manifest.yml (ADR-0008)
  6. WM8960 audio HAT redistribution rights (non-blocking warning)
  7. Pinned kernel debs SHA-256 match third_party/kernel/manifest.yml (ADR-0009)

Kernel deb search order (per deb, six of them):
  - \$ARLOWE_KERNEL_DIR/<filename>
  - third_party/kernel/<filename>
  - /var/cache/arlowe-build/kernel/<filename>
  - ${XDG_CACHE_HOME:-$HOME/.cache}/arlowe-build/kernel/<filename>

The kernel is installed from these debs instead of resolved by apt: the meta
packages carry exactly one version (the newest), and the newest broke the axcl
module compile. Set ARLOWE_KERNEL_FETCH=1 to download them (~75 MiB) -- to
/var/cache/arlowe-build/kernel/ if writable, otherwise to
${XDG_CACHE_HOME:-$HOME/.cache}/arlowe-build/kernel/ so an unprivileged build
user can fetch. The SHA-256 is asserted either way. Once all six verify, the
directory holding them is written to build/.arlowe-kernel-cache for
scripts/build-image.sh to forward into pi-gen.

Node tarball search order:
  - \$ARLOWE_NODE_TARBALL
  - third_party/node/<filename>
  - /var/cache/arlowe-build/<filename>

Unlike the other pins, third_party/node/manifest.yml carries a real url (Node is
MIT-licensed and publicly downloadable). Set ARLOWE_NODE_FETCH=1 to have this gate
download it when absent -- to /var/cache/arlowe-build/ if that is writable,
otherwise to ${XDG_CACHE_HOME:-$HOME/.cache}/arlowe-build/ so the fetch works
unprivileged; the SHA-256 is asserted either
way, so fetching never weakens the pin.

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
  third_party/kernel/INSTALL.md
  third_party/kernel/manifest.yml
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
# Check 5: Node.js tarball SHA-256 (ADR-0008)
#
# The dashboard unit's ExecStart names the interpreter this tarball unpacks to,
# not /usr/bin/node — the apt nodejs/npm packages are deliberately absent from
# 00-packages-nr because bookworm's 18.20.4 cannot run next@16.1.6 (engines.node
# >= 20.9.0) and bookworm-backports has no nodejs at all. A version pin with no
# recurring hash check is a decision that exists only on paper, so this block is
# the gate. HARD FAIL on mismatch or absence.
# ---------------------------------------------------------------------------
if [[ ! -f "${NODE_MANIFEST}" ]]; then
  printf "${RED}[FAIL]${NC} third_party/node/manifest.yml  not found\n"
  all_ok=false
else
  node_sha256=$(python3 -c "
import yaml
with open('${NODE_MANIFEST}') as f:
    m = yaml.safe_load(f)
print(m['node']['sha256'])
" 2>/dev/null) || {
    echo >&2 "ERROR: failed to parse ${NODE_MANIFEST} (is python3-yaml installed?)"
    exit 1
  }

  node_filename=$(python3 -c "
import yaml
with open('${NODE_MANIFEST}') as f:
    m = yaml.safe_load(f)
print(m['node']['filename'])
" 2>/dev/null)

  node_url=$(python3 -c "
import yaml
with open('${NODE_MANIFEST}') as f:
    m = yaml.safe_load(f)
print(m['node']['url'] or '')
" 2>/dev/null)

  _node_user_cache="${XDG_CACHE_HOME:-${HOME}/.cache}/arlowe-build"

  node_path=""
  if [[ -n "${ARLOWE_NODE_TARBALL:-}" ]]; then
    node_path="${ARLOWE_NODE_TARBALL}"
  elif [[ -f "${REPO_ROOT}/third_party/node/${node_filename}" ]]; then
    node_path="${REPO_ROOT}/third_party/node/${node_filename}"
  elif [[ -f "/var/cache/arlowe-build/${node_filename}" ]]; then
    node_path="/var/cache/arlowe-build/${node_filename}"
  elif [[ -f "${_node_user_cache}/${node_filename}" ]]; then
    node_path="${_node_user_cache}/${node_filename}"
  fi

  # Opt-in fetch. Node's url is non-null (MIT, publicly downloadable), unlike the
  # axcl and model pins. Fetching still lands in the hash assertion below.
  #
  # The shared cache lives under /var/cache, which an unprivileged build user
  # cannot create. Fall back to a user cache rather than failing: the bare
  # "mkdir: Permission denied" surfaced three lines above an unrelated-looking
  # "not found", which is how this cost a build cycle on the arm64 host.
  if [[ -z "${node_path}" ]] && [[ "${ARLOWE_NODE_FETCH:-}" == "1" ]] && [[ -n "${node_url}" ]]; then
    node_cache=""
    if mkdir -p /var/cache/arlowe-build 2>/dev/null; then
      node_cache="/var/cache/arlowe-build"
    elif mkdir -p "${_node_user_cache}" 2>/dev/null; then
      node_cache="${_node_user_cache}"
      echo "         /var/cache/arlowe-build not writable; caching in ${node_cache}"
    fi

    if [[ -z "${node_cache}" ]]; then
      echo >&2 "  ARLOWE_NODE_FETCH=1 set but no cache directory is writable."
      echo >&2 "  Tried /var/cache/arlowe-build and ${_node_user_cache}."
    elif curl -fsSL "${node_url}" -o "${node_cache}/${node_filename}.part"; then
      mv "${node_cache}/${node_filename}.part" "${node_cache}/${node_filename}"
      node_path="${node_cache}/${node_filename}"
    else
      rm -f "${node_cache}/${node_filename}.part"
      echo >&2 "  ARLOWE_NODE_FETCH=1 set but download failed: ${node_url}"
    fi
  fi

  if [[ -z "${node_path}" ]]; then
    printf "${RED}[FAIL]${NC} %-50s not found\n" "${node_filename}"
    echo >&2 "  Obtain it with either:"
    echo >&2 "    ARLOWE_NODE_FETCH=1 scripts/verify-third-party.sh"
    echo >&2 "    curl -fsSL ${node_url} -o /var/cache/arlowe-build/${node_filename}"
    echo >&2 "  or set ARLOWE_NODE_TARBALL=/path/to/${node_filename}"
    all_ok=false
  else
    node_actual_sha256=$(sha256sum "${node_path}" | awk '{print $1}')
    if [[ "${node_actual_sha256}" == "${node_sha256}" ]]; then
      printf "${GREEN}[OK]${NC}   %-50s sha256 matches\n" "third_party/node: ${node_filename}"
    else
      printf "${RED}[FAIL]${NC} %-50s sha256 mismatch\n" "third_party/node: ${node_filename}"
      echo >&2 "  Expected: ${node_sha256}"
      echo >&2 "  Actual:   ${node_actual_sha256}"
      echo >&2 "  Path:     ${node_path}"
      all_ok=false
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Check 6: WM8960 audio HAT redistribution rights — non-blocking warning
# ---------------------------------------------------------------------------
printf "${YELLOW}[WARN]${NC}  %-50s redistribution rights unresolved\n" "WM8960 audio HAT"
echo "         The Waveshare WM8960 HAT driver bundle in the Whisplay repo has no"
echo "         standalone license file. Treated as fetch-at-build (not bundled)."
echo "         Resolve before distributing a production image."

# ---------------------------------------------------------------------------
# Check 7: pinned kernel debs (ADR-0009)
#
# The kernel is the input that actually broke: 6.12.109 gave
# pci_resize_resource a fourth exclude_bars parameter, the vendored axcl 3.10.2
# driver passes three, and the module stopped compiling at
# ax_pcie_dev_host.c:220. Nothing in this repo changed.
#
# The four kernel META packages carry exactly one version each
# (apt-cache madison linux-headers-rpi-2712 -> 1:6.12.109-1+rpt1), so there is
# no older candidate to constrain them to. They are removed from the overlay's
# stage0/02-firmware/01-packages and these six versioned debs are installed
# instead -- see overlays/pi-gen/stage0/02-firmware/00-run.sh.
#
# HARD FAIL on absence or mismatch, like Node and axcl -- no degradation to
# WARN. One [OK]/[FAIL] line per deb so a partially populated cache is
# diagnosable at a glance rather than as one opaque failure.
# ---------------------------------------------------------------------------
if [[ ! -f "${KERNEL_MANIFEST}" ]]; then
  printf "${RED}[FAIL]${NC} third_party/kernel/manifest.yml  not found\n"
  echo >&2 "  Expected at: ${KERNEL_MANIFEST}"
  all_ok=false
  rm -f "${KERNEL_CACHE_FILE}" 2>/dev/null || true
else
  kernel_debs=$(python3 -c "
import yaml
with open('${KERNEL_MANIFEST}') as f:
    m = yaml.safe_load(f)
for d in m['kernel']['debs']:
    print('\t'.join([d['filename'], d['sha256'], d['url'] or '']))
" 2>/dev/null) || {
    echo >&2 "ERROR: failed to parse ${KERNEL_MANIFEST} (is python3-yaml installed?)"
    exit 1
  }

  kernel_expected=$(printf '%s\n' "${kernel_debs}" | grep -c . || true)

  _kernel_shared_cache="/var/cache/arlowe-build/kernel"
  _kernel_user_cache="${XDG_CACHE_HOME:-${HOME}/.cache}/arlowe-build/kernel"

  # Resolve the fetch destination ONCE, up front. The equivalent Node defect
  # surfaced a bare "mkdir: Permission denied" three lines above an
  # unrelated-looking "not found" and cost a build cycle; here it would have
  # done so six times. /var/cache is not writable by an unprivileged build
  # user, so falling back to the XDG cache is the normal path, not an edge case.
  kernel_fetch_dir=""
  if [[ "${ARLOWE_KERNEL_FETCH:-}" == "1" ]]; then
    if mkdir -p "${_kernel_shared_cache}" 2>/dev/null; then
      kernel_fetch_dir="${_kernel_shared_cache}"
    elif mkdir -p "${_kernel_user_cache}" 2>/dev/null; then
      kernel_fetch_dir="${_kernel_user_cache}"
      echo "         ${_kernel_shared_cache} not writable; caching in ${kernel_fetch_dir}"
    else
      echo >&2 "  ARLOWE_KERNEL_FETCH=1 set but no cache directory is writable."
      echo >&2 "  Tried ${_kernel_shared_cache} and ${_kernel_user_cache}."
    fi
  fi

  kernel_ok=true
  kernel_names=()
  kernel_shas=()
  kernel_paths=()

  while IFS=$'\t' read -r k_file k_sha k_url; do
    [[ -z "${k_file}" ]] && continue

    k_path=""
    for k_cand in \
      "${ARLOWE_KERNEL_DIR:+${ARLOWE_KERNEL_DIR}/${k_file}}" \
      "${REPO_ROOT}/third_party/kernel/${k_file}" \
      "${_kernel_shared_cache}/${k_file}" \
      "${_kernel_user_cache}/${k_file}"; do
      if [[ -n "${k_cand}" && -f "${k_cand}" ]]; then
        k_path="${k_cand}"
        break
      fi
    done

    # Opt-in fetch. The kernel is GPL-2.0 and publicly downloadable, so url is
    # populated (unlike axcl). Fetching still lands in the hash assertion below.
    if [[ -z "${k_path}" && -n "${kernel_fetch_dir}" && -n "${k_url}" ]]; then
      if curl -fsSL "${k_url}" -o "${kernel_fetch_dir}/${k_file}.part"; then
        mv "${kernel_fetch_dir}/${k_file}.part" "${kernel_fetch_dir}/${k_file}"
        k_path="${kernel_fetch_dir}/${k_file}"
      else
        rm -f "${kernel_fetch_dir}/${k_file}.part"
        echo >&2 "  download failed: ${k_url}"
      fi
    fi

    if [[ -z "${k_path}" ]]; then
      printf "${RED}[FAIL]${NC} %-58s not found\n" "${k_file}"
      echo >&2 "  Obtain all six with:"
      echo >&2 "    ARLOWE_KERNEL_FETCH=1 scripts/verify-third-party.sh"
      echo >&2 "  or set ARLOWE_KERNEL_DIR=<dir>, or stage at:"
      echo >&2 "    third_party/kernel/${k_file}"
      echo >&2 "  See third_party/kernel/INSTALL.md."
      kernel_ok=false
      all_ok=false
      continue
    fi

    k_actual=$(sha256sum "${k_path}" | awk '{print $1}')
    if [[ "${k_actual}" == "${k_sha}" ]]; then
      printf "${GREEN}[OK]${NC}   %-58s sha256 matches\n" "${k_file}"
      kernel_names+=("${k_file}")
      kernel_shas+=("${k_sha}")
      kernel_paths+=("${k_path}")
    else
      printf "${RED}[FAIL]${NC} %-58s sha256 mismatch\n" "${k_file}"
      echo >&2 "  Expected: ${k_sha}"
      echo >&2 "  Actual:   ${k_actual}"
      echo >&2 "  Path:     ${k_path}"
      kernel_ok=false
      all_ok=false
    fi
  done <<< "${kernel_debs}"

  # Downstream contract: ONE directory containing exactly these six files.
  # stage0/02-firmware/00-run.sh copies from a single ARLOWE_KERNEL_CACHE, so a
  # set resolved across several directories has to be consolidated here rather
  # than handed over as a list.
  kernel_cache_dir=""
  if [[ "${kernel_ok}" == "true" ]] && (( ${#kernel_paths[@]} == kernel_expected )); then
    kernel_dirs=$(printf '%s\n' "${kernel_paths[@]}" | xargs -n1 dirname | LC_ALL=C sort -u)
    if [[ "$(printf '%s\n' "${kernel_dirs}" | wc -l | tr -d ' ')" == "1" ]]; then
      kernel_cache_dir="${kernel_dirs}"
    else
      kernel_stage_dir=""
      if mkdir -p "${_kernel_shared_cache}" 2>/dev/null; then
        kernel_stage_dir="${_kernel_shared_cache}"
      elif mkdir -p "${_kernel_user_cache}" 2>/dev/null; then
        kernel_stage_dir="${_kernel_user_cache}"
      fi

      if [[ -z "${kernel_stage_dir}" ]]; then
        printf "${RED}[FAIL]${NC} %-58s cannot consolidate kernel cache\n" "third_party/kernel"
        echo >&2 "  The six debs resolved from more than one directory and neither"
        echo >&2 "  ${_kernel_shared_cache} nor ${_kernel_user_cache} is writable."
        echo >&2 "  Put all six in one directory and point ARLOWE_KERNEL_DIR at it."
        kernel_ok=false
        all_ok=false
      else
        echo "         kernel debs resolved from multiple directories; staging into ${kernel_stage_dir}"
        for k_i in "${!kernel_paths[@]}"; do
          if [[ "$(dirname "${kernel_paths[${k_i}]}")" != "${kernel_stage_dir}" ]]; then
            cp -f "${kernel_paths[${k_i}]}" "${kernel_stage_dir}/${kernel_names[${k_i}]}.part"
            mv "${kernel_stage_dir}/${kernel_names[${k_i}]}.part" "${kernel_stage_dir}/${kernel_names[${k_i}]}"
          fi
        done
        kernel_cache_dir="${kernel_stage_dir}"
      fi
    fi
  fi

  # Re-assert against the single directory actually being handed downstream.
  # Verifying the paths we resolved and then exporting a different directory
  # would be a check that measures something other than what the build uses --
  # and a copy that silently did not land is exactly what 00-run.sh would then
  # fail on, 25 minutes into a build.
  if [[ -n "${kernel_cache_dir}" ]]; then
    for k_i in "${!kernel_names[@]}"; do
      k_final="${kernel_cache_dir}/${kernel_names[${k_i}]}"
      if [[ ! -f "${k_final}" ]]; then
        printf "${RED}[FAIL]${NC} %-58s missing from resolved cache dir\n" "${kernel_names[${k_i}]}"
        echo >&2 "  Expected at: ${k_final}"
        kernel_ok=false
        all_ok=false
      elif [[ "$(sha256sum "${k_final}" | awk '{print $1}')" != "${kernel_shas[${k_i}]}" ]]; then
        printf "${RED}[FAIL]${NC} %-58s sha256 mismatch in resolved cache dir\n" "${kernel_names[${k_i}]}"
        echo >&2 "  Path: ${k_final}"
        kernel_ok=false
        all_ok=false
      fi
    done
  fi

  if [[ "${kernel_ok}" == "true" && -n "${kernel_cache_dir}" ]]; then
    if mkdir -p "$(dirname "${KERNEL_CACHE_FILE}")" 2>/dev/null &&
       printf '%s\n' "${kernel_cache_dir}" > "${KERNEL_CACHE_FILE}" 2>/dev/null; then
      printf "${GREEN}[OK]${NC}   %-58s cache: %s\n" \
        "third_party/kernel: ${kernel_expected} debs, kernel pinned" "${kernel_cache_dir}"
    else
      printf "${RED}[FAIL]${NC} %-58s cannot write %s\n" "third_party/kernel" "${KERNEL_CACHE_FILE}"
      echo >&2 "  scripts/build-image.sh reads this file to forward ARLOWE_KERNEL_CACHE"
      echo >&2 "  into pi-gen. Without it the kernel install stage has nothing to copy."
      echo >&2 "  Check ownership of $(dirname "${KERNEL_CACHE_FILE}") -- a previous sudo"
      echo >&2 "  build may have left it root-owned."
      all_ok=false
    fi
  else
    # Never leave a stale pointer behind. build-image.sh forwards this path into
    # the chroot installer; a path naming a directory that just failed
    # verification is worse than no path at all.
    rm -f "${KERNEL_CACHE_FILE}" 2>/dev/null || true
  fi
fi

# ---------------------------------------------------------------------------
# Check 8: pinned Raspberry Pi archive packages (ADR-0009)
#
# The last unpinned build inputs. Everything else comes from snapshot.debian.org,
# which is pinned to a timestamp; these three exist only in
# archive.raspberrypi.com, a rolling index with no snapshot service.
#
# raspi-firmware moved 1:1.20260907 -> 1:1.20260915 between two builds ten hours
# apart with nothing in the repo changed. It ships start.elf, fixup.dat and
# bootcode.bin -- the bootloader. python3-lgpio and python3-rpi-lgpio are the
# Pi 5 GPIO stack, and Debian has no package that does their job.
#
# SCOPE, stated plainly: this check verifies the pinned bytes are still what the
# archive serves, and HARD FAILS if they are not. It does not yet install from
# the pin -- the packages still enter the image through apt, so a drifted archive
# is caught here and stops the build rather than silently shipping a different
# bootloader. Switching the install path to the cached debs (as
# stage0/02-firmware does for the kernel) is the remaining half of #146.
# ---------------------------------------------------------------------------
RPT_MANIFEST="${REPO_ROOT}/third_party/rpt-packages/manifest.yml"

if [[ ! -f "${RPT_MANIFEST}" ]]; then
  printf "${RED}[FAIL]${NC} third_party/rpt-packages/manifest.yml  not found\n"
  echo >&2 "  Expected at: ${RPT_MANIFEST}"
  all_ok=false
else
  rpt_rows=$(python3 -c "
import yaml
with open('${RPT_MANIFEST}') as f:
    m = yaml.safe_load(f)
for e in m['packages']:
    print('\t'.join([e['name'], e['version'], e['filename'], e['sha256'], e['url']]))
" 2>/dev/null) || {
    echo >&2 "ERROR: failed to parse ${RPT_MANIFEST} (is python3-yaml installed?)"
    exit 1
  }

  _rpt_shared_cache="/var/cache/arlowe-build/rpt"
  _rpt_user_cache="${XDG_CACHE_HOME:-${HOME}/.cache}/arlowe-build/rpt"

  # Resolve the fetch destination once. /var/cache is not writable by an
  # unprivileged build user, so the XDG fallback is the normal path.
  rpt_fetch_dir=""
  if [[ "${ARLOWE_RPT_FETCH:-}" == "1" ]]; then
    if mkdir -p "${_rpt_shared_cache}" 2>/dev/null; then
      rpt_fetch_dir="${_rpt_shared_cache}"
    elif mkdir -p "${_rpt_user_cache}" 2>/dev/null; then
      rpt_fetch_dir="${_rpt_user_cache}"
      echo "         ${_rpt_shared_cache} not writable; caching in ${rpt_fetch_dir}"
    else
      echo >&2 "  ARLOWE_RPT_FETCH=1 set but no cache directory is writable."
    fi
  fi

  while IFS=$'\t' read -r r_name r_ver r_file r_sha r_url; do
    [[ -z "${r_name}" ]] && continue

    r_path=""
    for r_cand in \
      "${ARLOWE_RPT_DIR:+${ARLOWE_RPT_DIR}/${r_file}}" \
      "${REPO_ROOT}/third_party/rpt-packages/${r_file}" \
      "${_rpt_shared_cache}/${r_file}" \
      "${_rpt_user_cache}/${r_file}"; do
      [[ -n "${r_cand}" && -f "${r_cand}" ]] && { r_path="${r_cand}"; break; }
    done

    if [[ -z "${r_path}" && -n "${rpt_fetch_dir}" ]]; then
      echo "         fetching ${r_file}"
      if curl -fsSL --retry 2 -o "${rpt_fetch_dir}/${r_file}.part" "${r_url}" 2>/dev/null; then
        mv -f "${rpt_fetch_dir}/${r_file}.part" "${rpt_fetch_dir}/${r_file}"
        r_path="${rpt_fetch_dir}/${r_file}"
      else
        rm -f "${rpt_fetch_dir}/${r_file}.part" 2>/dev/null || true
      fi
    fi

    if [[ -z "${r_path}" ]]; then
      printf "${RED}[FAIL]${NC} %-50s not found\n" "${r_name} ${r_ver}"
      echo >&2 "  Set ARLOWE_RPT_FETCH=1 to download, or stage it at:"
      echo >&2 "    ${REPO_ROOT}/third_party/rpt-packages/${r_file}"
      all_ok=false
      continue
    fi

    r_actual=$(sha256sum "${r_path}" | awk '{print $1}')
    if [[ "${r_actual}" == "${r_sha}" ]]; then
      printf "${GREEN}[OK]${NC}   %-50s sha256 matches\n" "${r_file}"
    else
      printf "${RED}[FAIL]${NC} %-50s sha256 mismatch\n" "${r_file}"
      echo >&2 "  Expected: ${r_sha}"
      echo >&2 "  Actual:   ${r_actual}"
      echo >&2 "  The archive is serving different bytes than the pin records."
      echo >&2 "  If the bump is deliberate, update version/url/size/sha256 in"
      echo >&2 "  ${RPT_MANIFEST} and re-record the 07.2 inputs reference with it."
      all_ok=false
    fi
  done <<< "${rpt_rows}"
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
