# ADR-0007: Managed PKI service selection — AWS IoT Core native issuance

<!-- status: proposed -->
**Status:** Proposed
**Date:** 2026-09-10
**Phase:** 7 (Device identity and PKI)
**Closes:** IDENT-01, SC1

This ADR is **Proposed**, not Accepted. Two of its load-bearing claims — that AWS preserves the
CSR subject CN, and that provisioning plus the credentials provider are genuinely unbilled — are
inferences, not measured facts. Plan 07-09 runs the staging flow end to end, reads a real bill,
and amends this document to Accepted with the observed evidence. This mirrors the amendment
convention already used by ADR-0005.

## Context

Every Arlowe needs one credential that proves "I am this specific device" to every cloud-facing
call the firmware makes: OTA manifest fetch (Phase 9), support-mode key issuance (Phase 10), and
whatever Phase 8 pairing binds to an owner account. REQUIREMENTS.md puts a custom CA explicitly
out of scope — "Custom CA / self-rolled crypto — use a managed PKI service" — so the question is
*which* managed service, not whether to run one.

The constraints that actually decide this:

- **Pre-revenue solo founder.** A recurring bill before the first unit ships is disqualifying.
- **One image for every unit.** Phase 6 builds a single image. Anything secret baked into it is
  on every unit and is extractable by anyone who buys one and reads the SD card.
- **No secure element.** The Pi 5 has no TPM and no discrete secure element. There is no hardware
  key protection available at any price on this hardware.
- **No CA to operate.** A solo founder owning root-key custody, HA, backup and CRL hosting is the
  exact burden the "use a managed PKI service" constraint exists to avoid.
- **Revocation must be real.** SC4 requires a revoked unit to stop working within one polling
  interval, verified end to end against a staging PKI.

### Candidates

| Option | Verdict | Reason |
|--------|---------|--------|
| **AWS IoT Core native issuance** | **SELECTED** | No per-CA subscription. Amazon-root-signed client certs, first-party revocation checked at authentication time, and a documented cert-to-STS-credential exchange. |
| **AWS Private CA** | Ruled out on cost | $400/month per CA (general-purpose) or $50/month (short-lived mode, 7-day max validity plus $0.058/cert). |
| **Azure IoT Hub + DPS** | Runner-up | Comparable capability, but the free tier cannot be upgraded in place — outgrowing it means creating a new hub and re-provisioning devices. Azure also has no equivalent of the AWS IoT credentials provider, so the cert-to-cloud-credential step would need to be designed rather than consumed. Per-operation pricing was not verified against Microsoft's own pricing page. Pick this only if there is an independent reason to be on Azure. |
| **Google Cloud IoT Core** | Dead | Retired 2023-08-16. Any tutorial referencing it predates the shutdown. |
| **Let's Encrypt / ACME** | Category error | ACME proves control of a public DNS name or public IP in order to issue a **server** certificate. An Arlowe on a home LAN behind NAT has neither and needs a **client** certificate. There is no ACME challenge type that proves "I am device serial X owned by account Y". This is not a cost or maturity objection. (ACME as a *protocol* is reusable by private CAs such as step-ca — but that is step-ca, not Let's Encrypt.) |
| **Smallstep `step-ca` (self-hosted)** | Ruled out on operational custody | `step-ca` is a well-reviewed CA implementation; this is not a "self-rolled crypto" objection and nothing here implies the software is untrustworthy. The objection is that self-hosting means *you operate the CA*: root-key custody, HA, backup, CRL/OCSP hosting and uptime all become the solo founder's problem, and a CA outage becomes a pairing outage. |
| **Smallstep Certificate Manager (hosted)** | Ruled out as unplannable | Verified 2026-09-10: the pricing page lists no prices and no free tier — "contact us for a scoping exercise". A single founder cannot plan a bill of materials against a sales call. Reviving this option means getting a quote, not assuming it is cheap. |
| **HashiCorp Vault PKI** | Ruled out on custody + churn | Self-hosted Vault carries step-ca's custody problem plus more operational surface. Managed HCP Vault tiers are reported as expensive relative to $0, but every figure available came from third-party aggregators that disagree with each other, so no number is quoted here as verified. Separately, HCP Vault Secrets was end-of-sale 2025-06-30 with EOL 2026-07-01 — a live data point about product churn in that line. |

### The AWS Private CA trap

This is the single most load-bearing sentence in this document: **"AWS PKI" does not mean AWS
Private CA.** A reader who hears "we use AWS for device certs" and reaches for AWS Private CA
lands on a ~$4,800/year line item before the first unit ships. AWS IoT Core issues certificates
from an Amazon root CA at no per-CA subscription cost, and that — not Private CA — is what this
project uses. Private CA is revisited only if a self-controlled root becomes a contractual
requirement.

## Decision

**Use AWS IoT Core's native Amazon-Root-CA certificate issuance, via the
`iot:CreateCertificateFromCsr` API.**

The device generates its own keypair and never transmits the private key. A small
owner-authenticated broker holds the AWS credentials and calls the issuance API on the device's
behalf.

### Cert lifecycle

**Issuance.** At first-boot pairing the device generates a P-256 keypair locally and builds a CSR
with subject `CN=<device-id>`. It POSTs the CSR, plus a bearer token supplied by the pairing flow,
to an owner-authenticated broker over HTTPS. The broker authenticates the token, then calls
`iot:CreateCertificateFromCsr`, `iot:AttachThingPrincipal` and `iot:AttachPolicy` with its own IAM
credentials, and returns the signed certificate. The device needs no AWS SDK and no MQTT client —
one HTTPS POST.

**Renewal: none.** AWS-issued IoT certificates expire `2049-12-31T23:59:59Z`. Rotation is a
deliberate operation (issue a new cert, verify it works, mark the old one INACTIVE), not a
scheduled one. There is no renewal daemon, no ACME client and no cron entry in this design. A
renewal treadmill is a permanent operational cost, and this decision avoids it entirely — which is
also why the $50/month AWS Private CA short-lived tier (7-day max validity) is not the cheap
escape it appears to be.

**Revocation.** `aws iot update-certificate --certificate-id <id> --new-status REVOKED`.
Certificate status is checked **server-side at authentication time**. The device carries zero
revocation logic: no CRL, no OCSP, no device-side deny list, nothing to keep fresh and nothing to
tamper with. Revocation is a single API call by the owner, and the device's only observable
response is that its next credential exchange fails.

### Revocation latency has a number

Marking a certificate REVOKED prevents **new** credential exchanges but does not retroactively
invalidate an already-issued STS token. The honest guarantee is therefore:

> revocation takes effect within `max(poll_interval, remaining_credential_lifetime)`.

Three design rules collapse that to a single number:

1. The IoT role alias is created with `credentialDurationSeconds = 900` — the minimum AWS allows.
2. `identity.poll_interval_seconds` defaults to `3600`, and its schema minimum is `900`, so the
   credential lifetime is always less than or equal to the polling interval.
3. The device client holds credentials in process memory only, for the life of a single poll, and
   re-exchanges on the next poll rather than caching to expiry.

The guaranteed bound is therefore **one polling interval**, and that is the number SC4 tests
against.

### Bootstrap trust: no claim certificates

Phase 6 ships **one image to every unit**. Any credential present in that image is present on
every unit and is extractable by anyone who buys one and reads the SD card. AWS "fleet
provisioning by claim" requires exactly such a shared credential — AWS's own guidance is to use a
per-batch claim certificate so a compromise stays containable, which presupposes per-batch image
builds this project does not do. **Claim certificates are rejected.**

Instead the device is **token-agnostic**: it accepts a bearer token and a broker URL, and does not
care who issued the token. It performs no token introspection, enforces no issuer, and validates
no claims. The broker is the only component that authenticates the token.

**The owner-account question is deferred to Phase 8.** This ADR deliberately does not decide
whether there is an account system, who runs it, or what a token looks like. The contract this
phase commits to is narrower and testable: *a hand-minted token for a single unit and a token
issued by a future account system must both work against the same device code, unchanged.* The
cert-to-account binding (the second half of IDENT-02) is Phase 8's to close; Phase 7 delivers only
the device-unique-ID half, via the IoT Thing name and certificate ID.

### Identity binding

The CSR subject is `CN=<device-id>`, where `<device-id>` is derived from the CPU serial plus
per-device entropy and persisted to `/var/lib/arlowe/identity/device-id`. **Authorization does not
depend on the CN.** It binds to the IoT Thing name and certificate ID, both of which are created
by the broker and are under our control, so a surprise in AWS's CSR handling cannot become an
authorization bug.

Whether AWS preserves the CSR CN verbatim in the issued certificate is an **open question**. AWS
documents that client certs "hold issuer and subject attributes that you set at the time of
certificate creation", but no authoritative statement confirms verbatim CN preservation and
secondary sources are inconsistent. Plan 07-09 answers it empirically
(`openssl x509 -noout -subject` on a real issued cert) and records the observed behaviour here as
an amendment.

### The security tradeoff

> The device private key is generated in software and stored as a file on an unencrypted ext4
> partition (`/var/lib/arlowe/identity/`) on a removable SD card. The Pi 5 has no TPM and no
> secure element, so there is no hardware protection available. Anyone with physical possession
> of the SD card can extract the device private key and impersonate that one device. The
> mitigations are (a) blast radius is one device, not the fleet, because there is no shared
> secret; (b) the owner can revoke that device's cert, which is honoured by the PKI within one
> polling interval; (c) the cert authorizes only narrowly-scoped cloud reads — it grants no
> access to other owners' data and no access to the device's local conversation cache. This is
> the standard security posture for consumer hardware without a secure element and is accepted
> for v1.

File permissions (`0600`, `arlowe:arlowe`, enforced by the SC3 gate in `build-image.sh` and
`boot-check`) defend against other local processes. They do not defend against someone holding the
card, and this document does not pretend otherwise.

### Escape hatch

AWS IoT supports registering your own CA (BYOC) and just-in-time provisioning (JITP). A migration
to a self-controlled hierarchy is therefore possible **without re-flashing**: issue a second cert
from the new hierarchy over the channel the first cert already authenticates. Lock-in is real but
bounded, and the exit does not require touching deployed hardware.

## Consequences

**Positive:**

- No recurring PKI bill before the first unit ships. AWS IoT Core has no per-CA subscription
  charge, in contrast to AWS Private CA's $400/month.
- No CA to operate: no root key custody, no HA, no backup regime, no CRL distribution point, and
  no scenario where a CA outage becomes a pairing outage.
- No renewal machinery anywhere in the firmware — certs run to 2049.
- Zero secrets in the shipped image. The private key is generated on-device and never leaves it.
- Revocation is one owner-issued API call, enforced server-side, with a stated latency bound of
  one polling interval.
- The device needs neither an AWS SDK nor an MQTT client: one HTTPS POST at pairing, one HTTPS
  mTLS GET per poll.
- Token-agnosticism keeps Phase 8's account design free; no device-side change is needed when a
  real account system appears.

**Negative / known constraints:**

- **The private key is software-protected on unencrypted removable media.** See the tradeoff
  paragraph above. This is accepted, not mitigated away.
- Vendor lock-in on the credentials-provider exchange, which is AWS-specific. Bounded by the
  BYOC/JITP escape hatch, but real.
- A broker must exist for pairing to work. It is a new always-on dependency and a new outage
  surface, and it holds IAM credentials that can mint certificates in the account. Its blast
  radius is larger than any single device's.
- The credentials endpoint host carries an account-specific prefix and is therefore
  account-identifying. It is **not** on the sanitize banlist, so the gate will not catch it. It
  ships via the `identity.credentials_endpoint` config knob written at pairing, defaulting to
  `""` in `config/defaults.yml` — never as a tracked literal. The same applies to
  `identity.provisioning_url` and `identity.role_alias`.
- `credentialDurationSeconds = 900` means the device re-exchanges credentials every poll. That is
  the price of the one-polling-interval revocation bound, and it is deliberate.
- IDENT-02 does not close with this phase. Phase 7 binds the cert to a device; Phase 8 binds it to
  a customer.

### Open questions carried forward (unverified)

1. **Does AWS IoT preserve the CSR subject CN verbatim?** Not authoritatively documented.
   Authorization does not depend on it. Answered empirically in 07-09.
2. **Are provisioning and the credentials provider genuinely unbilled?** Neither appears as a
   billed dimension on the AWS IoT Core pricing page — but **absence from a pricing page is
   weaker evidence than an explicit "no charge" statement, and this is inference rather than a
   claim AWS makes.** The owner runs the staging flow for a month and reads the actual bill before
   this ADR is marked Accepted. Expected outcome: a few cents. This open question is the specific
   reason the status is Proposed.
3. **Does Phase 10 support-mode key issuance run through the same credentials-provider path?**
   Assumed yes, which is what makes SC4's "refuses support-mode key issuance" free. Confirm
   against the Phase 10 design.

Competitor pricing for Azure, HashiCorp and Smallstep is deliberately not quoted as verified in
this document. Only the AWS figures were traceable to consistent first-party-adjacent sources.

## References

- Research: `.planning/phases/07-device-identity-and-pki/07-RESEARCH.md`
- Plan: `.planning/phases/07-device-identity-and-pki/07-01-PLAN.md`
- Verification plan (flips this ADR to Accepted): `.planning/phases/07-device-identity-and-pki/07-09-PLAN.md`
- Config knobs: `config/schema.yml` (`identity`), `config/defaults.yml`
- Requirements: `.planning/REQUIREMENTS.md` IDENT-01, IDENT-02; ROADMAP Phase 7 SC1, SC4
- ADR-0005 (amendment convention for a decision corrected by later evidence)
- https://docs.aws.amazon.com/iot/latest/developerguide/authorizing-direct-aws.html — credentials provider, role alias, `credentialDurationSeconds` 900–43200s
- https://docs.aws.amazon.com/iot/latest/developerguide/provision-wo-cert.html — fleet provisioning by claim vs. by trusted user; claim-key security warning
- https://docs.aws.amazon.com/iot/latest/developerguide/device-certs-your-own.html — BYOC / registering your own CA / JITP
- https://docs.aws.amazon.com/iot-device-defender/latest/devguide/audit-chk-device-cert-approaching-expiration.html — AWS-issued IoT cert expiry 2049-12-31T23:59:59Z
- https://aws.amazon.com/private-ca/pricing/ — $400/month general purpose, $50/month short-lived + $0.058/cert
