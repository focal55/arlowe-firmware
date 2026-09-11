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

Added by plan 07-05b.
