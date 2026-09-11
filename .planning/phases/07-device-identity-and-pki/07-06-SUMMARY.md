---
phase: 07-device-identity-and-pki
plan: 06
subsystem: identity
tags: [pki, p-256, csr, x509, cryptography, bookworm-api-floor, tdd]
requires:
  - phase: 07-02
    provides: the python-floor-bookworm CI job that enforces the cryptography 38.0.4 API surface
  - phase: 07-03
    provides: KEY_PATH / CSR_PATH / CERT_PATH and write_secret, the umask-independent O_EXCL writer
provides:
  - "arlowe_pki.py: P-256 keypair generation, CSR building, certificate persistence and inspection"
  - "IdentityMismatch: the error for persisted material that does not belong to this device or key"
  - "certificate_summary(): the public-facts dict consumed by arlowe-identity status and boot-check"
affects: [07-07, 07-08a, 07-08b]
tech-stack:
  added: [cryptography (already pinned in 07-02; first actual use)]
  patterns:
    - "Late-bound path access (ident.KEY_PATH) so tests relocating the store via ARLOWE_IDENTITY_DIR need patch only one module"
    - "Validate-then-write: parse and key-match checks complete before anything touches disk"
key-files:
  created: [runtime/lib/arlowe_pki.py, runtime/lib/tests/test_arlowe_pki.py]
  modified: []
duration: 35min
completed: 2026-09-11
key-decisions:
  - "CSR subject CN is the device-id but is documented as human-facing provenance only; authorization binds to the IoT Thing name and certificate id (ADR-0007), because AWS is not documented to preserve the CSR subject verbatim"
  - "device.crt is 0600 despite a certificate being public, because SC3 states 0600 and 07-04's build gate tests exact equality"
  - "A CSR whose CN disagrees with the persisted device-id raises IdentityMismatch rather than regenerating; silent replacement would hide a real upstream fault"
  - "not_valid_before / not_valid_after are rendered as Z-suffixed strings so callers never learn that the 38.0.4 floor returns naive UTC"
---

# Phase 07 Plan 06: Device Keypair, CSR and Certificate Storage Summary

**An entirely offline PKI module: a write-once P-256 key at exactly 0600 under any umask, a CSR whose subject CN is the device-id, and a certificate that is parsed and key-matched before a byte hits disk — all inside the Debian bookworm `cryptography` 38.0.4 API surface that CI, not a laptop, enforces.**

## Exported surface

```python
ensure_keypair() -> ec.EllipticCurvePrivateKey       # write-once; never returns bytes
ensure_csr(device_id: str) -> str                    # CSR PEM; raises IdentityMismatch
load_csr_pem() -> str                                # FileNotFoundError if absent
store_certificate(pem: str) -> None                  # ValueError / IdentityMismatch
load_certificate() -> x509.Certificate
certificate_matches_key(cert, key) -> bool
certificate_summary() -> dict                        # never touches the private key
class IdentityMismatch(RuntimeError)
```

`certificate_summary()` keys: `subject_cn`, `issuer_cn`, `serial_number`,
`not_valid_before`, `not_valid_after`, `fingerprint_sha256`.

## The two `IdentityMismatch` conditions

1. `ensure_csr(device_id)` finds an existing `device.csr` whose subject CN is not `device_id`.
2. `store_certificate(pem)` is handed a well-formed certificate whose public key is not the
   on-disk private key's. Nothing is written; `device.crt` stays absent.

Garbage that does not parse as X.509 raises `ValueError` from `cryptography` and likewise
leaves no `device.crt`.

## Re-provision semantics

`write_secret` is O_EXCL, so replacement is an explicit `CERT_PATH.unlink(missing_ok=True)`
inside `store_certificate`, after both validations pass. Re-issue after revocation is a
legitimate operation. The private key is untouched by this path and keeps its write-once
guarantee — only the certificate is replaceable.

## Confirmed bookworm 38.0.4 API list

`ec.generate_private_key`, `ec.SECP256R1`, `x509.CertificateSigningRequestBuilder`,
`x509.Name`, `x509.NameAttribute`, `NameOID.COMMON_NAME`, `serialization.Encoding.PEM`,
`serialization.PrivateFormat.PKCS8`, `serialization.NoEncryption`,
`serialization.load_pem_private_key`, `x509.load_pem_x509_csr`,
`x509.load_pem_x509_certificate`, `hashes.SHA256`, `cert.not_valid_before` /
`not_valid_after` (naive UTC).

Banned here: `x509.verification` and `not_valid_after_utc` / `not_valid_before_utc` — both 42+.

**Where the constraint lives:** the `python-floor-bookworm` job in `.github/workflows/ci.yml`
runs the whole `runtime/lib` suite in a `debian:bookworm` container against apt's
`python3-cryptography`. That job is the authority. A future reader reaching for a 42-only API
goes red in CI, not on the device. Do not replace it with a laptop-only pip pin.

## Verification performed

- 11 new tests green; full `runtime/lib` suite 121 passed — both inside `debian:bookworm`
  with `cryptography 38.0.4` printed, matching the CI job exactly.
- Offline end-to-end under `umask 0`: `openssl req -noout -subject` prints `CN = <device-id>`,
  `-text` contains `prime256v1`, self-signature verifies, `device.key` and `device.csr` are `0600`.
- `git ls-files | grep -E '\.(key|crt|csr|pem|p12|pfx)$'` returns nothing; all test key material
  is generated at runtime into `tmp_path`.

## Notes for the next plan

- 07-08a's `init` is exactly `ensure_device_id()` -> `ensure_keypair()` -> `ensure_csr(id)`.
- Paths are read through `ident.KEY_PATH` (not imported by name) so a test relocating the store
  patches `arlowe_identity` only. Keep that shape in `arlowe_cloud`.
- STATE.md was deliberately not modified: wave 3 runs three agents in parallel and a per-plan
  STATE edit would conflict at merge. The orchestrator records the wave.
