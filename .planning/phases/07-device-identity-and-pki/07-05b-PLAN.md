---
phase: 07-device-identity-and-pki
plan: 05b
type: execute
wave: 3
depends_on: ["07-05a"]
files_modified:
  - scripts/pki/broker.py
  - scripts/pki/requirements.txt
  - scripts/pki/tests/test_broker.py
  - scripts/pki/README.md
autonomous: true

must_haves:
  truths:
    - "The CSR broker accepts a bearer token and a CSR and returns a signed certificate, and does not care who issued the token"
    - "A CSR whose subject CN does not match the submitted device_id is rejected, so the issued cert is traceable to the derived ID"
    - "Authorization binds to the IoT Thing name and certificate id, not to the CSR subject"
    - "No AWS account id, endpoint prefix, or token is ever written to a tracked file"
  artifacts:
    - path: "scripts/pki/broker.py"
      provides: "owner-token-authenticated CreateCertificateFromCsr broker (dev host only)"
      min_lines: 100
    - path: "scripts/pki/tests/test_broker.py"
      provides: "broker request-handling tests against a mocked IoT client"
      min_lines: 60
  key_links:
    - from: "scripts/pki/broker.py"
      to: "iot:CreateCertificateFromCsr"
      via: "boto3 iot client"
      pattern: "create_certificate_from_csr"
    - from: "scripts/pki/broker.py"
      to: "scripts/pki/.staging-env"
      via: "reads ARLOWE_PKI_POLICY / ARLOWE_PKI_ROLE_ALIAS / ARLOWE_PKI_CREDENTIALS_ENDPOINT from the environment"
      pattern: "ARLOWE_PKI_"
---

<objective>
Build the owner-token CSR broker and freeze the `POST /v1/certificates` contract that plan 07-07's
device client implements against.

Purpose: the device needs somewhere to send its CSR. Per the owner's settled decisions this is
**not** an owner-account backend — the broker checks a bearer token and does not care who minted it,
so a hand-minted token for one unit and a token from a future Phase 8 account system both work
unchanged.
Output: `scripts/pki/broker.py` + its tests — dev host only, never shipped in the image.

The HTTP contract defined here is frozen. Plan 07-07 writes `request_certificate` against it and
plan 07-09 runs both ends together.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/STATE.md
@.planning/phases/07-device-identity-and-pki/07-RESEARCH.md
@.planning/phases/07-device-identity-and-pki/07-01-SUMMARY.md
@.planning/phases/07-device-identity-and-pki/07-05a-SUMMARY.md
@scripts/pki/README.md
@scripts/sanitize/check.sh
</context>

<tasks>

<task type="auto">
  <name>Task 1: The owner-token CSR broker</name>
  <files>scripts/pki/broker.py, scripts/pki/requirements.txt</files>
  <action>
Create `scripts/pki/broker.py` — a small HTTPS service, run on the dev host only, that stands in for
the owner-authenticated CSR broker. Use `http.server` + `ssl` + `boto3`; do not pull in a web
framework for a stand-in.

`scripts/pki/requirements.txt`: `boto3==1.35.68` (or the current stable pin at execution time —
record the chosen pin in the SUMMARY). This file is dev-host only and must never be referenced by a
pi-gen stage.

Contract — **this is the interface plan 07-07's `request_certificate` implements against, so it is
frozen here**:

```
POST /v1/certificates
  Authorization: Bearer <owner-token>
  Content-Type: application/json
  Body: {"device_id": "<32 hex chars>", "csr": "<PEM CSR>"}

200 -> {"certificate_pem": "<PEM>",
        "certificate_id": "<hex>",
        "certificate_arn": "arn:aws:iot:...",
        "thing_name": "<device_id>",
        "credentials_endpoint": "<host>",
        "role_alias": "<alias>"}
401 -> {"error": "unauthorized"}
400 -> {"error": "<reason>"}   malformed JSON, unparseable CSR, or CSR CN != device_id
502 -> {"error": "issuance_failed", "detail": "<aws error code>"}
```

Behaviour:
- **Token check is the only authentication, and it is deliberately dumb.** Compare the bearer token
  against `$ARLOWE_BROKER_TOKEN` with `hmac.compare_digest`. The broker does not know or care who
  issued the token. Put that in the module docstring, citing the settled decision: the device side
  is token-agnostic and the owner-account question is Phase 8's. Do not build an account system, a
  user table, or a token-minting endpoint here.
- Parse the CSR with `cryptography.x509.load_pem_x509_csr` and verify its subject CN equals the
  submitted `device_id`. A mismatch is a 400. This is the binding that makes the issued cert
  traceable to the derived ID.
- Call `iot.create_certificate_from_csr(certificateSigningRequest=..., setAsActive=True)`.
- Call `iot.create_thing(thingName=device_id)` (tolerating `ResourceAlreadyExistsException`),
  `iot.attach_thing_principal(...)` and `iot.attach_policy(policyName=$ARLOWE_PKI_POLICY, target=arn)`.
  **Authorization binds to the Thing name and certificate ID, not to the CSR subject** — AWS is not
  documented to preserve the CSR CN verbatim in the issued certificate, and this design must not
  depend on it. Comment that.
- Return the JSON above, sourcing `credentials_endpoint` and `role_alias` from
  `$ARLOWE_PKI_CREDENTIALS_ENDPOINT` / `$ARLOWE_PKI_ROLE_ALIAS` — the names frozen by 07-05a's
  `.staging-env`. Fail loudly at startup if `ARLOWE_BROKER_TOKEN`, `ARLOWE_PKI_POLICY`,
  `ARLOWE_PKI_ROLE_ALIAS` or `ARLOWE_PKI_CREDENTIALS_ENDPOINT` is unset, rather than returning
  half-populated 200s at request time.
- Serve over TLS. For staging, accept `--certfile`/`--keyfile` for a self-signed pair and document
  generating one with `openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 ...`.
- Log every request with device_id, decision and AWS error code. Never log the token.
  </action>
  <verify>
`python3 -c "import ast; ast.parse(open('scripts/pki/broker.py').read())"`
`grep -q "compare_digest" scripts/pki/broker.py`
`grep -q "create_certificate_from_csr" scripts/pki/broker.py`
`ARLOWE_BROKER_TOKEN=x python3 scripts/pki/broker.py --help` prints usage and exits 0
Starting the broker with `ARLOWE_BROKER_TOKEN` unset exits non-zero naming the missing variable
`bash scripts/sanitize/check.sh` exits 0
  </verify>
  <done>The broker enforces the bearer token, validates the CSR CN against the submitted device_id, issues via `CreateCertificateFromCsr`, binds the cert to a Thing named for the device-id, and returns the frozen six-field response shape.</done>
</task>

<task type="auto">
  <name>Task 2: Broker tests and the README section</name>
  <files>scripts/pki/tests/test_broker.py, scripts/pki/README.md</files>
  <action>
Write `scripts/pki/tests/test_broker.py` with a mocked boto3 IoT client (`unittest.mock`) covering:
missing/blank/wrong bearer token -> 401; malformed JSON -> 400; CSR whose CN does not match
`device_id` -> 400; happy path -> 200 with all six response fields present and `setAsActive=True`
passed; `create_thing` raising `ResourceAlreadyExistsException` -> still 200; a generic
`ClientError` from `create_certificate_from_csr` -> 502; the token never appears in any log record
(capture with `caplog`).

**Generate the test CSRs in-test with `cryptography`. Do not commit a fixture CSR, key or
certificate.** Plan 07-04's build gate and plan 07-06's
`git ls-files | grep -E '\.(key|crt|csr|pem|p12|pfx)$'` check both treat a tracked key-shaped file
as a violation, and `scripts/pki/*.pem` is gitignored by 07-05a for the same reason.

These tests live under `scripts/pki/tests/` and are **NOT** part of the `runtime/lib` suite that
CI's `python-test` job runs; they need `boto3`, which the image never installs. Do not extend the CI
job to install boto3 for this. Document the local invocation in the README and record it in the
SUMMARY.

Fill the `## Running the broker` placeholder that plan 07-05a left in `scripts/pki/README.md`:
generating the self-signed TLS pair, the environment variables the broker requires (sourced from
`.staging-env` plus a hand-minted `ARLOWE_BROKER_TOKEN`), the `POST /v1/certificates` contract, the
fact that the device client honours `ARLOWE_BROKER_CA_BUNDLE` to trust the self-signed cert and that
this override exists for **staging only**, and the local test invocation.
  </action>
  <verify>
`python3 -m venv /tmp/brk && /tmp/brk/bin/pip install -r scripts/pki/requirements.txt cryptography pytest && /tmp/brk/bin/python -m pytest scripts/pki/tests/ -q` passes
`git ls-files scripts/pki | grep -E '\.(key|crt|csr|pem|p12|pfx)$'` returns nothing
`grep -q "ARLOWE_BROKER_CA_BUNDLE" scripts/pki/README.md`
`grep -q "/v1/certificates" scripts/pki/README.md`
`bash scripts/sanitize/check.sh` exits 0
  </verify>
  <done>Every response code in the frozen contract has a test against a mocked IoT client, no key-shaped fixture is tracked, and the README documents how to run the broker and its tests.</done>
</task>

</tasks>

<verification>
- `python3 -m pytest scripts/pki/tests/ -q` passes in a venv with boto3 + cryptography.
- `bash scripts/sanitize/check.sh` exits 0.
- `git grep -nE 'credentials\.iot\.[a-z0-9-]+\.amazonaws\.com|[0-9]{12}' -- scripts/pki` returns nothing.
- `grep -rn "scripts/pki" pi-gen/` returns nothing — no part of this ships in the image.
- Net diff under **425** lines. **This is an honest number, not the 350 an earlier draft carried.**
  The declared `min_lines` alone (100 + 60) floor this at 160, and a broker implementing the frozen
  request/response contract with `hmac.compare_digest` auth, CSR-CN-versus-device_id validation and
  four distinct error codes, plus a test per response code against a mocked IoT client and the
  README, realistically lands near 395. That clears the 600-line atomic-PR cap, so the 07-05a/07-05b
  split is doing its job — the split's whole purpose was fitting under that cap, and a stated number
  the artifact list already exceeds undermines it. Do not hit this number by dropping error-path
  tests: every code in the frozen contract is what plan 07-07 implements its client against.
</verification>

<success_criteria>
- A CSR broker exists that is token-agnostic by design, matching the settled owner decision, with no owner-account backend anywhere in it.
- The `POST /v1/certificates` request and response shapes are frozen and fully covered by tests, so plan 07-07 can implement the client against a written contract rather than against running code.
- Nothing key-shaped and nothing account-identifying is tracked.
</success_criteria>

<output>
After completion, create `.planning/phases/07-device-identity-and-pki/07-05b-SUMMARY.md`.
Record: the frozen `POST /v1/certificates` request and response shapes verbatim (07-07 implements
the client against them), the environment variables the broker requires, the
`ARLOWE_BROKER_CA_BUNDLE` staging override, the boto3 pin, and the local test invocation for
`scripts/pki/tests/`.
</output>

**Budget note.** `pr-checks.yml`'s `size-check` excludes lockfiles only, not `.planning/`, so this plan's `SUMMARY.md` (~60-90 lines) counts against the net diff. Budget accordingly.
