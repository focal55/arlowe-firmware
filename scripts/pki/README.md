# Staging PKI (ops host only)

Scripts that stand up, revoke against, and destroy the Phase 7 staging PKI in AWS IoT Core.

**Nothing here ships in the firmware image.** These are operator tools; `pi-gen/stage-arlowe/**`
must never reference `scripts/pki/`. The PKI is IoT Core's **native** issuance
(`iot:CreateCertificateFromCsr`, Amazon root CA); AWS Private CA is ruled out at ~$400/month and no
Private CA resource is created here. See
[ADR-0007](../../docs/architecture/0007-managed-pki-service-selection.md).

## Prerequisites

- AWS CLI **v2** on `PATH`.
- `AWS_PROFILE` and `AWS_REGION` exported, pointing at a **staging** account, never production.
  They are deliberately absent from `.staging-env`: which account you are aimed at should be an
  explicit act of the shell you are typing into, not something a script remembers for you.
- An IAM principal permitted to create IAM roles, IoT role aliases, IoT policies and certificates.

These scripts create **real, billable** resources. Always finish with `teardown-staging.sh`.

## Sequence

```bash
export AWS_PROFILE=arlowe-staging AWS_REGION=us-east-1

scripts/pki/setup-staging.sh                    # idempotent; --prefix defaults to arlowe-staging
# ... run the broker, provision a device, exchange credentials ...
scripts/pki/revoke.sh <certificate-id>          # the SC4 lever
scripts/pki/teardown-staging.sh                 # removes everything, including broker-minted certs
```

`setup-staging.sh` and `teardown-staging.sh` are both safe to re-run. Pass the same `--prefix` to
all three if you used a non-default one.

`revoke.sh` re-reads the status with `describe-certificate` and prints what AWS actually reports, so
the caller has proof rather than an assumption. It exits non-zero if the observed status differs
from the requested one. `--status ACTIVE` reactivates a certificate during iteration.

Teardown order is not cosmetic: AWS refuses to delete a certificate that is still `ACTIVE` or that
still has policies or things attached. `teardown-staging.sh` detaches policies, detaches and deletes
things, sets the certificate `INACTIVE`, and only then deletes it.

## `.staging-env`

`setup-staging.sh` writes `scripts/pki/.staging-env`. These six names are a **frozen contract** —
the CSR broker and the SC4 harness both read them, so do not rename them:

| Variable | Contents |
|---|---|
| `ARLOWE_PKI_PREFIX` | Resource name prefix (`arlowe-staging` by default) |
| `ARLOWE_PKI_REGION` | Region the resources live in |
| `ARLOWE_PKI_ROLE_ALIAS` | IoT role alias name |
| `ARLOWE_PKI_POLICY` | IoT policy attached to device certificates |
| `ARLOWE_PKI_CREDENTIALS_ENDPOINT` | `<account-prefix>.credentials.iot.<region>.amazonaws.com` |
| `ARLOWE_PKI_ROLE_ARN` | ARN of the role the credentials provider assumes |

**The account-identifier rule.** `ARLOWE_PKI_CREDENTIALS_ENDPOINT` carries an account-specific host
prefix and `ARLOWE_PKI_ROLE_ARN` embeds the 12-digit account id. Neither is on
`scripts/sanitize/banlist.txt`, so the sanitize gate will **not** catch one that gets committed.
`.staging-env` and `scripts/pki/*.pem` are gitignored for exactly this reason. The same rule applies
to the broker URL. Never write any of them as a literal into tracked source — they reach a device
through `identity.credentials_endpoint` / `identity.role_alias` / `identity.provisioning_url` or
through the provisioning response.

The role alias is created with `credentialDurationSeconds=900`, the AWS minimum. That is what
bounds SC4's revocation window to a single polling interval; the reasoning is in
`setup-staging.sh`.

## Running the broker

`broker.py` is the owner-authenticated CSR signer, **run on the dev host only**. It stands in for
whatever backend eventually does this job. Its token check is deliberately issuer-agnostic: it
compares the bearer token against `$ARLOWE_BROKER_TOKEN` with `hmac.compare_digest` and does not
know or care who minted it, so a hand-minted token for one unit and a token from a future
account system both work here unchanged. Do not add owner-account logic to it.

```bash
python3 -m venv .venv-broker && .venv-broker/bin/pip install -r scripts/pki/requirements.txt

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 \
  -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
  -keyout scripts/pki/broker-key.pem -out scripts/pki/broker-cert.pem

set -a; . scripts/pki/.staging-env; set +a
export ARLOWE_BROKER_TOKEN="$(openssl rand -hex 32)"     # hand-minted; never committed
.venv-broker/bin/python scripts/pki/broker.py --port 8443
```

It reads `ARLOWE_BROKER_TOKEN`, `ARLOWE_PKI_POLICY`, `ARLOWE_PKI_ROLE_ALIAS` and
`ARLOWE_PKI_CREDENTIALS_ENDPOINT` (the last three from `.staging-env`) and **exits non-zero at
startup naming the first one that is unset**, rather than serving half-populated `200`s a device
would then cache. `--certfile`/`--keyfile` default to `scripts/pki/broker-{cert,key}.pem`, which
`.gitignore` covers. AWS credentials come from the ambient boto3 session, not from `.staging-env`.

### `POST /v1/certificates` — frozen contract

Plan 07-07's device client is written against this. Changing a field name or a status code breaks
it.

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

The CSR's subject CN must equal the submitted `device_id`; a mismatch is a `400`, and that binding
is what makes the issued certificate traceable to the derived id. **Authorization itself binds to
the IoT Thing name and the certificate id, never to the CSR subject** — AWS is not documented to
carry the CSR CN into the issued certificate verbatim, so nothing may depend on reading it back.

The device client honours `ARLOWE_BROKER_CA_BUNDLE` (a path to the broker's self-signed
certificate) to trust this endpoint. **That override is for staging only.** A production broker
presents a publicly-trusted certificate and the variable is left unset; a device that needs it set
in the field is a device trusting an unverified issuer.

### Tests

```bash
python3 -m venv /tmp/brk && /tmp/brk/bin/pip install -r scripts/pki/requirements.txt pytest
/tmp/brk/bin/python -m pytest scripts/pki/tests/ -q
```

`scripts/pki/tests/` is **not** part of the `runtime/lib/tests/` suite CI runs — it needs boto3,
which the image never installs. Run it by hand when touching the broker. Test CSRs are generated
in-process; no key-, CSR- or certificate-shaped fixture is tracked.
