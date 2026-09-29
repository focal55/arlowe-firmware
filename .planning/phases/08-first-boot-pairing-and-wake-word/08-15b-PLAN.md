---
phase: 08-first-boot-pairing-and-wake-word
plan: 15b
type: tdd
wave: 1
depends_on: []
files_modified:
  - scripts/pki/stub_iot.py
  - scripts/pki/tests/test_stub_iot.py
autonomous: true

must_haves:
  truths:
    - "A stub IoT client signs real CSRs with a throwaway CA, tracks certificate status and thing attachment in memory, and can be told to fail issuance, so the broker runs on a dev machine with no AWS account."
    - "A self-signed TLS pair for a given LAN address can be generated for the local broker, and the device trusts it through ARLOWE_BROKER_CA_BUNDLE."
  artifacts:
    - path: "scripts/pki/stub_iot.py"
      provides: "StubIoT client, throwaway CA, TLS pair generator CLI"
      exports: ["StubIoT"]
  key_links:
    - from: "scripts/pki/stub_iot.py"
      to: "boto3 iot client surface used by scripts/pki/broker.py"
      via: "same method names and response keys"
      pattern: "def create_certificate_from_csr"
---

<objective>
Build the stub IoT backend the local broker runs on (CONTEXT: "cert step tested against a local broker with a stubbed IoT backend"; research Pattern 4). Split from 08-15 so the broker's claim-code gate and the fixture rewrite stay under 400 lines; this half touches no existing file, so it runs in wave 1.

Purpose: SC2's "obtains a device cert" and SC3's "cert issuance fail" become testable without the parked AWS account; 08-19's revoke needs `update_certificate` and `describe_certificate`.

**Honest PR size: ~200 lines.**
- stub_iot.py: 130 (StubIoT methods used by issuance and by 08-19's revoke: create_certificate_from_csr, create_thing, attach_thing_principal, attach_policy, describe_certificate, list_principal_things, update_certificate 80; CA and TLS generation CLI 50)
- test_stub_iot.py: 70 (6 cases)

130 + 70 = 200.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/phases/08-first-boot-pairing-and-wake-word/08-RESEARCH.md
@scripts/pki/broker.py
@scripts/pki/tests/test_broker.py
</context>

<execution_notes>
- **Phase precondition (from 08-01): PR #201 is merged and `git show main:pi-gen/config | grep -c FIRST_USER_PASS` prints 0.** If not, stop and report.
- Dev host only. `cryptography>=38.0.4,<46` is already pinned in `scripts/pki/requirements.txt`; use only that API. `botocore` is available in the `pki-broker` job and locally per the README.
- Match the boto3 IoT method names and response keys `broker.py` reads (read it; do not guess). `fail_issuance=True` makes `create_certificate_from_csr` raise `botocore.exceptions.ClientError` with code `InternalFailure`, which the broker maps to 502.
- Stub state is in memory, keyed by certificate id (sha256 of the DER, hex). The CA lives in a directory argument (`ca_dir`), created on first use, so a restarted broker keeps signing with the same CA.
- `python3 stub_iot.py tls --san <ip-or-name> --out DIR` writes `broker-cert.pem`, `broker-key.pem` (0600) and `ca.pem`. No PEM is committed: tests generate into `tmp_path` (07-04's build gate).
- The AWS path must not import this module; 08-15 imports it only under `--stub-iot`.
- Test import: `sys.path.insert(0, <scripts/pki>)` as `test_broker.py` already does.
</execution_notes>

<feature>
  <name>Stub IoT backend and TLS generator</name>
  <files>scripts/pki/stub_iot.py, scripts/pki/tests/test_stub_iot.py</files>
  <behavior>
    - `create_certificate_from_csr` returns `certificateArn`, `certificateId`, `certificatePem`; the PEM verifies against the stub CA and its public key equals the CSR's.
    - `describe_certificate(certificateId=…)` returns that PEM and status `ACTIVE`; after `update_certificate(certificateId=…, newStatus="REVOKED")` it returns `REVOKED`.
    - `list_principal_things(principal=arn)` returns the thing `attach_thing_principal` attached.
    - `fail_issuance=True` → `ClientError` with code `InternalFailure`.
    - A second `StubIoT(ca_dir)` on the same directory signs with the same CA.
    - `stub_iot.py tls --san 192.0.2.10 --out DIR` writes a cert whose SAN contains that IP and that verifies against `ca.pem`; the key file is 0600.
  </behavior>
  <implementation>A plain class plus an argparse `tls` subcommand.</implementation>
</feature>

<tasks>

<task type="auto">
  <name>Task 1: Cases (RED)</name>
  <files>scripts/pki/tests/test_stub_iot.py</files>
  <action>One case per behaviour bullet, CSRs generated in-process. Run: fails on import.</action>
  <verify>
    python3 -m pytest scripts/pki/tests/test_stub_iot.py -q; echo "rc=$?"   # expect: failures
  </verify>
  <done>Cases fail because the stub does not exist.</done>
</task>

<task type="auto">
  <name>Task 2: Stub (GREEN)</name>
  <files>scripts/pki/stub_iot.py</files>
  <action>Implement per the spec and notes.</action>
  <verify>
    python3 -m pytest scripts/pki/tests -q                   # expect: all pass
    scripts/sanitize/check.sh --grep-only
    git diff --shortstat main -- . ':(exclude).planning/**'    # expect: ~200
  </verify>
  <done>A local IoT stand-in issues, tracks and revokes real certificates, and the local broker can get a TLS pair.</done>
</task>

</tasks>

<verification>
- `pki-broker` job (08-02) passes once both have merged.
</verification>

<success_criteria>
The broker has an IoT backend to talk to before the AWS account exists.
</success_criteria>

<output>
After completion, create `.planning/phases/08-first-boot-pairing-and-wake-word/08-15b-SUMMARY.md`.
</output>
