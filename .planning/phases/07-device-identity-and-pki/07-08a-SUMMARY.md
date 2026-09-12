---
phase: 07-device-identity-and-pki
plan: 08a
subsystem: identity
tags: [cli, argparse, provisioning, exit-codes, phase-8-seam]
requires: ["07-03: store paths + update_metadata", "07-06: keypair/CSR/certificate", "07-07: broker + credentials client"]
provides: ["runtime/cli/identity: arlowe-identity init/status/provision/check-cloud/reset", "the non-interactive pairing trigger Phase 8 calls"]
affects: ["07-08b boot unit + image wiring", "07-09 SC2/SC4 verification scripts", "08 pairing daemon + factory reset (PAIR-07)", "11 dashboard health view"]
tech-stack: {added: [], patterns: ["extensionless CLI file named for the installer's arlowe-${cli} link convention", "argparse parent parser supplying --json to every subcommand", "exception-to-exit-code table as a machine contract"]}
key-files: {created: [runtime/cli/identity, runtime/lib/tests/test_identity_cli.py], modified: []}
key-decisions: ["exit 6 reserved for CertificateRevoked alone", "provision merges identity.json via update_metadata, O_EXCL untouched", "init exits 5 rather than creating an absent identity store", "token precedence flag < file < env, flag documented last", "provision never writes /etc/arlowe/config.yml"]
duration: 66min
completed: 2026-09-11
---

# Phase 7 Plan 08a: arlowe-identity CLI Summary

**Five subcommands make SC2 and SC4 checkable without Phase 8, and `provision` is the entire Phase 7/8 seam: a broker URL and a bearer token in, an issued certificate and six merged metadata fields out, no human anywhere in the call.**

## Subcommands, flags, exit codes

Every subcommand takes `--json`. The exit codes are a contract 07-09 asserts against, not diagnostics.

| Subcommand | Flags | Network | Exit codes |
| --- | --- | --- | --- |
| `init` | `--json` | none | 0 ok; 5 store absent / no serial source |
| `status` | `--json` | none | 0 always — unpaired is a correct state, not an error; 5 only on a corrupt `identity.json` |
| `provision` | `--ca-broker-url URL`, `--owner-token`, `--owner-token-file PATH`, `--json` | broker POST | 0 ok; 2 usage; 3 `ProvisioningRejected`; 4 `CloudUnavailable`; 5 local state |
| `check-cloud` | `--json` | credentials GET | 0 ok; **6 `CertificateRevoked`**; 4 `CloudUnavailable`; 5 `NotProvisioned` |
| `reset` | `--force` (required), `--json` | none | 0 ok; 2 without `--force`; 5 store absent |

**Exit 6 is reserved for `CertificateRevoked` and nothing else.** 07-09's SC4 script needs to assert "refused *because revoked*", and exit 4 — "the call failed somehow" — is a FAIL in its eyes. The `except` ladder in `main()` lists `CertificateRevoked` before any broader clause and there is no bare `except CloudError`, so no future sibling exception can quietly collapse into it.

## provision: the Phase 8 trigger

Signature is `provision --ca-broker-url URL --owner-token TOKEN`. Non-interactive by contract — no prompts, no TTY assumptions — because Phase 8's pairing daemon calls exactly this and a prompt would deadlock it. Token-agnostic by the settled owner decision: it forwards a bearer token and never asks who minted it, so a hand-minted staging token and a token from a future account system work through the same code path unchanged.

Sequence: `init` (idempotent, so `provision` works on a device that never ran the boot unit) → `request_certificate` → `store_certificate` → `update_metadata`.

**The metadata merge is the part worth reading.** `identity.json` already exists when step 4 runs, because step 1's `ensure_device_id` created it. A direct `write_secret` would raise `FileExistsError`, and the tempting "fix" — dropping `O_EXCL` — would trade away the write-once guarantee that keeps `device.key`, `device-entropy` and `device-id` un-clobberable. So the six provisioned fields (`certificate_id`, `certificate_arn`, `thing_name`, `credentials_endpoint`, `role_alias`, `provisioned_at`) go through `arlowe_identity.update_metadata(**fields)`, the sanctioned atomic read-merge-replace. `test_provision_stores_the_certificate_and_merges_metadata` asserts the *derivation* fields survive — a naive unlink-and-rewrite would drop `device_id` / `serial_source` / `derived_at` silently, and that assertion is what catches it.

`provision` does **not** write `/etc/arlowe/config.yml`. Its absence is the Phase 4 CONFIG-03 pre-pairing signal and creating it is Phase 8's job; provisioning results land in `identity.json` only. Asserted against a relocated `arlowe_config.OVERLAY`.

**Token precedence: `--owner-token`, then `--owner-token-file PATH`, then `ARLOWE_OWNER_TOKEN`.** The flag wins when present but is documented last and carries a help string saying so — an argv token is visible to every user on the box through `ps`. Runbooks should use the file or env form. The token appears in no output stream on any path, success or failure.

## check-cloud --json

```json
{"ok": true, "expiration": "2099-01-01T00:00:00Z",
 "access_key_id_prefix": "AKIATEST", "thing_name": "..."}
```

`expiration` is top-level and load-bearing: 07-09 computes the residual-credential-lifetime half of `max(poll_interval, remaining_credential_lifetime)` from it, and without it that half of the revocation bound is unmeasurable from the CLI. The call always passes `force_refresh=True` — a cached hit would prove nothing about the certificate's *current* status. Only an 8-character access-key-id prefix leaves the process; the secret access key and the session token are never printed, not truncated, on either the JSON or the human path, and two tests assert their absence from captured output.

## init and the absent store

`init` refuses to create `/var/lib/arlowe/identity` and exits 5 naming the path. On a running device that directory is the owner_state partition (p4) mountpoint, created at `arlowe:arlowe 0700` by `install-arlowe-fs.sh`; its absence means the mount did not happen, and silently writing identity to the underlying slot-A rootfs would lose it at the next A/B flip. This loud failure is the deliberate counterpart to 07-08b's unit carrying no `Condition*` guard — the guard is here, in code, where it can say why.

The hostname test asserts the substituted segment opens with a letter rather than asserting the absence of the banned literal. Spelling that literal to test for it trips `scripts/sanitize/check.sh`, which matches `rg -iF` without word boundaries — the gate caught exactly that during execution, which is the gate working.

## Verification

163 tests pass (145 pre-existing + 18 new) on Python 3.11 and in a `debian:bookworm` container against **cryptography 38.0.4 / requests 2.28.1**, the real CI surface. `scripts/sanitize/check.sh` clean over 254 files. No key-shaped tracked file; all test key and certificate material is generated at runtime. Offline smoke against `ARLOWE_IDENTITY_DIR` produces a store whose every file is `-rw-------`, a CSR whose CN equals the device-id, and a hostname free of founder literals; `check_identity_store <root>` in device mode exits 0 over that output, and `tests/phase-7/test-identity-store-check.sh` still passes. `git ls-files -s runtime/cli/identity` is `100755`.

The CLI is runnable off-device through `ARLOWE_LIB`, `ARLOWE_IDENTITY_DIR`, `ARLOWE_SERIAL_ROOT`, `ARLOWE_DEFAULTS_PATH`, `ARLOWE_SCHEMA_PATH` and `ARLOWE_CONFIG_PATH`; the config trio is load-bearing because `arlowe_config.load()` otherwise reads `/opt/arlowe/config/*` and raises. `_config()` additionally swallows `FileNotFoundError` and the loader's `SystemExit(78)` so a missing or invalid config can never block identity derivation on first boot.

## IDENT-02 status

**The device half only.** `provision` requests the certificate and binds it to the device-unique ID **via the IoT Thing name**; the **customer-account binding is deferred to Phase 8**. The broker compares a bearer token with `hmac.compare_digest` and does not know who issued it, which is token verification, not account binding. IDENT-02 must not be ticked as fully met at the end of Phase 7 — 07-09 updates its traceability row to span Phase 7 + Phase 8.

## Deviations from plan

**Budget overrun — 657 net lines against a 500 stated cap.** Reported rather than absorbed, per the standing instruction not to buy the number with tests or prose. Composition: 378 executable lines, 279 docstring / comment / blank. The executable portion sits inside the plan's own 350-430 estimate for a five-subcommand CLI with full exit-code coverage; the estimate did not account for this phase's docstring density, and the two files carry 134 docstring lines between them. Nothing was cut: all 18 tests and every WHY comment stand. `pr-checks.yml`'s `size-check` cap is 1500, so CI does not block. If the orchestrator wants this under 500, the honest lever is splitting `reset` and `status` into a follow-up plan, not compressing prose.

Two test-harness corrections landed in the implementation commit rather than the test commit: `importlib.util.spec_from_file_location` returns `None` for an extensionless file and needs an explicit `SourceFileLoader`, and the provision test helper needed a `token=` keyword so the file/env precedence test could withhold the argv token.

## Next-phase readiness

07-08b wires the boot unit and adds `identity` to the `CLIS` array in `install-arlowe-cli.sh`. 07-09 can script against the exit-code table above and against `check-cloud --json`'s `expiration`. Phase 8's pairing daemon calls `arlowe-identity provision` and its factory reset calls `arlowe-identity reset --force`; neither needs anything else from Phase 7.
