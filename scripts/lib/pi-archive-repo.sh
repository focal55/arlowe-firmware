#!/usr/bin/env bash
# scripts/lib/pi-archive-repo.sh
#
# Builds the flat apt repo that stands in for archive.raspberrypi.com during a
# build, from exactly the debs third_party/pi-archive/manifest.yml pins:
#
#   pi-archive-repo.sh --manifest M --paths P --out O
#
# P is the filename<TAB>path map pi-archive-fetch.py writes only when every deb
# verified. Each deb is copied and the COPY is re-hashed, so the bytes in O are
# the bytes asserted. O ends up holding the debs, Packages and SHA256SUMS, and
# nothing else; any failure leaves no O behind.
#
# dpkg-scanpackages, not a hand-written index: it reproduces the control fields
# apt resolves on (Pre-Depends, Provides, Breaks, Multi-Arch) faithfully. The
# index is then cross-checked against the manifest, so a deb whose control file
# disagrees with its pin (name, version with epoch, arch) fails here.
#
# `[trusted=yes]` on the rootfs source is sound: the trust anchor is the
# committed sha256, enforced here and again by apt against the Packages SHA256
# at install time. Signing would only prove the build host signed its own output.
set -euo pipefail

die() { echo "[pi-archive-repo] FAIL: $*" >&2; exit 1; }

MANIFEST="" PATHS="" OUT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --manifest) MANIFEST="$2"; shift 2 ;;
        --paths)    PATHS="$2"; shift 2 ;;
        --out)      OUT="$2"; shift 2 ;;
        *) die "unknown argument: $1 (usage: --manifest M --paths P --out O)" ;;
    esac
done
[[ -n "${MANIFEST}" && -n "${PATHS}" && -n "${OUT}" ]] || die "usage: --manifest M --paths P --out O"
[[ -f "${PATHS}" ]] || die "paths map ${PATHS} missing; run scripts/verify-third-party.sh (check 8) first"

# A previous run's repo is removed up front, so a failed run leaves none behind.
OUT="${OUT%/}"
TMP="${OUT}.tmp"
rm -rf "${TMP}" "${OUT}"
trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}"

ROWS="$(python3 - "${MANIFEST}" <<'PY'
import sys, yaml
m = yaml.safe_load(open(sys.argv[1]))
for e in (m.get("packages") or []) + (m.get("resolve_only") or []):
    print(f'{e["filename"]}\t{e["sha256"]}\t{e["size"]}')
PY
)" || die "cannot read ${MANIFEST}"
[[ -n "${ROWS}" ]] || die "${MANIFEST} lists no debs"

FAILS=0
while IFS=$'\t' read -r file sum _size; do
    src="$(awk -F'\t' -v f="${file}" '$1 == f { print $2; exit }' "${PATHS}")"
    if [[ -z "${src}" ]]; then
        echo "[pi-archive-repo] FAIL ${file}: not in paths map ${PATHS}" >&2; FAILS=$((FAILS + 1)); continue
    fi
    cp "${src}" "${TMP}/${file}"
    got="$(sha256sum "${TMP}/${file}" | cut -d' ' -f1)"
    if [[ "${got}" != "${sum}" ]]; then
        echo "[pi-archive-repo] FAIL ${file}: sha256 ${got}, manifest pins ${sum}" >&2; FAILS=$((FAILS + 1))
    fi
done <<< "${ROWS}"
[[ ${FAILS} -eq 0 ]] || die "${FAILS} deb(s) failed; no repo written"

# No override file, so the only expected stderr is the "Wrote N entries" line.
(cd "${TMP}" && dpkg-scanpackages --multiversion . > Packages 2> scan.err) || die "dpkg-scanpackages failed: $(cat "${TMP}/scan.err")"
if grep -v 'info: Wrote [0-9]* entries' "${TMP}/scan.err" >&2; then die "dpkg-scanpackages warned (above)"; fi
rm -f "${TMP}/scan.err"

python3 - "${MANIFEST}" "${TMP}/Packages" <<'PY' || die "Packages disagrees with the manifest; no repo written"
import sys, yaml
m = yaml.safe_load(open(sys.argv[1]))
want = {e["filename"]: e for e in (m.get("packages") or []) + (m.get("resolve_only") or [])}
text = open(sys.argv[2]).read().strip()
stanzas = [dict(l.split(": ", 1) for l in s.splitlines() if ": " in l and not l.startswith(" "))
           for s in text.split("\n\n")] if text else []
bad = [] if len(stanzas) == len(want) else [f"{len(stanzas)} stanzas for {len(want)} manifest debs"]
for s in stanzas:
    f = s.get("Filename", "").removeprefix("./")
    e = want.get(f)
    if e is None:
        bad.append(f"{f}: not in the manifest"); continue
    for field, key in (("Package", "name"), ("Version", "version"), ("Architecture", "arch"),
                       ("Size", "size"), ("SHA256", "sha256")):
        if s.get(field) != str(e[key]):
            bad.append(f"{f}: {field} {s.get(field)!r}, manifest {key} {e[key]!r}")
for b in bad:
    print(f"[pi-archive-repo] FAIL {b}", file=sys.stderr)
sys.exit(1 if bad else 0)
PY

(cd "${TMP}" && sha256sum -- *.deb Packages > SHA256SUMS)
mv "${TMP}" "${OUT}"
echo "[pi-archive-repo] $(wc -l <<< "${ROWS}") debs, Packages verified against the manifest"
