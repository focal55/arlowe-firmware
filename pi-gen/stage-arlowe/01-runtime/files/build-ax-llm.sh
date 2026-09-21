#!/bin/bash
# Build the ax-llm HTTP server natively on arm64 and install it as
# /opt/arlowe/runtime/llm/bin/main_api_axcl_aarch64.
#
# runtime/llm/run_api.sh has named that path since Phase 1 and nothing ever
# produced it: /opt/arlowe/runtime/llm/bin did not exist on a flashed image, so
# qwen-api exited 127 on every start. A consumer with no producer.
#
# WHY NOT third_party/ax-llm/build_aarch64.sh, the upstream script:
#   It cross-compiles from x86 and fetches two things over the network with no
#   checksum -- an ARM GCC 9.2 toolchain from developer.arm.com and
#   axcl_3.6.2_aarch64.zip from a GitHub release. Both are unpinned, so wiring it
#   in would reintroduce the drift class Phase 7.2 closed (#137). Worse, it pulls
#   axcl 3.6.2 while this image ships the pinned V3.10.2 deb, so the binary would
#   be linked against a different SDK than the one it runs on.
#
# Instead: build natively (the build host and the target are both arm64) against
# the axcl headers and libraries the pinned deb already installed. CMakeLists.txt
# falls back to /usr/include/axcl and /usr/lib/axcl when AXCL_DIR is unset, which
# is exactly where the deb puts them -- so leaving AXCL_DIR unset is the whole
# mechanism. No download, and the SDK linked against is the SDK that ships.
#
# ORDER: must run AFTER the axcl deb install in 00-run-chroot.sh. Without it
# there are no headers and cmake fails at configure time.
set -euo pipefail

log()  { echo "[build-ax-llm] $*"; }
fail() { echo "[build-ax-llm] ERROR: $*" >&2; exit 1; }

# 00-run-chroot.sh sets REPO_ROOT but does not export it, so a child `bash`
# does not inherit it. build-dashboard.sh and build-venvs.sh both handle this
# by defaulting to the staged path directly; match them rather than relying on
# an inherited value. A wrong default here is invisible until the build runs:
# the first attempt defaulted to /opt/arlowe-build/repo and died at step 8b.
REPO_ROOT="${REPO_ROOT:-/root/arlowe-build/repo}"
SRC="${ARLOWE_AXLLM_SRC:-${REPO_ROOT}/third_party/ax-llm}"
DEST_DIR=/opt/arlowe/runtime/llm/bin
DEST="${DEST_DIR}/main_api_axcl_aarch64"

# The CMake target is named main_api. The name the runtime expects,
# main_api_axcl_aarch64, is the upstream cross-build's output name; nothing in
# the tree renames it, which is part of why this gap went unnoticed.
BUILT_NAME=main_api

[[ -d "${SRC}" ]] || fail "ax-llm submodule not found at ${SRC} — run: git submodule update --init third_party/ax-llm"
[[ -f "${SRC}/CMakeLists.txt" ]] || fail "${SRC} has no CMakeLists.txt — submodule not initialised"

[[ -d /usr/include/axcl ]] || fail "/usr/include/axcl missing — the axcl deb must be installed before this runs"
[[ -d /usr/lib/axcl ]]     || fail "/usr/lib/axcl missing — the axcl deb must be installed before this runs"
command -v cmake >/dev/null 2>&1 || fail "cmake not installed — it is declared in stage-arlowe/00-packages/00-packages-nr"

# Fail loudly on a missing link input rather than letting cmake emit a confusing
# error 200 lines into configure.
for lib in axcl_pcie_dma axcl_pcie_msg axcl_token axcl_comm axcl_pkg axcl_rt spdlog; do
    [[ -e "/usr/lib/axcl/lib${lib}.so" ]] \
        || fail "/usr/lib/axcl/lib${lib}.so missing — the axcl deb did not install what CMakeLists.txt links against"
done

BUILD_DIR="${SRC}/build_arlowe_native"
rm -rf "${BUILD_DIR}"

log "configuring (native arm64, AXCL_DIR unset -> /usr/include/axcl + /usr/lib/axcl)"
cmake -S "${SRC}" -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release >/dev/null \
    || fail "cmake configure failed"

log "building ${BUILT_NAME}"
cmake --build "${BUILD_DIR}" --target "${BUILT_NAME}" -j "$(nproc)" >/dev/null \
    || fail "cmake build failed for target ${BUILT_NAME}"

BUILT="$(find "${BUILD_DIR}" -type f -name "${BUILT_NAME}" -perm -u+x -print -quit)"
[[ -n "${BUILT}" ]] || fail "build reported success but no executable named ${BUILT_NAME} was produced"

install -d -m 0755 "${DEST_DIR}"
install -m 0755 -o root -g arlowe "${BUILT}" "${DEST}" 2>/dev/null \
    || { install -m 0755 "${BUILT}" "${DEST}"; log "WARNING: group 'arlowe' absent; ${DEST} left root-owned"; }

# The runtime resolves libaxcl_*.so from /usr/lib/axcl, which is not on the
# default loader path. Record it so qwen-api does not need LD_LIBRARY_PATH.
if [[ ! -f /etc/ld.so.conf.d/axcl.conf ]]; then
    echo /usr/lib/axcl > /etc/ld.so.conf.d/axcl.conf
    ldconfig
    log "registered /usr/lib/axcl with ldconfig"
fi

# Prove the binary actually resolves its libraries here, not on first boot.
if command -v ldd >/dev/null 2>&1; then
    if ldd "${DEST}" 2>/dev/null | grep -q 'not found'; then
        ldd "${DEST}" 2>/dev/null | grep 'not found' >&2
        fail "${DEST} has unresolved shared libraries"
    fi
fi

log "provenance: ax-llm submodule at $(git -C "${SRC}" rev-parse HEAD 2>/dev/null || echo unknown)"
log "installed -> ${DEST}"
rm -rf "${BUILD_DIR}"
