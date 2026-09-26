#!/bin/bash
# tests/phase-07.3/probe-pi-archive.sh --retention | --state
#
# Two read-only questions about archive.raspberrypi.com, answered against
# third_party/pi-archive/manifest.yml. Neither one fetches a deb.
#
# --retention: does the pool still serve every pinned deb at its pinned size?
#   A HEAD per manifest URL. bookworm is `oldstable` on the Pi archive, and an
#   aging suite is the likeliest to be pruned (07.3 research, Pitfall 8). When
#   one goes, the build host cache and the CI cache are the only copies left, and
#   the time to learn that is before the next cache miss, not during it. This runs
#   from a daily scheduled workflow rather than per PR: an upstream prune should
#   raise one issue, not turn every unrelated PR red.
#
# --state: a fingerprint of the Pi archive's current publish, for the SC4
#   checkpoint. It reports whether the archive has moved since the pin, and which
#   pinned packages the live index now serves at another version.
#
# Needs curl, python3 and PyYAML on the host.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="${PI_ARCHIVE_MANIFEST:-${REPO_ROOT}/third_party/pi-archive/manifest.yml}"
DIST="http://archive.raspberrypi.com/debian/dists/bookworm"
MIN_URLS=50

die() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
command -v curl >/dev/null || die "curl not found"
python3 -c 'import yaml' 2>/dev/null || die "python3 PyYAML not found (apt install python3-yaml)"
[[ -f "${MANIFEST}" ]] || die "manifest missing: ${MANIFEST}"

# Prints `name<TAB>version<TAB>size<TAB>filename<TAB>url`, one per pinned deb.
# SECTIONS is `packages` or `packages resolve_only`.
manifest_rows() {
    python3 - "${MANIFEST}" "$@" <<'PY'
import sys, yaml
m = yaml.safe_load(open(sys.argv[1]))
for section in sys.argv[2:]:
    for e in m.get(section) or []:
        print("\t".join(str(e[k]) for k in ("name", "version", "size", "filename", "url")))
PY
}

retention() {
    local rows total=0 failures=0 size filename url headers status length
    rows="$(manifest_rows packages resolve_only)" || die "cannot read ${MANIFEST}"
    while IFS=$'\t' read -r _ _ size filename url; do
        [[ -n "${url}" ]] || continue
        total=$(( total + 1 ))
        if ! headers="$(curl -sfI --retry 2 "${url}" | tr -d '\r')"; then
            printf '[FAIL] %s: HEAD failed (%s)\n' "${filename}" "${url}"
            failures=$(( failures + 1 )); continue
        fi
        status="$(printf '%s\n' "${headers}" | awk 'NR==1 {print $2}')"
        length="$(printf '%s\n' "${headers}" | awk -F': ' 'tolower($1)=="content-length" {print $2}' | tail -1)"
        if [[ "${status}" != "200" || "${length}" != "${size}" ]]; then
            printf '[FAIL] %s: status %s, Content-Length %s, pinned size %s\n' \
                "${filename}" "${status:-none}" "${length:-none}" "${size}"
            failures=$(( failures + 1 ))
        fi
    done <<< "${rows}"

    (( total >= MIN_URLS )) || die "only ${total} URLs read from the manifest (floor ${MIN_URLS}); this probe measured nothing"
    if (( failures > 0 )); then
        printf '\n%d of %d pinned debs failed.\n' "${failures}" "${total}"
        printf 'The Raspberry Pi pool no longer serves the files above; the build host cache and the CI cache are now the only copies; see third_party/pi-archive/INSTALL.md.\n'
        return 1
    fi
    printf '%d/%d pinned debs still served at their pinned size\n' "${total}" "${total}"
}

# This fetch is unsigned and trusted for NOTHING. It only fingerprints a
# publish; no byte of it reaches a build. The pin is the manifest's sha256.
state() {
    local tmp date sha
    tmp="$(mktemp -d)" || die "mktemp failed"
    trap 'rm -rf "${tmp}"' RETURN
    curl -sf --retry 2 -o "${tmp}/InRelease" "${DIST}/InRelease" || die "fetch failed: ${DIST}/InRelease"
    curl -sf --retry 2 -o "${tmp}/Packages.gz" "${DIST}/main/binary-arm64/Packages.gz" \
        || die "fetch failed: ${DIST}/main/binary-arm64/Packages.gz"
    date="$(sed -n 's/^Date: //p' "${tmp}/InRelease" | head -1)"
    [[ -n "${date}" ]] || die "InRelease carries no Date: field"
    sha="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "${tmp}/Packages.gz")"
    printf 'inrelease_date\t%s\n' "${date}"
    printf 'packages_gz_sha256\t%s\n' "${sha}"
    manifest_rows packages | python3 -c '
import gzip, sys
live = {}
for stanza in gzip.open(sys.argv[1], "rt", encoding="utf-8").read().split("\n\n"):
    f = dict(l.split(": ", 1) for l in stanza.splitlines() if ": " in l and not l.startswith(" "))
    if "Package" in f:
        live.setdefault(f["Package"], set()).add(f["Version"])
moved = []
for row in sys.stdin:
    name, version = row.rstrip("\n").split("\t")[:2]
    if version not in live.get(name, set()):
        moved.append((name, version, ",".join(sorted(live.get(name, ()))) or "absent"))
print(f"pinned_moved\t{len(moved)}")
for name, pinned, now in moved:
    print(f"moved\t{name}\t{pinned}\t{now}")
' "${tmp}/Packages.gz" || die "cannot parse the live Packages.gz"
}

case "${1:-}" in
    --retention) retention ;;
    --state) state ;;
    *) die "usage: $0 --retention | --state" ;;
esac
