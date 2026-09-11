---
phase: 07-device-identity-and-pki
plan: 05b
subsystem: infra
tags: [pki, aws-iot-core, csr-broker, http-contract, boto3, ops-tooling]

requires:
  - phase: 07-device-identity-and-pki
    provides: the six frozen ARLOWE_PKI_* names in scripts/pki/.staging-env (07-05a) and the 32-hex device id derived by runtime/lib/arlowe_identity.py (07-02)
provides:
  - scripts/pki/broker.py - owner-token CreateCertificateFromCsr broker, dev host only
  - the frozen POST /v1/certificates request and response contract
  - scripts/pki/tests/test_broker.py - a test per response code against a mocked IoT client
affects: [07-07, 07-09]

tech-stack:
  added: ["boto3==1.35.68 (dev host only, scripts/pki/requirements.txt)"]
  patterns:
    - "Request-handling logic is a pure function taking an injected boto3 client; the http.server subclass is a thin shell, so every response code is testable without AWS"
    - "Authentication surfaces that will later be replaced stay issuer-agnostic rather than growing a stub account model"

key-files:
  created:
    - scripts/pki/broker.py
    - scripts/pki/requirements.txt
    - scripts/pki/tests/test_broker.py
  modified:
    - scripts/pki/README.md

key-decisions:
  - "The bearer token is compared with hmac.compare_digest against $ARLOWE_BROKER_TOKEN and nothing else; no owner-account logic, per the settled decision that it is Phase 8's"
  - "Authorization binds to the IoT Thing name and certificate arn, never to the CSR subject, because AWS does not document preserving the CSR CN in the issued certificate"
  - "Four distinct 400 reasons rather than one, so 07-07's client can tell a retryable client bug from a genuine identity mismatch"
  - "All four required env vars are checked at startup, not per request, so a misconfigured broker refuses to boot instead of serving a 200 a device would cache"
  - "cryptography is bounded >=38.0.4,<46 on the dev host to stay on the API surface the bookworm device actually has"

patterns-established:
  - "scripts/pki/tests/ is deliberately outside CI's python-test job; boto3 is not an image dependency and the job must not grow one"

duration: 25min
completed: 2026-09-11
---

# Phase 7 Plan 05b: Owner-token CSR broker Summary

**A ~220-line dev-host HTTPS service that checks one bearer token, refuses any CSR whose subject CN is not the submitted device id, and issues through `iot:CreateCertificateFromCsr` — freezing the `POST /v1/certificates` shapes that plan 07-07 writes its device client against.**

## Performance

- **Duration:** 25 min
- **Tasks:** 2/2
- **Files:** 3 created, 1 modified
- **Net diff:** 448 lines before this SUMMARY

## Accomplishments

- **The broker is token-agnostic by construction, not by convention.** `authorized()` does one thing: split the `Authorization` header, reject anything that is not a non-empty `Bearer`, and `hmac.compare_digest` the rest against `$ARLOWE_BROKER_TOKEN`. There is no user table, no account lookup, no token-minting endpoint, and the module docstring says why in the imperative so a future agent does not helpfully add one.
- **Every response code in the frozen contract is reachable in a test.** `handle_certificate_request(auth_header, body, iot, config)` takes the IoT client as an argument, so the 19 tests drive 401/400/200/502 against a `MagicMock` with zero AWS contact and zero network.
- **Nothing key-shaped or account-shaped is tracked.** Test CSRs are generated in-process with `cryptography`; `git ls-files scripts/pki | grep -E '\.(key|crt|csr|pem|p12|pfx)$'` is empty and the account-literal regex over `scripts/pki` returns nothing.

## Task Commits

1. **Task 1: broker.py + requirements.txt** — `29a8134` (feat)
2. **Task 2: tests + README section** — `cbf781d` (test)
3. **Trim: `--help` epilog no longer duplicates the README** — `d2cc5e2` (refactor)

## The frozen `POST /v1/certificates` contract

**07-07 implements `request_certificate` against exactly this. A renamed field or a changed status code breaks it.**

```
POST /v1/certificates
  Authorization: Bearer <owner-token>
  Content-Type: application/json
  {"device_id": "<32 hex chars>", "csr": "<PEM CSR>"}

200 {"certificate_pem": "<PEM>", "certificate_id": "<hex>",
     "certificate_arn": "arn:aws:iot:...", "thing_name": "<device_id>",
     "credentials_endpoint": "<host>", "role_alias": "<alias>"}
401 {"error": "unauthorized"}
400 {"error": "malformed_request" | "invalid_device_id" | "unparseable_csr" | "csr_subject_mismatch"}
502 {"error": "issuance_failed", "detail": "<aws error code>"}
```

- `device_id` must match `[0-9a-f]{32}` — the shape `derive_device_id()` produces. A non-string or wrong-shaped value is `invalid_device_id`, distinct from `malformed_request` (undecodable body, non-JSON, or a missing key).
- The CSR's subject CN must equal the submitted `device_id`, else `csr_subject_mismatch`. **That binding is the only thing making the issued cert traceable to the derived id.**
- `502` carries the AWS error code verbatim in `detail` so the client can distinguish `ThrottlingException` (retry) from `ResourceNotFoundException` (the staging PKI is not stood up). A `ClientError` from any of the three AWS calls produces it.
- Any path other than `/v1/certificates` is `404 {"error": "not_found"}`; bodies over 16 KiB are `400 malformed_request`.

**Authorization binds to the Thing name and certificate arn, never to the CSR subject.** After issuance the broker calls `create_thing(thingName=device_id)` (tolerating `ResourceAlreadyExistsException`), `attach_thing_principal` and `attach_policy(policyName=$ARLOWE_PKI_POLICY)`. AWS is not documented to carry the CSR CN into the issued certificate verbatim, so no policy may read it back.

## Environment, TLS, and the staging CA override

`broker.py` requires **four** variables and exits non-zero at startup naming the first missing one — it does not degrade to half-populated 200s at request time:

| Variable | Source |
|---|---|
| `ARLOWE_BROKER_TOKEN` | hand-minted, e.g. `openssl rand -hex 32`; never committed |
| `ARLOWE_PKI_POLICY` | `.staging-env` |
| `ARLOWE_PKI_ROLE_ALIAS` | `.staging-env`, echoed back in the 200 |
| `ARLOWE_PKI_CREDENTIALS_ENDPOINT` | `.staging-env`, echoed back in the 200 |

AWS credentials come from the ambient boto3 session (`AWS_PROFILE`/`AWS_REGION`), consistent with 07-05a keeping them out of `.staging-env`. `--certfile`/`--keyfile` default to `scripts/pki/broker-{cert,key}.pem`, which `.gitignore:73` covers; the README gives the `openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256` invocation.

**`ARLOWE_BROKER_CA_BUNDLE`** is the device-side counterpart 07-07 must honour: a path to the broker's self-signed certificate, used as the `verify=` bundle. **Staging only.** A production broker presents a publicly-trusted cert and the variable stays unset.

## Dependency pins and the test invocation

`scripts/pki/requirements.txt` pins **`boto3==1.35.68`** and bounds **`cryptography>=38.0.4,<46`**. The upper bound is not cosmetic: the device targets bookworm's 38.0.4 and the broker uses only that API subset (`load_pem_x509_csr`, `subject.get_attributes_for_oid`) — no `x509.verification`, no `not_valid_after_utc`. Locally resolved to `cryptography 45.0.7` on Python 3.11.

```bash
python3 -m venv /tmp/brk && /tmp/brk/bin/pip install -r scripts/pki/requirements.txt pytest
/tmp/brk/bin/python -m pytest scripts/pki/tests/ -q
```

`scripts/pki/tests/` is **not** in CI. `ci.yml` runs `pytest runtime/lib/tests/` by explicit path in both the `python-test` and `python-floor-bookworm` jobs, so these are not collected, and the jobs must not be extended to install boto3 — it is not an image dependency and adding it there would make CI assert against something the device does not have.

## Deviations from Plan

**1. [Rule 3 - Blocking] The worktree was branched from the wrong base.** HEAD was `9206c63` (Phase 6 `#116` lineage), not `plan/phase-7-device-identity`. Resolved on a clean tree with `git reset --hard plan/phase-7-device-identity`. This is the same defect 07-05a reported; it is now three-for-three on wave agents and is a worktree-creation bug, not an agent bug.

**2. `cryptography` carries an upper bound the plan did not ask for.** `cryptography>=38.0.4` alone is unresolvable on Python 3.11: pip picks 50.0.1, which ships no wheel for it and fails building the Rust extension. `<46` is the last line with 3.11 wheels and is the correct bound anyway, since drifting the dev host past the device's API surface is what the floor job exists to prevent.

**3. Net diff is 448 lines against a stated 425 budget.** Not resolved by dropping tests, per the plan's explicit instruction. One honest trim was taken (`d2cc5e2`, -6): the `--help` epilog duplicated the openssl invocation the README already carries. The remainder is the four distinct 400 reasons and the three-call 502 parametrization that 07-07 is written against. Still well under the 600-line atomic-PR cap, which is what the 05a/05b split exists to clear.

## Issues Encountered

**A `MagicMock` IoT client cannot be used with `except iot.exceptions.ResourceAlreadyExistsException`** — the attribute is a `Mock`, and `except` on a non-exception raises `TypeError`. The broker therefore catches `botocore.exceptions.ClientError` and compares `exc.response["Error"]["Code"]` as a string. This is also the more honest form: the modelled-exception classes are generated per-client, and the code string is what AWS actually sends.

## Verification Evidence

- `/tmp/brk/bin/python -m pytest scripts/pki/tests/ -q` → **19 passed**. `python3 -m pytest runtime/lib/tests/ -q` → 110 passed (unaffected).
- `env -u ARLOWE_BROKER_TOKEN broker.py` → exit 1, `broker.py: ARLOWE_BROKER_TOKEN is unset or empty`. Empty-string form identical. With the token set → exit 1 naming `ARLOWE_PKI_POLICY`.
- `ARLOWE_BROKER_TOKEN=x broker.py --help` → usage, exit 0.
- `bash scripts/sanitize/check.sh` → exit 0 (248 tracked files, 11 unit files).
- `git ls-files scripts/pki | grep -E '\.(key|crt|csr|pem|p12|pfx)$'` → empty.
- `git grep -nE 'credentials\.iot\.[a-z0-9-]+\.amazonaws\.com|[0-9]{12}' -- scripts/pki` → empty.
- `grep -rn "scripts/pki" pi-gen/` → empty. Nothing here ships.

**Not verified: a single real AWS call, and TLS serving.** No `create_certificate_from_csr` has been executed against an account; every AWS interaction is asserted against a mock shaped from the API docs in 07-RESEARCH. The `ssl.SSLContext` wrap in `main()` has never bound a socket. Plan 07-09 is the first time either runs for real.

## Next Phase Readiness

07-07 can write `request_certificate` against the contract above without reading `broker.py`, and must honour `ARLOWE_BROKER_CA_BUNDLE` and cap its credential cache at or below the 900s 07-05a pinned. 07-09 runs both ends: `setup-staging.sh` → broker → `arlowe-identity provision` → `revoke.sh`, and is where the mocked assumptions either hold or do not.
