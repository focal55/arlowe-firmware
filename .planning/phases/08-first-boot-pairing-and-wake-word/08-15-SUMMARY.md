---
phase: 08-first-boot-pairing-and-wake-word
plan: 15
subsystem: pki-broker
tags: [broker, claim-codes, stub-iot, tdd]
requires: ["08-05 claim_codes.py", "08-15b stub_iot.py"]
provides: ["claim-code-gated POST /v1/certificates", "broker.py --stub-iot/--stub-ca-dir/--stub-fail issuance", "make_iot_client(args)"]
affects: ["08-19 revoke endpoint", "08-26", "08-27b"]
key-files:
  modified: [scripts/pki/broker.py, scripts/pki/tests/test_broker.py, scripts/pki/README.md]
duration: ~25min
completed: 2026-09-28
---

# Phase 8 Plan 15: Broker claim-code gate Summary

The broker redeems the device's bearer value against the 08-05 claim store under one store lock (check, issue, bind), and `--stub-iot` issues real certificates from 08-15b's StubIoT with no AWS account.

## Commits
- cc8e334 test(08-15): claim-code gate and stub-mode cases (RED: 28 failing on the missing config key)
- 8d11375 feat(08-15): claim-code gate, stub mode, README (GREEN: 53 passed)

## Interfaces for later plans
- `load_config(env=None, stub=False)`: requires `ARLOWE_BROKER_CLAIM_CODES` naming an existing file; under `stub=True` the three `ARLOWE_PKI_*` default to `arlowe-stub-device-policy`, `arlowe-stub-role-alias`, `credentials.stub-iot.invalid`.
- `make_iot_client(args)`: StubIoT under `--stub-iot` (`--stub-ca-dir` required; `--stub-fail issuance` -> 502, detail `InternalFailure`), else `boto3.client("iot")`.
- Processing order: bearer value that is not a claim code -> 401; malformed body/CSR -> 400; store refusal -> 401; issuance ClientError -> 502 (code stays unused).
- The broker serves only `POST /v1/certificates`; `/v1/certificates/revoke` is 08-19's.

## Decisions
- Store refusal is checked after body validation, because redemption needs `device_id`. An unknown code with a bad body gets 400; this reveals nothing about any code.
- The store is re-opened per request from the configured path, not cached, so `claim_codes.py revoke/release` take effect without a restart.

## Deviations from Plan
- Renamed `test_bad_token_is_401` to `test_bad_claim_code_is_401`. Added `test_missing_authorization_header_is_401` and `test_normalizes_the_presented_code` (the old parametrize's `None` case moved out because the fixture uses `None` as "default code").
- `--stub-ca-dir`/`--stub-fail` without `--stub-iot`, and `--stub-iot` without `--stub-ca-dir`, are argparse errors.
- Size: 345 code lines vs. the ~250 estimate (README grew to cover the `arlowe-broker.json` shape and the one-liner that produces it).

## Verification
- `python -m pytest scripts/pki/tests -q`: 53 passed (venv: boto3 1.35.68, cryptography 45.0.7).
- End-to-end over TLS on the dev machine: minted code -> 200, same device again -> 200, unknown code -> 401, other device -> 401; store shows `bound`; the code appears 0 times in the broker log.
- `scripts/sanitize/check.sh --grep-only`: clean.
- Not verified here: a unit pairing against this broker (08-27b, hardware).
