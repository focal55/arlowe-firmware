---
phase: 08-first-boot-pairing-and-wake-word
plan: 19
subsystem: pki-broker
tags: [broker, revoke, ecdsa, claim-codes, stub-iot]
requires:
  - phase: 08-06
    provides: revoke request contract, arlowe_pki.sign_payload
  - phase: 08-05
    provides: ClaimStore.release_device
  - phase: 08-15
    provides: StubIoT describe_certificate / list_principal_things / update_certificate
provides:
  - POST /v1/certificates/revoke on scripts/pki/broker.py
  - broker.handle_revoke_request(body, iot, store, now)
affects: [08-18 factory reset, 08-28 AWS exercise]
tech-stack:
  added: []
  patterns: [device-key signature as sole authorization, uniform 401 for every refusal]
key-files:
  created:
    - scripts/pki/tests/test_broker_revoke.py
  modified:
    - scripts/pki/broker.py
    - scripts/pki/README.md
duration: 25min
completed: 2026-09-29
---

# Phase 8 Plan 19: Broker Revoke Endpoint Summary

**Device-signed `POST /v1/certificates/revoke` on the broker: ECDSA-verified against the certificate's own key, 300 s freshness, Thing binding check, idempotent REVOKED and claim-code release.**

## Accomplishments

- `handle_revoke_request(body, iot, store, now)` returns `(status, dict)`; `store` is a `ClaimStore`, `now` an aware UTC datetime.
- Check order: parse (400) -> freshness |now - issued_at| <= 300 s -> `describe_certificate` -> signature over canonical JSON -> `list_principal_things` contains `device_id` -> `update_certificate REVOKED` (skipped if already revoked) -> `store.release_device(device_id)`.
- Every refusal after parsing is `401 {"error":"unauthorized"}`; the log line carries the reason (`stale_request`, `unknown_certificate`, `bad_signature`, `device_not_attached`).
- `do_POST` routes both paths; the store is re-opened per request, as for issuance.
- README documents the contract and the offline-reset path (`claim_codes.py release` plus `revoke.sh`).

## Task Commits

1. Task 1: Cases (RED) - `f9f7450`
2. Task 2: Endpoint (GREEN) - `5e85897`

## Verification

- `python -m pytest scripts/pki/tests -q`: 66 passed (13 new).
- RED run before the endpoint: 12 failed, all `AttributeError: ... handle_revoke_request`.
- HTTPS smoke (scratch script, not committed): broker `--stub-iot` process, issuance with a bearer code, then `arlowe_cloud.revoke_certificate(..., arlowe_pki.sign_payload)` -> 200 `{"revoked": true, ...}`, store entry `bound` -> `unused`; a foreign `device_id` -> 401, raised on the device as `ProvisioningRejected`.
- `scripts/sanitize/check.sh`: clean. Net size 284.
- Not verified: the AWS half (real `describe_certificate` / `list_principal_things`). Deferred to 08-28, as the plan states.

## Deviations from Plan

1. **[Rule 2 - Missing Critical] 502 for AWS failures other than not-found.** The plan lists only 200/400/401. A throttled or failed `update_certificate` answering 401 would mark the device's revoke as a definitive rejection (exit 3) instead of unavailable (exit 4). Now `ResourceNotFoundException`/`InvalidRequestException` -> 401, anything else -> `502 {"error":"revoke_failed","detail":<code>}` with the claim code left bound. One extra test.
2. **Malformed `issued_at` or non-string fields -> 400** (plan said missing field or non-JSON). Undecodable base64 signature -> 401 as a bad signature.
3. The `arlowe_pki` case uses `ensure_keypair()` with `arlowe_identity.KEY_PATH` monkeypatched, and builds the CSR in the test instead of `ensure_csr`, so no other identity paths need relocating.

## Notes for Later Plans

- Response body is `{"revoked": true, "certificate_id": ...}`; the device ignores it (any 200 = revoked).
- The endpoint does not detach the Thing principal or policy; teardown still handles those.
- `list_principal_things` is not paginated here; a certificate attached to more than one page of Things is not a case this system creates.
