#!/bin/bash
# Install the pinned Piper TTS binary into the image.
#
# runtime/tts/manifest.yml has declared this binary -- pinned url, pinned
# sha256, and an install_to path -- since Phase 1, and nothing ever read the
# binary stanza. 02-models/00-run.sh stages piper-voices (the .onnx models) and
# stops there, so every image shipped the voices with no engine to play them:
# arlowe-voice came up and logged
#   [TTS:piper] Error: [Errno 2] No such file or directory: '/opt/arlowe/runtime/tts/bin/piper'
# on its first utterance, leaving a device that listens and cannot speak.
#
# Verify the TARBALL before unpacking, then the binary after. The archive ships
# libonnxruntime.so, libpiper_phonemize.so, libespeak-ng.so and espeak-ng-data
# alongside the executable and piper loads all of them, so hashing only the
# executable would leave ~16 MB of loaded code unverified. Mirrors
# build-dashboard.sh's fetch/verify/install shape for the Node tarball.
set -euo pipefail

log()  { echo "[install-piper] $*"; }
fail() { echo "[install-piper] ERROR: $*" >&2; exit 1; }

# 00-run-chroot.sh sets REPO_ROOT but does not export it, so a child `bash`
# does not inherit it. build-dashboard.sh and build-venvs.sh both handle this
# by defaulting to the staged path directly; match them rather than relying on
# an inherited value. A wrong default here is invisible until the build runs:
# the first attempt defaulted to /opt/arlowe-build/repo and died at step 8b.
REPO_ROOT="${REPO_ROOT:-/root/arlowe-build/repo}"
MANIFEST="${ARLOWE_TTS_MANIFEST:-${REPO_ROOT}/runtime/tts/manifest.yml}"
[[ -f "${MANIFEST}" ]] || fail "manifest not found at ${MANIFEST}"

# Field reader scoped to the piper.binary block: the voices below carry their
# own url/sha256 keys and a naive grep would pick up whichever came first.
binary_field() {
    awk -v key="$1" '
        /^[[:space:]]*binary:/     { inblk = 1; next }
        /^[[:space:]]*voices:/     { inblk = 0 }
        inblk && $1 == key":"      { $1 = ""; sub(/^[[:space:]]+/, ""); gsub(/"/, ""); print; exit }
    ' "${MANIFEST}"
}

PIPER_URL="$(binary_field url)"
PIPER_SHA="$(binary_field sha256)"
PIPER_BIN_SHA="$(binary_field binary_sha256)"
PIPER_DEST="$(binary_field install_to)"
PIPER_VERSION="$(binary_field version)"

[[ -n "${PIPER_URL}"     ]] || fail "piper.binary.url missing from ${MANIFEST}"
[[ -n "${PIPER_SHA}"     ]] || fail "piper.binary.sha256 missing from ${MANIFEST}"
[[ -n "${PIPER_BIN_SHA}" ]] || fail "piper.binary.binary_sha256 missing from ${MANIFEST}"
[[ -n "${PIPER_DEST}"    ]] || fail "piper.binary.install_to missing from ${MANIFEST}"

if [[ -x "${PIPER_DEST}" ]] \
   && printf '%s  %s\n' "${PIPER_BIN_SHA}" "${PIPER_DEST}" | sha256sum -c - >/dev/null 2>&1; then
    log "piper ${PIPER_VERSION} already installed at ${PIPER_DEST}"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
TARBALL="${WORK}/piper.tar.gz"

log "fetching piper ${PIPER_VERSION} from ${PIPER_URL}"
curl -fsSL "${PIPER_URL}" -o "${TARBALL}" || fail "failed to fetch ${PIPER_URL}"

log "verifying tarball sha256 against ${MANIFEST}"
printf '%s  %s\n' "${PIPER_SHA}" "${TARBALL}" | sha256sum -c - \
    || fail "sha256 mismatch for ${PIPER_URL} — expected ${PIPER_SHA}. Refusing to unpack."

log "unpacking"
tar -xzf "${TARBALL}" -C "${WORK}" || fail "failed to unpack ${TARBALL}"

# The v1.2.0 release unpacks to piper/piper plus its shared libraries and
# espeak-ng-data; locate the executable rather than assuming the layout.
SRC_BIN="$(find "${WORK}" -type f -name piper -perm -u+x -print -quit)"
[[ -n "${SRC_BIN}" ]] || fail "no executable named 'piper' inside ${PIPER_URL}"
SRC_DIR="$(dirname "${SRC_BIN}")"

log "verifying the extracted binary against ${MANIFEST}"
printf '%s  %s\n' "${PIPER_BIN_SHA}" "${SRC_BIN}" | sha256sum -c - \
    || fail "the tarball verified but ./piper/piper inside it did not match ${PIPER_BIN_SHA}. Refusing to install."

# piper is dynamically linked against libpiper_phonemize/libonnxruntime and reads
# espeak-ng-data by relative path, so the whole payload ships beside the binary.
DEST_DIR="$(dirname "${PIPER_DEST}")"
install -d -m 0755 "${DEST_DIR}"
cp -a "${SRC_DIR}/." "${DEST_DIR}/"
chmod 0755 "${PIPER_DEST}"

# cp -a preserves the tarball's root:root. Everything else under /opt/arlowe is
# root:arlowe per scripts/provision/install-arlowe-fs.sh, and the service runs as
# arlowe: leaving it root:root works only because the modes happen to be
# world-readable, which is a weaker guarantee than the layout intends.
if getent group arlowe >/dev/null 2>&1; then
    chown -R root:arlowe "${DEST_DIR}"
    chmod -R g+rX "${DEST_DIR}"
else
    log "WARNING: group 'arlowe' absent; leaving ${DEST_DIR} as root:root"
fi

[[ -x "${PIPER_DEST}" ]] || fail "${PIPER_DEST} is not executable after install"
log "installed piper ${PIPER_VERSION} -> ${PIPER_DEST}"
