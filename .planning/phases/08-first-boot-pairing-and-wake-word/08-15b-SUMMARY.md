---
phase: 08-first-boot-pairing-and-wake-word
plan: 15b
subsystem: pki
tags: [iot, stub, tls, broker, cryptography]
requires: []
provides: [scripts/pki/stub_iot.py StubIoT, "stub_iot.py tls" CLI]
affects: [08-15, 08-19]
key-files:
  created: [scripts/pki/stub_iot.py, scripts/pki/tests/test_stub_iot.py]
  modified: []
completed: 2026-09-28
---

# Phase 8 Plan 15b: Stub IoT backend and TLS generator Summary

In-memory boto3-IoT stand-in that signs real CSRs with a CA persisted in `ca_dir`, plus a `tls` subcommand that writes a SAN-bound broker pair and its `ca.pem`.

## Interface for 08-15 / 08-19

- `StubIoT(ca_dir, fail_issuance=False)`. CA files: `ca_dir/ca.pem`, `ca_dir/ca-key.pem` (0600), created on first use and reused after.
- Same keyword names as boto3: `create_certificate_from_csr(certificateSigningRequest, setAsActive)`, `create_thing(thingName)`, `attach_thing_principal(thingName, principal)`, `attach_policy(policyName, target)`, `describe_certificate(certificateId)` -> `{"certificateDescription": {certificateArn, certificateId, certificatePem, status}}`, `list_principal_things(principal)` -> `{"things": [...]}`, `update_certificate(certificateId, newStatus)`.
- `certificateId` = sha256 of the DER, hex. ARN = `arn:aws:iot:us-east-1:000000000000:cert/<id>`.
- Unknown certificate id or thing: `ClientError` `ResourceNotFoundException`. `fail_issuance`: `ClientError` `InternalFailure` (broker returns 502).
- `create_thing` is idempotent, as real IoT is for an identical create; it never raises `ResourceAlreadyExistsException`.
- `python3 scripts/pki/stub_iot.py tls --san <ip-or-name> [--san ...] --out DIR` writes `broker-cert.pem`, `broker-key.pem` (0600), `ca.pem`. The TLS CA key is discarded, so that `ca.pem` vouches for one pair only; it is a separate CA from the stub IoT CA.

## Verification

- RED: `pytest scripts/pki/tests/test_stub_iot.py` failed at collection (`No module named 'stub_iot'`).
- GREEN: `pytest scripts/pki/tests -q`: 25 passed under cryptography 38.0.4 (device pin) and 45.0.7 (upper bound), boto3 1.35.68.
- Ad hoc: `broker.handle_certificate_request` with `StubIoT` returned 200 (twice for the same device, exercising the idempotent thing path) and 502 `InternalFailure` with `fail_issuance=True`; a real TLS handshake against a `tls`-generated pair verified with `ca.pem` and hostname 127.0.0.1.
- `scripts/sanitize/check.sh --grep-only`: clean. pyflakes: clean.
- Not run: the `pki-broker` CI job (08-02) does not exist on main yet.

## Deviations from Plan

1. **Precondition check.** `grep -c FIRST_USER_PASS pi-gen/config` prints 1, not 0; the one match is the comment explaining that it is deliberately unset. No assignment exists and PR #201 is merged, so the precondition holds in substance.
2. **Size.** Code 211 lines and tests 127 against the plan's 130 and 70. The extra is `ResourceNotFoundException` handling, the thread lock (the broker is a `ThreadingHTTPServer`), and the cryptography-38 signature check in the tests (`verify_directly_issued_by` needs 40+).
3. **TLS CA is ephemeral** (key discarded) rather than reusing the stub IoT CA; the plan did not settle this, and keeping no key that the device trusts on disk is the safer default.

## Decisions Made

- `create_thing` is idempotent, as real IoT is, so the broker's `ResourceAlreadyExistsException` branch is not exercised through the stub.
