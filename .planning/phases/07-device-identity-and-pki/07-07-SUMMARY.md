---
phase: 07-device-identity-and-pki
plan: "07"
subsystem: identity
tags: [aws-iot, mutual-tls, requests, credentials-provider, revocation]
requires: ["07-03: store paths + read_metadata", "07-05b: frozen broker contract", "07-06: device key/CSR/cert"]
provides: ["runtime/lib/arlowe_cloud.py: brokered CSR submission and IoT credential exchange (IDENT-04)"]
affects: ["07-08a identity CLI", "07-09 revocation probe", "09 OTA", "10 support mode"]
tech-stack: {added: [], patterns: ["module-level in-memory credential cache", "one-condition-per-exception cloud error hierarchy"]}
key-files: {created: [runtime/lib/arlowe_cloud.py, runtime/lib/tests/test_arlowe_cloud.py], modified: []}
key-decisions: ["403 maps to CertificateRevoked and nothing else", "cache TTL capped at poll_interval_seconds", "no AWS SDK and no vendored root CA on the device", "SigV4 deferred to Phase 9"]
duration: 41min
completed: 2026-09-11
---

# Phase 7 Plan 07: Cloud Client Summary

**Device certificate is the cloud credential: one HTTPS POST pairs, one mutual-TLS GET exchanges, and a 403 on that GET is the machine-checkable signal that revocation took effect.**

## Exceptions — exactly one condition each

| Exception | Raised when |
| --- | --- |
| `NotProvisioned` | `device.crt` / `device.key` / `device-id` missing, checked *before* any network call; or neither config nor `identity.json` yields an endpoint and alias |
| `ProvisioningRejected` | non-`https://` broker URL; any broker 4xx, with `.status` and `.reason` carrying the frozen code (`unauthorized`, `malformed_request`, `invalid_device_id`, `unparseable_csr`, `csr_subject_mismatch`, `not_found`) uncollapsed; or a 200 missing any of the six issuance fields |
| `CertificateRevoked` | credentials provider returns **403, and nothing else** — 07-09 asserts exit 6 on this alone, so no broad `except` may swallow it |
| `CloudUnavailable` | transport error or timeout, any 5xx (including the broker's `502 issuance_failed`), or an unusable 200 body |

## Endpoint resolution, cache TTL, staging overrides

`resolve_endpoints()` per field: `config.identity.credentials_endpoint` / `.role_alias` when non-empty, else what `provision` wrote to `identity.json` — read only via `arlowe_identity.read_metadata()`, so that file's shape keeps one owner. Its `ValueError` on corrupt JSON propagates deliberately: a provisioned device with an unreadable `identity.json` is a fault, not a factory state. Neither value is ever a tracked literal.

TTL is `min(expiration - 60s, identity.poll_interval_seconds)`, module-level and in memory, never on disk. Revocation cannot retract an already-issued STS token, so the honest bound is `max(poll_interval, remaining_lifetime)`; with `credentialDurationSeconds=900` (07-05a) and the schema's 900s floor on `poll_interval_seconds`, the cap collapses that to one polling interval. Pinned numerically by `test_cache_ttl_is_capped_at_the_poll_interval` — trap 3's only live check. Both `fetch_credentials(force_refresh=False)` and `clear_credential_cache()` are exported because 07-09's probe warms the cache in-process, revokes, then re-reads without a refresh.

`ARLOWE_BROKER_CA_BUNDLE` and `ARLOWE_CLOUD_CA_BUNDLE` supply `verify=` for the broker POST and the credentials GET respectively; both are staging-only, for self-signed TLS, and default to the system trust store. No root CA is vendored — bookworm's `ca-certificates` already carries Amazon Root CA 1, and a `*.pem` under `/opt/arlowe` trips 07-04's build gate.

## Verification

145 tests pass in a `debian:bookworm` container against cryptography 38.0.4 / requests 2.28.1, the real CI surface; the suite makes zero network calls and generates its key material at runtime. No AWS SDK import, no account-identifying literal, no key-shaped tracked file, `scripts/sanitize/check.sh` exits 0. Net diff 510 lines plus this summary, inside the plan's 550 hard stop. **Deviations from plan:** none — docstring prose was compressed twice to hold the line budget, and no assertion was removed.
