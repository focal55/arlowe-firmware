#!/usr/bin/env bash
# tests/phase-07.3/bootstrap-manifest.sh [--pi-retained DIR] [--out FILE]
#
# Regenerates third_party/pi-archive/manifest.yml from the committed real-build
# reference (docs/operations/phase-07.2-inputs.reference) crossed with a
# signature-verified Raspberry Pi index.
#
# Why this route: the reference is already a real build's installed set, so no
# record-mode hardware build is needed. The digests come from an index that apt
# itself verified against the Raspberry Pi archive key pi-gen installs, never
# from a download hashed on first use. And the Pi archive has no snapshot
# service: the live index carries one version per package and moves several
# times a week, so once a reference row has been superseded the only signed
# source for its digest is the index the build resolved against. --pi-retained
# supplies that one, and apt re-verifies it exactly as the build did.
#
# Runs in a debian:bookworm arm64 container. Needs docker and network.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="third_party/pi-archive/manifest.yml"
RETAINED=""
RPI_KEY_FPR="CF8A1AF502A2AA2D763BAE7E82B129927FA3303E"

die() { printf '[bootstrap] ERROR %s\n' "$*" >&2; exit 1; }

while (( $# )); do
    case "$1" in
        --pi-retained) RETAINED="${2:?--pi-retained needs a directory}"; shift 2 ;;
        --out) OUT="${2:?--out needs a path}"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[[ "${OUT}" != /* ]] || die "--out must be relative to the repo root: ${OUT}"

PIGEN_REF="$(sed -n 's/^PIGEN_REF="\(.*\)"$/\1/p' "${REPO_ROOT}/scripts/build-image.sh" | head -1)"
[[ -n "${PIGEN_REF}" ]] || die "cannot read PIGEN_REF from scripts/build-image.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/key"
curl -fsSL -o "${TMP}/key/raspberrypi.gpg.key" \
    "https://raw.githubusercontent.com/RPi-Distro/pi-gen/${PIGEN_REF}/stage0/00-configure-apt/files/raspberrypi.gpg.key"

mkdir -p "${REPO_ROOT}/$(dirname "${OUT}")"
MOUNTS=(-v "${REPO_ROOT}:/w" -v "${TMP}/key:/boot-in:ro")
if [[ -n "${RETAINED}" ]]; then
    for f in InRelease Packages; do
        [[ -f "${RETAINED}/${f}" ]] || die "--pi-retained needs ${RETAINED}/${f}. On the build host they are
  \${WORK_DIR}/stage2/rootfs/var/lib/apt/lists/archive.raspberrypi.com_debian_dists_bookworm_InRelease
  \${WORK_DIR}/stage2/rootfs/var/lib/apt/lists/archive.raspberrypi.com_debian_dists_bookworm_main_binary-arm64_Packages
left there by the last build that passed the 07.2 input diff gate."
    done
    mkdir -p "${TMP}/mirror/dists/bookworm/main/binary-arm64"
    cp "${RETAINED}/InRelease" "${TMP}/mirror/dists/bookworm/InRelease"
    cp "${RETAINED}/Packages" "${TMP}/mirror/dists/bookworm/main/binary-arm64/Packages"
    MOUNTS+=(-v "${TMP}/mirror:/pi-retained:ro")
fi

docker run --rm -i --platform linux/arm64 "${MOUNTS[@]}" \
    -e OUT="${OUT}" -e RETAINED="${RETAINED:+1}" -e RPI_KEY_FPR="${RPI_KEY_FPR}" \
    -e OWNER="$(id -u):$(id -g)" debian:bookworm bash -s <<'INNER'
set -euo pipefail
cd /w
# Without this, apt stores lists as .lz4, which the generator refuses.
rm -f /etc/apt/apt.conf.d/docker-gzip-indexes
rm -f /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list
OVERLAY_APT=overlays/pi-gen/stage0/00-configure-apt/files
sed "s/RELEASE/bookworm/g" "${OVERLAY_APT}/sources.list" > /etc/apt/sources.list
cp "${OVERLAY_APT}/99arlowe-pinned" /etc/apt/apt.conf.d/99arlowe-pinned
apt-get update -qq
apt-get install -y -qq --no-install-recommends gnupg python3 python3-yaml >/dev/null

KR=/usr/share/keyrings/rpi-archive.gpg
gpg --dearmor < /boot-in/raspberrypi.gpg.key > "${KR}"
FPRS="$(gpg --show-keys --with-colons "${KR}" | awk -F: '$1 == "fpr" { print $10 }')"
echo "[bootstrap] Pi archive key fingerprints: ${FPRS//$'\n'/ }"
grep -qx "${RPI_KEY_FPR}" <<<"${FPRS}" || { echo "[bootstrap] ERROR key is not ${RPI_KEY_FPR}" >&2; exit 1; }

echo "deb [signed-by=${KR}] http://archive.raspberrypi.com/debian bookworm main" \
    > /etc/apt/sources.list.d/rpi.list
[[ -z "${RETAINED}" ]] || echo "deb [signed-by=${KR}] file:/pi-retained bookworm main" \
    >> /etc/apt/sources.list.d/rpi.list
# The exit code of update proves nothing: apt drops the list of a source whose
# signature fails and carries on. The list files are the evidence.
apt-get update -qq || true
L=/var/lib/apt/lists
mapfile -t PI < <(find "${L}" -maxdepth 1 -name 'archive.raspberrypi.com_*binary-arm64_Packages' | sort)
(( ${#PI[@]} )) || { echo "[bootstrap] ERROR no signature-verified live Pi index" >&2; exit 1; }
if [[ -n "${RETAINED}" ]]; then
    mapfile -t RP < <(find "${L}" -maxdepth 1 -name '_pi-retained_*binary-arm64_Packages' | sort)
    (( ${#RP[@]} )) || { echo "[bootstrap] ERROR the retained Pi index failed verification" >&2; exit 1; }
    PI+=("${RP[@]}")
fi
mapfile -t DEB < <(find "${L}" -maxdepth 1 -name 'snapshot.debian.org_*binary-arm64_Packages' | sort)
(( ${#DEB[@]} )) || { echo "[bootstrap] ERROR no snapshot.debian.org index" >&2; exit 1; }
printf '[bootstrap] pi list: %s\n' "${PI[@]}"
printf '[bootstrap] debian list: %s\n' "${DEB[@]}"

ARGS=()
for p in "${PI[@]}"; do ARGS+=(--pi-list "${p}"); done
for p in "${DEB[@]}"; do ARGS+=(--debian-list "${p}"); done
python3 scripts/lib/pi-archive-manifest.py generate \
    --installed-reference docs/operations/phase-07.2-inputs.reference "${ARGS[@]}" \
    --kernel-manifest third_party/kernel/manifest.yml --allow-local axclhost \
    --resolve-only firmware-marvell-prestera \
    --pool-base http://archive.raspberrypi.com/debian --out "${OUT}"
chown "${OWNER}" "${OUT}"
INNER
