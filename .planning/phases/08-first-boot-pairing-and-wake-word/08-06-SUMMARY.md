---
phase: 08-first-boot-pairing-and-wake-word
plan: 06
subsystem: identity
tags: [arlowe-identity, broker, revoke, ecdsa, tls, exit-codes]
requires:
  - phase: 07
    provides: arlowe-identity CLI, arlowe_cloud.request_certificate, frozen exit codes 0/2/3/4/5/6
provides:
  - "arlowe-identity revoke --json (device-key signed, no bearer token)"
  - "{ok:false, exit, error, http_status} failure payload on provision and revoke under --json"
  - "CloudUnavailable.status (5xx status, None when no response arrived)"
  - "arlowe_pki.sign_payload and arlowe_cloud.revoke_certificate"
affects: [08-18, 08-19, pairing daemon, factory reset]
tech-stack:
  added: []
  patterns:
    - "Per-test TLS broker fixture: throwaway CA + 127.0.0.1 cert from cryptography, ssl-wrapped http.server"
key-files:
  created: []
  modified:
    - runtime/cli/identity
    - runtime/lib/arlowe_cloud.py
    - runtime/lib/arlowe_pki.py
    - runtime/lib/tests/test_arlowe_cloud.py
    - runtime/lib/tests/test_identity_cli.py
key-decisions:
  - "Revoke failures reuse ProvisioningRejected/CloudUnavailable, so exit 3/4 and the payload map identically for provision and revoke"
  - "revoke_certificate rejects non-https URLs like request_certificate, although it carries no token"
  - "sign_payload loads device.key and never generates one"
duration: ~35min
completed: 2026-09-28
---

# Phase 8 Plan 06: Identity JSON failure payload and device revoke Summary

**`arlowe-identity` now reports failures as `{ok, exit, error, http_status}` under --json, so SC3's four errors are separable on (exit, http_status). A new `revoke` subcommand asks the broker to revoke the current certificate with an ECDSA-SHA256 signature by device.key and no bearer token.**

## Interface for downstream plans (08-18, 08-19)

- `arlowe-identity revoke --json [--ca-broker-url URL]`. URL resolution matches provision. The CA comes only from `ARLOWE_BROKER_CA_BUNDLE`.
  - Success: exit 0, `{"ok": true, "certificate_id": ...}`.
  - No `certificate_id` or `device_id` in identity.json: exit 5, `error: "not_provisioned"`, `http_status: null`. No request is sent.
  - 4xx: exit 3, `error` is the broker's `error` field.
  - 5xx: exit 4, `error: "unavailable"` with the status.
  - Transport or TLS failure: exit 4, `error: "unavailable"`, `http_status: null`.
- Provision failure mapping: 401 gives exit 3 with `unauthorized`/401. Another 4xx gives exit 3 with the broker reason and status. 5xx gives exit 4, `unavailable`, with the status. An unreachable broker gives exit 4, `unavailable`, null.
- Wire contract as the plan specified: `POST /v1/certificates/revoke`, body `{device_id, certificate_id, issued_at, signature}`. `issued_at` is `%Y-%m-%dT%H:%M:%SZ` UTC. `signature` is the base64 DER signature over `json.dumps({certificate_id, device_id, issued_at}, sort_keys=True, separators=(",", ":"))`. Timeout is 20 s.
- Human-mode output (no --json) is unchanged. Failures still print `arlowe-identity: <message>` to stderr in both modes.

## Commits

- 6b4e8b0 test(08-06): failure detail and revoke cases (RED: 15 new cases failed, 43 passed)
- 0d92a80 feat(08-06): failure payload, sign and revoke (GREEN)

## Verification

- `python-test` equivalent (`runtime/lib/tests/ runtime/voice/tests/`, Python 3.11, cryptography 43.0.3): 194 passed, 1 skipped. The skip already exists on main.
- `python-floor-bookworm` equivalent (debian:bookworm container, apt python3-cryptography 38.0.4): 182 passed. This includes the TLS fixture on bookworm's OpenSSL, requests and urllib3.
- `scripts/sanitize/check.sh`: clean. pyflakes on all five files: clean.
- Code diff excluding .planning: 5 files, +384/-16.

## Deviations from Plan

1. **Precondition check:** `git show main:pi-gen/config | grep -c FIRST_USER_PASS` prints 1, not 0. PR #201 is merged, and the one match is a comment saying the variable is deliberately unset (`# ... FIRST_USER_PASS is deliberately unset`). No assignment exists. I proceeded because the intent of the precondition holds, but the check as written is wrong. It should be `grep -c '^FIRST_USER_PASS='`.
2. **ProvisioningRejected message:** changed from "broker rejected the CSR" to "broker rejected the request", because revoke now raises it too. No test or script matched the old text.
3. **Response parsing shared:** `request_certificate`'s non-200 and unparseable-body handling moved into `_broker_body` so revoke uses the same mapping. Behaviour is unchanged, and the existing tests cover it.
4. **`test_token_never_printed` passed at RED.** It guards against regression, and the old code already kept the token out of output.
5. **Size:** 400 code lines against the ~360 estimate. The TLS fixture (key identifiers and key usage so the chain also passes OpenSSL strict X.509 mode) and the subprocess env builder cost the difference.

## Next Phase Readiness

- A 200 reply without `"revoked": true` is still reported as success. The contract defines 200 as revoked, so nothing checks the body. If 08-19 can return 200 for a no-op, tighten this here.
- The CLI subprocess tests strip `REQUESTS_CA_BUNDLE`, `CURL_CA_BUNDLE` and `SSL_CERT_FILE`. On a device, these also change what "CA bundle unset" means. The pairing daemon's unit must not set them.
