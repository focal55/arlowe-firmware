# Phase 7: Device identity and PKI - Research

**Researched:** 2026-09-10
**Domain:** Managed X.509 PKI for low-volume consumer IoT; device-unique identity derivation on Raspberry Pi 5
**Confidence:** MEDIUM-HIGH (stack + mechanism HIGH from AWS docs; pricing MEDIUM; competitor pricing LOW)

## Summary

Phase 7 has one decision that dominates everything else: which managed PKI issues the device cert.
The research answer is **AWS IoT Core's built-in Amazon-root-CA certificate issuance** (NOT AWS Private
CA, NOT a registered custom CA). This is the only option surveyed that costs effectively **$0/month at
low volume**, issues certs to devices with **no public DNS name**, provides a **first-class revocation
switch with a sub-poll-interval effect on HTTPS calls**, and needs **no renewal daemon at all** because
AWS-issued IoT certs expire 2049-12-31. Every alternative either costs $50-$400/month before the first
unit ships (AWS Private CA, HCP Vault), is retired (Google Cloud IoT Core, shut down 2023-08-16), is
structurally wrong for device identity (Let's Encrypt / ACME), or is sales-gated with unknown pricing
(Smallstep Certificate Manager).

The second hard problem is bootstrap trust. The image is built by pi-gen from a repo that is
effectively public, and Phase 6 ships a single image to every unit. **Any secret baked into that image
is on every unit.** AWS's "fleet provisioning by claim" does exactly that (a shared claim cert per
batch) and AWS itself warns about it. The recommendation is to skip claim certs entirely and use
**owner-account-token-mediated issuance**: the device generates its keypair and CSR locally and never
holds any credential until the owner's authenticated pairing session hands it one. Two concrete shapes
of this are analysed below; the recommended one (backend-brokered `CreateCertificateFromCsr`) requires
no MQTT stack on the device and no AWS SDK in the image.

Third: SC2 and SC4 both mention "the pairing flow", which is Phase 8. They are still verifiable in
Phase 7 by splitting the identity work at the right seam. Device-ID derivation, keypair+CSR generation,
the identity-store permission gate, and the cert-authenticated cloud client are all buildable and
end-to-end testable now against a staging AWS account, with a CLI-invoked **stubbed pairing trigger**
that Phase 8 later calls instead of the human. Section "Phase 7 scope boundary" below is prescriptive
about the seam.

**Primary recommendation:** AWS IoT Core with Amazon-root-CA-issued device certs, obtained via
`CreateCertificateFromCsr` brokered by a small owner-authenticated backend at pairing; the device
authenticates all cloud calls via the **AWS IoT Core credentials provider** (cert -> temporary SigV4
credentials over mutual TLS); revocation is `update-certificate --new-status REVOKED`.

---

## The decision: managed PKI service comparison

### RECOMMENDATION: AWS IoT Core (native Amazon CA issuance)

**What is actually being selected.** AWS IoT Core is not only an MQTT broker. It contains a certificate
registry and a signing service that issues X.509 client certs signed by the Amazon Root CA, at no
per-certificate charge. The device never gets a public DNS name; identity is the certificate, and
authorization binds to the certificate ID and the attached IoT Thing.

| Dimension | Finding | Confidence |
|---|---|---|
| Issuance cost | Certificate issuance is not a billed dimension on the AWS IoT Core pricing page. Billed dimensions are connectivity ($0.08/M connection-minutes), messaging ($1/M messages), registry + shadow ops ($1.25/M), rules ($0.15/M). | HIGH (AWS pricing page) |
| Cost at low volume | Effectively $0/month for a few hundred units doing daily OTA polls. The credentials-provider call is not a listed billed dimension either. Free tier: 2.25M connection-minutes, 500k messages, 225k registry ops for 12 months. | MEDIUM - the pricing page does not itemize provisioning or the credentials provider, which means "not separately charged", not "documented as free". **Owner should confirm on a real bill before committing.** |
| Device with no public DNS | Yes, natively. Mutual TLS with a client cert; no DNS name or inbound reachability required. | HIGH |
| Revocation mechanism | `aws iot update-certificate --certificate-id X --new-status REVOKED` (or `INACTIVE`). Certificate status is checked by AWS IoT **at authentication time**, on every new connection and every credentials-provider HTTPS request. No CRL, no OCSP, no device-side revocation list. | HIGH |
| Revocation latency | For the paths this product actually uses (HTTPS credentials-provider calls, not a long-lived MQTT session), the revoked cert is rejected on the **next call**. Existing MQTT sessions are documented as dropping "within a few minutes". Because the device holds no persistent connection, SC4's "within one polling interval" is satisfied structurally. Residual exposure: previously-issued temporary SigV4 credentials remain valid until expiry - see Pitfall 4. | HIGH mechanism / MEDIUM on the "few minutes" MQTT figure |
| Renewal | **None required.** AWS-issued IoT certs expire 2049-12-31T23:59:59Z. Rotation is a deliberate operation (issue new cert, verify, mark old INACTIVE), not a scheduled one. No renewal daemon, no ACME client, no cron. | HIGH |
| Operational burden | Lowest of the options: one provisioning template or one Lambda, one IAM role, one role alias. No CA to operate, no root key to protect, no HSM, no CRL distribution point to host. | HIGH |
| Vendor lock-in | Real but bounded. The cert is Amazon-root-signed and the credentials-provider exchange is AWS-specific. Escape hatch: AWS IoT supports registering your own CA later (BYOC / JITP), so the design can migrate to a self-controlled hierarchy without re-flashing, by issuing a second cert over the existing authenticated channel. | HIGH |

**Why this wins for this specific product:** privacy positioning means the cloud footprint is
deliberately small - OTA manifest fetch and support-mode key issuance, both HTTPS, both low-frequency.
That profile is exactly where AWS IoT Core's usage-based pricing costs nearly nothing, and exactly
where a $400/month CA subscription is indefensible.

**Critical distinction the ADR must state explicitly:** AWS IoT Core's native issuance is free;
**AWS Private CA is $400/month per CA** (general-purpose mode) or **$50/month** (short-lived mode,
max 7-day certs, plus $0.058/cert). A reader who hears "AWS PKI" and reaches for Private CA lands on a
$4,800/year line item before the first unit ships. The ADR must name the specific API
(`CreateCertificateFromCsr` against the Amazon CA) and explicitly rule out Private CA for v1.

### RUNNER-UP: Azure IoT Hub + Device Provisioning Service (DPS)

Architecturally equivalent: X.509 individual enrollment, no public DNS needed, per-operation DPS
billing, a free IoT Hub tier capped at 500 device identities.

**Why it is second, not first:** the free tier is documented as proof-of-concept only and **cannot be
upgraded to a paid tier** - meaning the migration from prototype to production is a rebuild, not a
setting. Pricing detail for DPS operations was not verifiable to the level AWS's was in this research
pass (LOW confidence on Azure figures). Azure has no equivalent of the AWS IoT credentials provider
that as cleanly converts a device cert into short-lived credentials for a CDN/object-store fetch; the
OTA auth story would need more design. Pick this only if there is an independent reason to be on Azure.

### Ruled out, with reasons

| Option | Verdict | Reason |
|---|---|---|
| **Google Cloud IoT Core** | **DEAD - do not plan against it** | Retired **2023-08-16**. MQTT and HTTP bridges shut off; all existing connections terminated. Google directed customers to partners. Confidence: HIGH, multiple independent sources. |
| **Let's Encrypt / ACME** | **STRUCTURALLY WRONG - say so plainly in the ADR** | ACME proves control of a **public DNS name or public IP** in order to issue a **server** certificate. An Arlowe on a home LAN behind NAT has neither, and needs a **client** certificate. There is no ACME challenge type that proves "I am device serial X owned by account Y". This is not a cost or maturity objection; it is a category error. Confidence: HIGH. (ACME as a *protocol* is reusable by private CAs such as step-ca - but that is step-ca, not Let's Encrypt.) |
| **AWS Private CA** | Ruled out on cost for v1 | $400/month general-purpose, $50/month short-lived (7-day max validity, which would force a renewal daemon). Revisit only if a self-controlled root becomes a contractual requirement. Confidence: HIGH on the figures. |
| **Smallstep `step-ca` (self-hosted)** | Ruled out on the no-self-rolled-CA constraint | `step-ca` is a well-reviewed CA implementation, so this is not "self-rolled crypto". But self-hosting means **you operate the CA**: root key custody, HA, backup, CRL/OCSP hosting, and uptime all become the solo founder's problem, and a CA outage becomes a pairing outage. That is the burden the "use a managed PKI service" constraint exists to avoid. Recommend the ADR reject it on *operational custody* grounds and state that reasoning, rather than implying the software is untrustworthy. Confidence: HIGH on reasoning, MEDIUM on framing. |
| **Smallstep Certificate Manager (hosted)** | Ruled out on unknown cost | Verified 2026-09-10: the Smallstep pricing page lists **no prices and no free tier** - "Contact us for a scoping exercise." A single founder cannot plan a bill of materials against a sales call. If the owner wants to keep it alive as an option, the action is "get a quote", not "assume it is cheap". Confidence: HIGH that pricing is sales-gated. |
| **HashiCorp Vault PKI** | Ruled out on cost + vendor churn | Self-hosted Vault has the same custody problem as step-ca plus more operational surface. HCP Vault Dedicated production tiers are reported in the hundreds-to-thousands of dollars per month (LOW confidence - aggregator sites, not HashiCorp's own page). Separately, **HCP Vault Secrets was end-of-sale 2025-06-30 with EOL 2026-07-01**, which is a live data point about product churn in that line. |

---

## Bootstrap trust: how a factory-fresh device gets its first cert

This is the genuinely hard part and it deserves its own ADR section.

### The constraint, stated bluntly

Phase 6 produces **one image, flashed to every unit**, built by pi-gen from this repo. There is no
per-unit manufacturing step, no key injection fixture, no HSM programmer. Therefore:

> Any credential present in the image is present, identically, on every unit, and is extractable by
> anyone who buys one unit and reads the SD card.

The Pi 5 has **no TPM and no secure element** (confirmed by the owner on hardware). There is no
hardware root of trust to anchor to.

### The four options and their tradeoffs

| Approach | How it works | Why it fails / works here |
|---|---|---|
| **1. Shared claim cert baked into the image** (AWS "fleet provisioning by claim") | A provisioning claim cert + key ship in the image. Device connects with it over MQTT, calls `CreateCertificateFromCsr` then `RegisterThing`, gets a permanent cert, disconnects, reconnects with the real cert. | **REJECT.** Extracting the claim key from one SD card lets an attacker mint unlimited certs in your account. AWS's own doc says the claim key "should be secured at all times, including on the device" and recommends a **per-batch** claim cert so a compromise is containable - which presupposes per-batch image builds this project does not do. Also requires the AWS IoT MQTT SDK in the image for a one-time operation. |
| **2. Per-device secret injected at manufacture** | Each unit gets a unique key/cert written during production. | **NOT AVAILABLE.** There is no manufacturing step. Revisit only if contract manufacturing appears. Keep the design compatible so this can be added later. |
| **3. Owner-account-token-mediated issuance, backend-brokered** | Device generates P-256 keypair + CSR locally at first boot. Pairing hands the device an owner-authenticated session. The device (or the pairing companion) submits the CSR to **your** backend along with the owner's account token. Backend authenticates the owner, calls `iot:CreateCertificateFromCsr` + `AttachThingPrincipal` + `AttachPolicy` with its own IAM creds, returns the signed cert. | **RECOMMENDED.** Zero secrets in the image. Private key is generated on-device and never leaves it. The trust anchor is the owner's account - which Phase 8 must establish anyway for PAIR-03. The device needs no AWS SDK and no MQTT: one HTTPS POST. The backend is where the cert-to-account binding (IDENT-02) is enforced, which is also where it belongs. |
| **4. AWS "fleet provisioning by trusted user"** | The companion app (authenticated as the owner) calls `CreateProvisioningClaim`, receives a **temporary claim cert valid 5 minutes**, hands it to the device over the pairing channel; the device uses it over MQTT to call `CreateCertificateFromCsr` + `RegisterThing` within that 5-minute window, then reconnects with the permanent cert. | **VIABLE ALTERNATIVE**, same trust shape as (3) - trust is mediated by the owner's authenticated session, nothing is baked in. Downsides for this project: requires the AWS IoT MQTT SDK (`awsiotsdk`/`awscrt`) in the image purely for provisioning; a hard 5-minute wall-clock window that a slow first Wi-Fi association can blow; and it ties the pairing UX to AWS API shapes. Choose this only if you want AWS to own the registry-resource creation via a provisioning template. |

### Recommended approach and its security tradeoff, stated plainly

**Use option 3 (backend-brokered, owner-token-authenticated `CreateCertificateFromCsr`).** Structure
the device side so that option 4 remains a drop-in swap: the device's contract is "produce a CSR, hand
it to a trigger, receive and persist a cert".

**The tradeoff you are accepting, in plain language - this belongs verbatim in the ADR:**

> The device private key is generated in software and stored as a file on an unencrypted ext4
> partition (`/var/lib/arlowe/identity/`) on a removable SD card. The Pi 5 has no TPM and no secure
> element, so there is no hardware protection available. **Anyone with physical possession of the SD
> card can extract the device private key and impersonate that one device.** The mitigations are
> (a) blast radius is one device, not the fleet, because there is no shared secret; (b) the owner can
> revoke that device's cert from the dashboard, which is honoured by the PKI within one polling
> interval; (c) the cert authorizes only narrowly-scoped cloud reads (OTA manifest fetch, support-mode
> key issuance) - it grants no access to other owners' data and no access to the device's local
> conversation cache. This is the standard security posture for consumer hardware without a secure
> element and is accepted for v1.

Do not hedge this in the ADR. Writing it down clearly is what makes it a decision rather than an
oversight.

---

## Device-unique ID (SC2 / IDENT-06)

### Pi 5 serial: what is actually true

| Source | What it is | Verdict |
|---|---|---|
| `/proc/cpuinfo` `Serial:` field | On **Pi 4 and earlier**: a 32-bit value generated by the hardware RNG at first boot and burned into OTP. **Collisions are documented and confirmed in the wild** - a Raspberry Pi forum thread reports two Pi 4B boards with identical serial `100000006947c8c2`, and a Raspberry Pi engineer acknowledged duplicates as "extremely rare" but real. | Usable on Pi 5, **not** sufficient alone as a uniqueness guarantee for earlier silicon. |
| Pi 5 serial | **64-bit**, generated by the hardware RNG at first boot, stored in OTP. A Raspberry Pi engineer stated directly: **"The Pi 5 does have unique serial numbers."** | HIGH confidence this is stable and unique on Pi 5. |
| `/proc/device-tree/chosen/rpi-duid` | Pi 5 only. A manufacturing-allocated device unique ID that **matches the 2D data-matrix laser-etched on the PCB**. | This is the better identifier: it is factory-allocated rather than RNG-derived, and it is physically readable off the board - which matters for RMA, support, and "the customer reads the number off the sticker". |
| `/sys/firmware/devicetree/base/serial-number` | Device-tree view of the same serial as `/proc/cpuinfo`. NUL-terminated; must strip the trailing NUL. | Equivalent to `/proc/cpuinfo` Serial; prefer it as the primary read since it is the stable sysfs path. |
| `vcgencmd otp_dump` (rows 28/31) | Third read path. | Requires `vcgencmd` and `/dev/vcio` access; avoid under the sandboxed unit. Not needed. |

**Recommended derivation (prescriptive):**

1. Read `/proc/device-tree/chosen/rpi-duid` if present; else fall back to
   `/sys/firmware/devicetree/base/serial-number`; else `/proc/cpuinfo` `Serial:`. Record which source
   was used in the identity metadata so a field diagnosis is possible.
2. Generate **32 bytes from `os.urandom()` exactly once**, at first identity initialization, and
   persist to `/var/lib/arlowe/identity/device-entropy` mode `0600`. This is "per-device entropy":
   it is not a TPM, not hardware-backed, and its purpose is (a) closing the Pi-4-era collision hole,
   (b) ensuring two units with the same serial cannot collide, (c) making the ID non-guessable from
   the serial alone so the ID is not an enumeration vector.
3. `device-id = hex(sha256(source_tag || ":" || serial || ":" || entropy))[:32]` - a 32-hex-char
   opaque token. Persist to `/var/lib/arlowe/identity/device-id` mode `0600`.
4. The derivation is **idempotent and stable**: if `device-id` exists, return it; never re-derive.
   The entropy file being on the shared `/var/lib/arlowe` partition means the ID survives an A/B slot
   flip and an app OTA, and is destroyed by factory reset (PAIR-07), which is the correct lifecycle.
5. Use `CN=<device-id>` as the CSR subject. **Do not depend on AWS preserving that CN in the issued
   cert** - see Open Question 1. AWS IoT authorization keys off the certificate ID and the attached
   Thing name, not the subject. Bind identity by naming the IoT Thing `<device-id>` and attaching the
   cert to it; treat the CSR CN as human-facing provenance.

**Stability caveat to verify on hardware:** the Pi 5 serial is documented as RNG-generated *at first
boot* and burned to OTP. Once burned it is immutable, but this research did not verify behaviour on a
board whose OTP was somehow unprogrammed. Reading it on the dev unit and on the first production unit
and confirming they differ and are each stable across reflash is a cheap, worthwhile verification task.

---

## Phase 7 scope boundary: buildable now vs blocked on Phase 8

SC2 and SC4 both name "the pairing flow". Phase 8 does not exist. The seam that makes Phase 7
independently verifiable:

> Phase 7 owns **everything except the human**. The pairing daemon's only contribution is calling a
> trigger that Phase 7 already built and tested.

### BUILDABLE NOW in Phase 7

| Deliverable | Verifies | Notes |
|---|---|---|
| **ADR-0007**: PKI service selection + cert lifecycle | SC1, IDENT-01 | Pure document. Must name AWS IoT Core native issuance, explicitly rule out AWS Private CA on cost, state the no-secure-element tradeoff verbatim, and record issuance / renewal(=none) / revocation. |
| **`arlowe_identity.py`** in `runtime/lib/` - device-ID derivation + entropy generation + idempotent persistence | SC2 (derivation half), IDENT-06 | Fully unit-testable offline with fixture paths, mirroring `arlowe_config.py`'s `ARLOWE_*_PATH` env-override pattern. |
| **Keypair + CSR generation** (P-256, `cryptography` lib) writing `device.key` 0600 and `device.csr` | SC2 (CSR half), IDENT-03 | Offline-testable. Assert key file mode is exactly `0600` and the key never leaves `/var/lib/arlowe/identity/`. |
| **Identity-store hygiene check** - an assertion script wired into `scripts/build-image.sh` and/or `boot-check` | **SC3 in full** | This SC is 100% achievable in Phase 7 and needs no PKI at all. See "Integration points" below. |
| **`arlowe_cloud.py`** - cert-authenticated cloud client: loads cert+key, calls the IoT credentials-provider endpoint over mutual TLS, caches SigV4 creds until expiry, raises a distinguishable `CertificateRevoked` on 403 | IDENT-04, and the mechanism SC4 depends on | Testable end-to-end against a staging AWS account **today**, with a manually-provisioned cert. No pairing needed. |
| **`arlowe-identity` CLI with a `provision` subcommand** = the **stubbed pairing trigger** | The Phase 7/8 seam | `arlowe-identity provision --ca-broker-url URL --owner-token TOKEN` does the whole flow non-interactively. Phase 8's pairing daemon calls exactly this. This is what makes SC2 and SC4 verifiable without Phase 8. |
| **Staging PKI setup as code** - a `scripts/pki/` shell or Terraform artifact that creates the IoT policy, role alias, IAM role, and the CSR-broker | SC4 prerequisite | Lives in the repo, never in the image. Keep AWS account IDs out of tracked files. |
| **SC4 end-to-end revocation test** against staging | **SC4 in full** | Provision a cert via the stub; confirm an OTA-shaped fetch succeeds; run `update-certificate --new-status REVOKED`; confirm the next poll fails with `CertificateRevoked` and the device refuses the cloud call. Fully achievable in Phase 7. |
| **Config schema `identity` block** | IDENT-01 plumbing | See the schema warning in Pitfall 1 - this is the highest-risk edit in the phase. |

### GENUINELY BLOCKED until Phase 8

- Owner account creation, the owner-token capture UX, and the captive-portal/BLE channel (PAIR-02/03).
- Whisplay status display during issuance (PAIR-05).
- Whether the **companion** or the **device** makes the broker call - Phase 8's channel decision drives
  this. Phase 7 must build the device-side path (device calls the broker directly over HTTPS once
  Wi-Fi is up) because it is the simpler of the two and is a strict subset of the other.
- Factory reset clearing `/var/lib/arlowe/identity/` (PAIR-07) - Phase 7 should nonetheless expose
  `arlowe-identity reset` so Phase 8 has something to call.

**Explicit guidance for the planner:** do not let a plan depend on the pairing daemon existing. If a
task's verification step says "pair the device", it is mis-scoped - rewrite it to invoke
`arlowe-identity provision` with a token minted by hand against staging.

---

## Concrete integration points in this repo

### Existing config knobs relevant to Phase 7

Read from `config/schema.yml` on 2026-09-10. **There is no provisioning-URL knob and no identity
block.** Phase 7 must add them. What exists today:

| Knob | Current state | Relevance |
|---|---|---|
| `device.hostname` | default `"arlowe-${device_serial}"`, documented as "resolved at pairing (Phase 7/8) by substituting the device serial number" | Phase 7 supplies the substitution value. **See Pitfall 3 - this interacts badly with the sanitize gate.** |
| `ota.channel_url` | default `""`, "Empty until set at pairing (Phase 8/9)" | Phase 9 consumes; Phase 7's cloud client is what authenticates the fetch. |
| `support_mode.*` | `enabled: false`, `window_hours: 24` | Phase 10 consumes; Phase 7's cert is the credential for key issuance. |

**Proposed new `identity` block** (planner should size this as its own small PR):

```yaml
identity:
  provisioning_url: ""        # owner-authenticated CSR broker endpoint; empty until paired
  credentials_endpoint: ""    # <prefix>.credentials.iot.<region>.amazonaws.com
  role_alias: ""              # IoT role alias for the credentials provider
  poll_interval_seconds: 3600 # bounds SC4's "within one polling interval"
```

### File and path map

| Path | Role in Phase 7 |
|---|---|
| `/var/lib/arlowe/identity/` | Exists on a freshly flashed image, `arlowe:arlowe` `0700`. Created by `scripts/provision/install-arlowe-fs.sh` line ~78, whose comment already says "reserved for Phase 7 PKI". **No change needed to that script** unless you want the entropy/device-id files pre-seeded (you do not - they must be first-boot generated). |
| `/var/lib/arlowe/identity/device-id` | SC2 target. `0600`. |
| `/var/lib/arlowe/identity/device-entropy` | New. `0600`. Generated once. |
| `/var/lib/arlowe/identity/device.key` | New. `0600`. **Never leaves the device.** |
| `/var/lib/arlowe/identity/device.crt` | New. `0600` per IDENT-03 (0644 would also be safe for a cert, but SC3 says 0600 - honour the SC literally so the automated check is a simple equality test). |
| `runtime/lib/arlowe_config.py` | The config loader. Import path is **flat**: installed at `/opt/arlowe/runtime/lib/arlowe_config.py`, imported as `from arlowe_config import load`. `load()` returns the merged+validated dict, raises `SystemExit(78)` on schema violation. Env overrides: `ARLOWE_DEFAULTS_PATH`, `ARLOWE_CONFIG_PATH`, `ARLOWE_SCHEMA_PATH`. **New identity modules go in the same flat directory and follow the same env-override-for-testability pattern.** |
| `runtime/lib/requirements.txt` | Currently `jsonschema==4.23.0`, `PyYAML==6.0.3`. Phase 7 adds `cryptography` (keypair + CSR) and `requests` (already pinned at `2.32.5` in voice/tts - **keep the pin in sync**). |
| `runtime/cli/boot-check` | 97-line bash, `check_service` / `check_port` helpers, `PASS`/`FAIL` counters. Phase 7 extends with a `check_identity` block: device-id present, key mode 0600, cert present and not expired, no key material under `/opt/arlowe`. Phase 5 precedent: write structured JSON to `/var/lib/arlowe/state/` for the Phase 11 dashboard (`audio-selfcheck.json` is the pattern). |
| `scripts/build-image.sh` step 5 | Loop-mounts slot A read-only and runs `scripts/sanitize/check.sh --scan-dir`. **This is the natural home for SC3's automated check** - add a sibling assertion over the same mountpoint that fails the build if any `*.key`/`*.pem`/`*.crt`/`*.csr` exists under `/opt/arlowe`. Note the existing `mount -o ro` - keep it read-only (see the `.bmap` desync hazard recorded in project memory). |
| `units/` | Six units, all `User=arlowe`, `ProtectSystem=strict`, `NoNewPrivileges`, explicit `ReadWritePaths`. A new `arlowe-identity.service` must follow suit with `ReadWritePaths=/var/lib/arlowe/identity` and `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`. Note `arlowe-face.service` uses `ExecStartPre=... -m arlowe_config_validate` as a fail-fast idiom - reuse it. |
| `units/install-units.sh` | Idempotent installer; `cmp -s` before copy, conditional `daemon-reload`. New units just drop into `units/`. |
| `pi-gen/stage-arlowe/03-firstboot/` | Installs `arlowe-firstboot.service` (`ConditionPathExists=!/var/lib/arlowe/.firstboot-done`, `ExecStart=/opt/arlowe/runtime/cli/boot-check --first-boot`). **This is where device-ID derivation should be triggered on first boot** - either an `ExecStartPre` on that unit or a new oneshot ordered `Before=` it. Deriving the ID at first boot rather than at pairing means SC2's "a device boots, derives... and persists it" is true even for an unpaired unit. |
| `docs/architecture/` | ADRs 0001-0006. House style: `# ADR-000N: Title`, an HTML `<!-- status: accepted -->` comment, then bold `**Status:**` / `**Date:**` / `**Phase:**` / `**Closes:**` lines, then `## Context` / `## Decision` / `## Consequences` (split into `**Positive:**` and `**Negative / known constraints:**`) / `## References`. ADR-0005 also demonstrates the amendment convention. **Phase 7's ADR is 0007.** |
| `.sanitize-allowlist` | `.planning/**` and `docs/architecture/**` are allowlisted, so the ADR and this research file may quote banned literals freely. Anything under `runtime/`, `scripts/`, `units/`, `config/` may not. |

---

## Don't hand-roll

| Problem | Do NOT build | Use instead | Why |
|---|---|---|---|
| Keypair + CSR generation | OpenSSL subprocess string-munging | `cryptography` (`ec.generate_private_key(ec.SECP256R1())`, `x509.CertificateSigningRequestBuilder`) | Already the ecosystem standard; no shell-injection surface; deterministic error handling; the pinned wheel has an arm64 build. |
| Certificate authority | Any CA, including step-ca | AWS IoT native issuance | Explicit REQUIREMENTS.md out-of-scope entry: "Custom CA / self-rolled crypto - Use a managed PKI service." |
| Revocation distribution | CRL fetch / OCSP stapling / a device-side deny list | AWS IoT certificate status, checked server-side at every auth | Revocation checking is the single most bug-prone part of PKI. AWS checks it for you on every credentials-provider call; the device needs zero revocation logic. |
| Signing AWS requests | Hand-rolled SigV4 | `botocore`/`boto3` session with the credentials-provider output, or a signed pre-authorized URL from your broker | SigV4 canonicalization is notoriously easy to get subtly wrong. |
| Cert -> credential exchange | Storing long-lived AWS keys on the device | AWS IoT credentials provider: `curl --cert device.crt --key device.key --cacert AmazonRootCA1.pem https://<ep>/role-aliases/<alias>/credentials` returning `{accessKeyId, secretAccessKey, sessionToken, expiration}` | Documented, first-party, and the whole reason this design has a clean revocation story. `credentialDurationSeconds` is settable 900s-43200s on the role alias. |
| Config loading in new modules | A second YAML parser | `from arlowe_config import load` | One loader, one schema, one failure mode (exit 78). |

---

## Common pitfalls

### Pitfall 1: Adding `identity` to the schema's top-level `required` list breaks the dashboard

`config/schema.yml` has `additionalProperties: false` and an 8-entry top-level `required` list. The
dashboard hard-codes that list in **two** places that will silently drift:

- `runtime/dashboard/app/audio/save-body.ts`: `const REQUIRED_KEYS = ['device','audio','model','persona','ports','logs','support_mode','ota']` plus a `CONFIG_DEFAULTS` object that must "stay in sync with config/defaults.yml".
- `runtime/dashboard/tests/unit/config-validate.test.ts`: at least three hand-built full-config fixtures.

`POST /api/config` AJV-validates the **raw body** and returns 422 on a partial body. Adding a 9th
required key without updating `save-body.ts` means every dashboard audio save 422s.

**How to avoid:** either (a) make `identity` optional in the schema and rely on `defaults.yml` +
deep-merge to always supply it - simplest, no dashboard change; or (b) if it must be required, the
schema edit and the `save-body.ts` + test-fixture edits must be **the same PR**, or the repo is broken
between merges. Recommend (a).

### Pitfall 2: No pytest job in CI - "tests pass" means "passed on my laptop"

`.github/workflows/ci.yml` gates only on `package.json` existing and runs pnpm lint/typecheck/test.
There is **no Python test job**. Every Python test written in Phase 7 (`runtime/lib/tests/`) runs only
when a human runs it. Given that Phase 7 is the security-critical phase, the planner should consider
adding a pytest job as an explicit early task rather than assuming coverage exists. Related known
failure mode in this repo: empty directories without a `.keep` file silently vanish in a clean
checkout and break fixture-based tests.

### Pitfall 3: The sanitize gate will flag a serial-derived hostname starting with "1"

`scripts/sanitize/check.sh` runs `rg -iFnH` against `scripts/sanitize/banlist.txt`, which contains the
literal `arlowe-1`. `-F` is fixed-string with **no word boundaries** and `-i` is case-insensitive. So a
resolved hostname such as `arlowe-1a2b3c4d...` **contains** `arlowe-1` and will trip the gate.

This matters because `--scan-dir` mode runs over the mounted slot-A rootfs during `build-image.sh` and
**ignores `.sanitize-allowlist` entirely**. It will not fire on a factory image (no
`/etc/arlowe/config.yml`, no `device-id`), but it **will** fire on any dev image captured after a test
pairing, or on any test fixture committed under `runtime/` or `tests/`.

**How to avoid:** (a) do not derive the hostname from a raw hex ID that can start with `1` - prefix or
encode it so `arlowe-1` cannot appear (e.g. base32 with a non-digit leading character, or always
prefix the ID segment with a letter); and (b) never commit a test fixture containing a rendered
hostname of that shape. Flag this to the owner - it is a five-minute design choice now and an
unexplained red CI later.

### Pitfall 4: Revoking the cert does not instantly kill already-issued SigV4 credentials

The credentials provider returns STS credentials valid for `credentialDurationSeconds` (default 1h,
max 12h). Marking the cert REVOKED prevents **new** exchanges but does not retroactively invalidate an
outstanding token. SC4 says "within one polling interval" - so the honest guarantee is:

> revocation takes effect within `max(poll_interval, remaining_credential_lifetime)`.

**How to avoid:** set `credentialDurationSeconds` to a value at or below the OTA poll interval (900s
minimum is allowed), and/or have the device re-exchange on every poll rather than caching to expiry.
State the resulting bound explicitly in the ADR so SC4's verification has a number to test against.

### Pitfall 5: Silently assuming AWS preserves the CSR subject

SC2 says the device-id is "the CSR subject". Generate it that way. But **authorization must not depend
on it** - see Open Question 1. Bind by Thing name + certificate ID, which are under your control.

### Pitfall 6: Committing an AWS account ID or endpoint prefix into the image

The credentials endpoint is `<account-specific-prefix>.credentials.iot.<region>.amazonaws.com`. That
prefix is account-identifying. It is not on the banlist, so the sanitize gate will not catch it.
Ship it via the `identity.credentials_endpoint` config knob written at pairing, with `""` in
`defaults.yml` - never as a literal in tracked source. Same for the CSR-broker URL.

### Pitfall 7: Sandboxed units and file creation modes

`ProtectSystem=strict` + `ReadWritePaths=/var/lib/arlowe/identity` is necessary but not sufficient for
SC3. Python's default file mode is `0666 & ~umask`; systemd's default `UMask` is `0022`, yielding
`0644`, which **fails the SC3 0600 check**. Create key material with
`os.open(path, os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o600)` or set `UMask=0077` in the unit. Do both.

### Pitfall 8: Plan scripts drifting from merged code

Recorded pattern in this project: late-wave plans written before their dependencies merged do not match
the real repo. Phase 7 plans must be written against the code as it exists on `main` at plan time -
particularly `boot-check` (97 lines, bash, not Python) and `build-image.sh` step 5 (whose loop-mount
must stay `-o ro`).

---

## Code examples (verified from official sources)

### Exchanging the device cert for temporary AWS credentials

Source: https://docs.aws.amazon.com/iot/latest/developerguide/authorizing-direct-aws.html

```bash
# One-time, on the build/ops host: discover the account-specific endpoint.
aws iot describe-endpoint --endpoint-type iot:CredentialProvider
# -> {"endpointAddress": "<prefix>.credentials.iot.<region>.amazonaws.com"}

# On the device, per OTA poll:
curl --cert /var/lib/arlowe/identity/device.crt \
     --key  /var/lib/arlowe/identity/device.key \
     --cacert /opt/arlowe/config/AmazonRootCA1.pem \
     -H "x-amzn-iot-thingname: ${DEVICE_ID}" \
     "https://${CREDENTIALS_ENDPOINT}/role-aliases/${ROLE_ALIAS}/credentials"
# -> {"credentials":{"accessKeyId":"...","secretAccessKey":"...","sessionToken":"...","expiration":"..."}}
```

Notes carried from the doc: SNI is mandatory and `host_name` must be the credentials endpoint exactly,
or the connection fails. `x-amzn-iot-thingname` must match the Thing the cert is attached to or you get
a 403 - which is convenient, because it means a mismatch is loud.

### IoT policy on the device cert (grants only the credential exchange)

Source: same page.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "iot:AssumeRoleWithCertificate",
    "Resource": "arn:aws:iot:<region>:<account>:rolealias/<your-role-alias>"
  }]
}
```

### Revocation (the SC4 lever)

Source: https://docs.aws.amazon.com/iot/latest/developerguide/activate-or-deactivate-device-cert.html

```bash
aws iot update-certificate --certificate-id "${CERT_ID}" --new-status REVOKED
aws iot describe-certificate --certificate-id "${CERT_ID}"   # confirm status
```

### Device-side key + CSR (pattern, `cryptography`)

```python
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import hashes, serialization
from cryptography import x509
from cryptography.x509.oid import NameOID

key = ec.generate_private_key(ec.SECP256R1())
csr = (x509.CertificateSigningRequestBuilder()
       .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, device_id)]))
       .sign(key, hashes.SHA256()))

fd = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "wb") as f:
    f.write(key.private_bytes(serialization.Encoding.PEM,
                              serialization.PrivateFormat.PKCS8,
                              serialization.NoEncryption()))
```

P-256 is within AWS's accepted set (RSA >= 2048, or NIST P-256/P-384/P-521).

---

## State of the art

| Old approach | Current approach | When changed | Impact here |
|---|---|---|---|
| Google Cloud IoT Core as a mainstream device-PKI option | Retired; AWS IoT Core / Azure IoT Hub / specialist vendors | 2023-08-16 | Do not plan against it. Any tutorial referencing it predates the shutdown. |
| Shared claim certificate baked into firmware | Owner/trusted-user-mediated issuance with short-lived or brokered claims | Ongoing industry shift | AWS's own "provisioning by trusted user" exists specifically to avoid baked-in shared secrets. |
| Long-lived AWS access keys on devices | Cert -> credentials provider -> short-lived SigV4 | Established AWS guidance | Removes the "secret in the image" problem for the OTA fetch path too, not just for identity. |
| CRL / OCSP device-side revocation checking | Server-side cert-status check at auth time | Managed-PKI norm | Device carries zero revocation code. |
| HCP Vault Secrets as a lightweight managed option | Discontinued (EOS 2025-06-30, EOL 2026-07-01) | 2025-2026 | Argues against betting a shipping product's identity layer on a young managed product. |

---

## Open questions

1. **Does AWS IoT preserve the CSR subject CN in the issued certificate?**
   - What we know: `CreateCertificateFromCsr` takes a CSR and issues an Amazon-CA-signed cert; AWS
     docs state client certs "hold issuer and subject attributes that you set at the time of
     certificate creation".
   - What's unclear: I could not find authoritative documentation confirming that the CN from the CSR
     appears verbatim in the issued cert, and secondary sources are inconsistent.
   - Recommendation: **do not block on this.** Generate the CSR with `CN=<device-id>`, but bind
     authorization to the IoT Thing name and certificate ID. Verify empirically in the first staging
     task (`openssl x509 -noout -subject` on the issued cert) and record the observed behaviour in the
     ADR. Ten-minute experiment, removes all ambiguity.

2. **Are fleet provisioning and the credentials provider genuinely unbilled?**
   - What we know: neither appears as a billed dimension on the AWS IoT Core pricing page.
   - What's unclear: absence from a pricing page is weaker evidence than an explicit "no charge"
     statement. **This is vendor-marketing-adjacent inference, not verified fact.**
   - Recommendation: owner runs the staging flow for a month and reads the actual bill before the ADR
     is marked Accepted. Expected outcome: a few cents.

3. **Do you want a backend at all in v1?**
   - The recommended bootstrap requires a small owner-authenticated HTTPS broker (Lambda + API Gateway
     or equivalent) and an owner-account system. Phase 8's PAIR-03 already requires "owner account
     credentials/token", which implies one exists - but that is an assumption, not a recorded decision.
   - **Needs owner confirmation.** If no account system is planned for v1, the bootstrap options
     collapse to fleet-provisioning-by-claim (rejected above) or a manual per-unit step, and Phase 7's
     design changes materially. Resolve this before planning tasks.

4. **Does support-mode key issuance (Phase 10) run through the same credentials-provider path?**
   - Assumed yes (device presents cert, gets short-lived creds, calls your support endpoint), which is
     what makes SC4's "refuses ... support-mode key issuance" free. Worth confirming with the Phase 10
     shape so Phase 7's client API is general enough.

5. **Pi 5 serial stability across reflash** - documented as OTP-burned and therefore immutable, but not
   verified on this project's hardware. Cheap to confirm; worth a verification step.

---

## Sources

### Primary (HIGH confidence)
- https://docs.aws.amazon.com/iot/latest/developerguide/provision-wo-cert.html - fleet provisioning by claim vs by trusted user; 5-minute temporary claim cert; 1-hour `certificateOwnershipToken`; claim-key security warning
- https://docs.aws.amazon.com/iot/latest/developerguide/authorizing-direct-aws.html - credentials provider workflow, role alias, `credentialDurationSeconds` 900-43200s, SNI requirement, curl example
- https://docs.aws.amazon.com/iot/latest/developerguide/activate-or-deactivate-device-cert.html - ACTIVE / INACTIVE / REVOKED; status checked at authentication
- https://docs.aws.amazon.com/iot/latest/developerguide/device-certs-your-own.html - BYOC / registering your own CA / JITP
- https://aws.amazon.com/iot-core/pricing/ - connectivity / messaging / registry / rules rates; free tier; provisioning not itemized
- https://smallstep.com/pricing/ - verified 2026-09-10: no published prices, "Contact us" only
- Repo inspection: `config/schema.yml`, `config/defaults.yml`, `runtime/lib/arlowe_config.py`, `runtime/cli/boot-check`, `scripts/provision/install-arlowe-fs.sh`, `scripts/sanitize/check.sh`, `scripts/build-image.sh`, `units/arlowe-face.service`, `pi-gen/stage-arlowe/03-firstboot/`, `.sanitize-allowlist`, `.github/workflows/ci.yml`, `runtime/dashboard/app/audio/save-body.ts`

### Secondary (MEDIUM confidence)
- https://forums.raspberrypi.com/viewtopic.php?t=379296 - Pi 4B duplicate serial `100000006947c8c2`; Raspberry Pi engineer: "The Pi 5 does have unique serial numbers"; `rpi-duid` matching the PCB data-matrix. Official-adjacent (vendor forum, engineer participation) but not formal documentation.
- https://aws.amazon.com/private-ca/pricing/ (via search summary) - $400/mo general purpose, $50/mo short-lived + $0.058/cert. Figures consistent across multiple sources; not fetched directly.
- https://docs.aws.amazon.com/iot-device-defender/latest/devguide/audit-chk-device-cert-approaching-expiration.html (via search) - AWS-issued IoT cert expiry 2049-12-31T23:59:59Z; rotation procedure
- Google Cloud IoT Core retirement 2023-08-16 - multiple independent sources agree; not fetched from a Google-owned URL in this pass

### Tertiary (LOW confidence - flagged, do not treat as fact)
- HCP Vault Dedicated pricing figures ($350/mo minimum vs $22/mo dev vs $1,150-6,900/mo production) - third-party aggregator sites only, mutually inconsistent. Only the *direction* (expensive relative to $0) is used in the recommendation.
- HCP Vault Secrets EOS 2025-06-30 / EOL 2026-07-01 - aggregator-sourced.
- Azure DPS per-operation pricing and free-tier limits - not verified against Microsoft's own pricing page.
- "$0.0035 per device per month" AWS connectivity figure - a third-party derivation, not an AWS statement.

---

## Metadata

**Confidence breakdown:**
- PKI service selection (AWS IoT Core): **HIGH** - mechanism, revocation, renewal, and no-DNS-required all verified against first-party AWS documentation. The one soft spot is whether provisioning is truly unbilled (see Open Question 2).
- Bootstrap-trust approach: **HIGH** on the reasoning (the "one image = shared secret on every unit" argument is a fact about this project's build, not a claim about a vendor); **MEDIUM** on the specific broker shape, which depends on Open Question 3.
- Device-ID derivation: **MEDIUM-HIGH** - Pi 5 uniqueness is confirmed by a Raspberry Pi engineer on the official forum but not in formal documentation; OTP stability not verified on this project's hardware.
- Repo integration points: **HIGH** - read directly from the working tree on 2026-09-10.
- Pitfalls: **HIGH** for 1, 3, 5, 6, 7 (all derived from reading this repo's actual code); **HIGH** for 4 (derived from documented credential lifetimes); **HIGH** for 2 and 8 (observed repo/project facts).
- Competitor pricing: **LOW** for Azure, Vault, Smallstep. Do not quote these figures in the ADR as verified; cite them as "not verifiable without a sales conversation / a real bill".

**Research date:** 2026-09-10
**Valid until:** ~2026-12-10 (90 days). AWS IoT Core's provisioning and credentials-provider APIs are stable and long-lived; pricing pages change more often. Re-verify pricing before the ADR is marked Accepted.
