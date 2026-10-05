#!/usr/bin/env bash
# tests/phase-8/test-boot-check-identity.sh
#
# runtime/cli/boot-check must apply the same identity rule as the build-time
# authority scripts/lib/identity-store-check.sh: a PRIVATE KEY block is always
# identity material; a certificate-only file is identity material unless it is
# on a recognised vendored trust-store path (pip's bundled cacert.pem and kin).
#
# Seam relied on (all already exist in boot-check, same as test-boot-check.sh):
#   ARLOWE_ROOT, ARLOWE_IDENTITY_OWNER, ARLOWE_AXCL_SMI, and PATH shims for
#   systemctl, lsof and python3. The whole script runs on an unpaired temp
#   root; assertions look only at the "/opt/arlowe" identity line.
#
# Seam DEV must implement for the parity case (static extraction, no execution):
#   runtime/cli/boot-check defines two bash array literals, written one quoted
#   entry per line, with exactly these names and the same entries as the
#   authority (order-insensitive):
#       IDENTITY_MATERIAL_GLOBS=( 'x' ... )
#       _IDENTITY_TRUST_STORE_PATHS=( 'x' ... )
#   The array literal must open with `NAME=(` at line start and close with a
#   line-start `)`. Inline `-name` flags in a find expression no longer count.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOOT_CHECK="${REPO_ROOT}/runtime/cli/boot-check"
AUTHORITY="${REPO_ROOT}/scripts/lib/identity-store-check.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

FAILURES=0
ok()  { printf '[OK]   %s\n' "$1"; }
bad() { printf '[FAIL] %s\n' "$1" >&2; FAILURES=$(( FAILURES + 1 )); }
assert_rc()     { if [[ "$2" == "$1" ]]; then ok "$3 (exit $2)"; else bad "$3 (expected exit $1, got $2)"; fi; }
assert_out()    { if grep -qF -- "$1" "$OUT"; then ok "$2"; else bad "$2 -- output lacks: $1"; fi; }
assert_no_out() { if grep -qF -- "$1" "$OUT"; then bad "$2 -- output contains: $1"; else ok "$2"; fi; }

if ! command -v openssl >/dev/null 2>&1; then
    echo "openssl is required to generate fixtures" >&2
    exit 2
fi

SHIMS="${WORK}/bin"
mkdir -p "$SHIMS"
printf '#!/bin/sh\nexit 1\n' > "${SHIMS}/systemctl"
printf '#!/bin/sh\nexit 1\n' > "${SHIMS}/lsof"
printf '#!/bin/sh\nexit 0\n' > "${SHIMS}/python3"
printf '#!/bin/sh\nexit 0\n' > "${WORK}/axcl-smi"
chmod 0755 "${SHIMS}"/* "${WORK}/axcl-smi"

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -subj /CN=t -days 1 -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" 2>/dev/null
grep -q 'BEGIN CERTIFICATE' "${WORK}/cert.pem" || { echo "fixture: no certificate" >&2; exit 2; }
grep -q 'PRIVATE KEY' "${WORK}/key.pem" || { echo "fixture: no private key" >&2; exit 2; }
cat "${WORK}/cert.pem" "${WORK}/cert.pem" > "${WORK}/bundle.pem"

OWNER=$(stat -c '%U:%G' "${WORK}" 2>/dev/null || stat -f '%Su:%Sg' "${WORK}")

PIP_CA="opt/arlowe/venvs/x/lib/python3.11/site-packages/pip/_vendor/certifi/cacert.pem"
CERTIFI_CA="opt/arlowe/venvs/x/lib/python3.11/site-packages/certifi/cacert.pem"

# new_root <name>: fresh unpaired root with an otherwise clean identity store.
new_root() {
    ROOT="${WORK}/root-$1"
    mkdir -p "${ROOT}/var/lib/arlowe/identity" "${ROOT}/var/lib/arlowe/state" \
        "${ROOT}/opt/arlowe" "${ROOT}/etc/arlowe"
    chmod 0700 "${ROOT}/var/lib/arlowe/identity"
}
place() {  # place <src> <relpath under ROOT>
    mkdir -p "${ROOT}/$(dirname "$2")"
    cp "$1" "${ROOT}/$2"
}
run() {
    OUT="${WORK}/out-$1.log"
    PATH="${SHIMS}:${PATH}" ARLOWE_ROOT="$ROOT" ARLOWE_IDENTITY_OWNER="$OWNER" \
        ARLOWE_AXCL_SMI="${WORK}/axcl-smi" bash "$BOOT_CHECK" --first-boot >"$OUT" 2>&1
    RC=$?
}

# --- [trust-store] certificate-only pip bundle passes ---
new_root trust; place "${WORK}/bundle.pem" "$PIP_CA"; run trust
assert_out "OK  No identity material under /opt/arlowe" "[trust-store] cert-only pip cacert.pem is not identity material"
assert_no_out "FAIL Identity material" "[trust-store] no identity FAIL"
assert_rc 0 "$RC" "[trust-store] boot-check passes the tree"

# --- [certifi] certificate-only certifi bundle passes ---
new_root certifi; place "${WORK}/bundle.pem" "$CERTIFI_CA"; run certifi
assert_out "OK  No identity material under /opt/arlowe" "[certifi] cert-only certifi cacert.pem is not identity material"
assert_no_out "FAIL Identity material" "[certifi] no identity FAIL"
assert_rc 0 "$RC" "[certifi] boot-check passes the tree"

# --- [key-on-trust-path] a private key at the trust-store path always fails ---
new_root keypath; place "${WORK}/key.pem" "$PIP_CA"; run keypath
assert_out "FAIL Identity material under /opt/arlowe" "[key-on-trust-path] private key on a trust-store path fails"
assert_out "/${PIP_CA}" "[key-on-trust-path] offending path is listed"
assert_rc 1 "$RC" "[key-on-trust-path] boot-check fails the tree"

# --- [mixed] a bundle that also carries a key fails ---
new_root mixed; cat "${WORK}/cert.pem" "${WORK}/key.pem" > "${WORK}/mixed.pem"
place "${WORK}/mixed.pem" "$PIP_CA"; run mixed
assert_out "FAIL Identity material under /opt/arlowe" "[mixed] cert plus key on a trust-store path fails"
assert_rc 1 "$RC" "[mixed] boot-check fails the tree"

# --- [cert-elsewhere] cert-only file off the trust-store paths fails ---
new_root certelse; place "${WORK}/cert.pem" "opt/arlowe/runtime/device.pem"; run certelse
assert_out "FAIL Identity material under /opt/arlowe" "[cert-elsewhere] cert-only device.pem fails"
assert_out "/opt/arlowe/runtime/device.pem" "[cert-elsewhere] offending path is listed"
assert_rc 1 "$RC" "[cert-elsewhere] boot-check fails the tree"

# --- [cert-near-miss] a cacert.pem not under site-packages/certifi is not exempt ---
new_root nearmiss; place "${WORK}/cert.pem" "opt/arlowe/runtime/certifi/cacert.pem"; run nearmiss
assert_out "FAIL Identity material under /opt/arlowe" "[cert-near-miss] cacert.pem outside site-packages fails"
assert_rc 1 "$RC" "[cert-near-miss] boot-check fails the tree"

# --- [key-elsewhere] a .key file fails ---
new_root keyelse; place "${WORK}/key.pem" "opt/arlowe/runtime/device.key"; run keyelse
assert_out "FAIL Identity material under /opt/arlowe" "[key-elsewhere] device.key fails"
assert_out "/opt/arlowe/runtime/device.key" "[key-elsewhere] offending path is listed"
assert_rc 1 "$RC" "[key-elsewhere] boot-check fails the tree"

# --- [exempt-is-scoped] a legit bundle must not mask a real violation ---
new_root scoped; place "${WORK}/bundle.pem" "$PIP_CA"; place "${WORK}/cert.pem" "opt/arlowe/runtime/device.pem"; run scoped
assert_out "/opt/arlowe/runtime/device.pem" "[exempt-is-scoped] violation still reported next to a bundle"
assert_no_out "pip/_vendor/certifi/cacert.pem" "[exempt-is-scoped] bundle itself is not listed"
assert_rc 1 "$RC" "[exempt-is-scoped] boot-check fails the tree"

# --- [parity] boot-check and the authority agree on both lists ---
extract_array() {  # extract_array <file> <name> -> sorted entries, one per line
    sed -n "/^$2=(/,/^)/p" "$1" | grep -o "'[^']*'" | sort
}
for name in IDENTITY_MATERIAL_GLOBS _IDENTITY_TRUST_STORE_PATHS; do
    want=$(extract_array "$AUTHORITY" "$name")
    got=$(extract_array "$BOOT_CHECK" "$name")
    if [[ -z "$want" ]]; then
        bad "[parity] authority defines no $name (test is broken)"
    elif [[ -z "$got" ]]; then
        bad "[parity] boot-check defines no $name array literal"
    elif [[ "$want" == "$got" ]]; then
        ok "[parity] $name matches the authority"
    else
        bad "[parity] $name diverges from the authority: $(diff <(echo "$want") <(echo "$got") | tr '\n' ' ')"
    fi
done

if (( FAILURES > 0 )); then
    printf '%d check(s) failed\n' "$FAILURES" >&2
    exit 1
fi
echo "all checks passed"
