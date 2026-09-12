---
phase: 07-device-identity-and-pki
plan: 08a
type: execute
wave: 5
depends_on: ["07-06", "07-07"]
files_modified:
  - runtime/cli/identity
  - runtime/lib/tests/test_identity_cli.py
autonomous: true

must_haves:
  truths:
    - "`arlowe-identity init` gives a device a device-id, a private key and a CSR with no network and no human"
    - "`arlowe-identity provision --ca-broker-url URL --owner-token TOKEN` completes the whole issuance flow with no human in the loop"
    - "The same command works with a hand-minted token and with a token from a future account system, unchanged"
    - "`check-cloud` exits 6 and only 6 when the certificate has been revoked, so revocation is machine-distinguishable from any other failure"
    - "`arlowe-identity reset` clears the identity store so Phase 8 has a factory-reset hook to call"
  artifacts:
    - path: "runtime/cli/identity"
      provides: "arlowe-identity CLI: init, status, provision, check-cloud, reset"
      min_lines: 130
    - path: "runtime/lib/tests/test_identity_cli.py"
      provides: "subcommand tests driving the CLI in-process against a temp identity dir"
      min_lines: 100
  key_links:
    - from: "runtime/cli/identity"
      to: "runtime/lib/arlowe_identity.py"
      via: "update_metadata() merges the provisioned fields into identity.json"
      pattern: "update_metadata"
    - from: "runtime/cli/identity"
      to: "runtime/lib/arlowe_cloud.py"
      via: "request_certificate + fetch_credentials, with exceptions mapped to distinct exit codes"
      pattern: "CertificateRevoked"
---

<objective>
Ship `arlowe-identity` — the CLI that is the Phase 7/8 seam.

Purpose: this is what makes SC2 and SC4 verifiable without Phase 8. `provision` is the stubbed
pairing trigger: Phase 8's pairing daemon will call exactly this command instead of a human.
Per the settled owner decision the CLI is **token-agnostic** — it takes a bearer token and a broker
URL and does not care who issued the token.
Output: `runtime/cli/identity` and its test suite.

Plan 07-08b adds the boot unit and the image wiring. This plan is split from that one because the
combined change lands well over the 600-line atomic-PR cap.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/STATE.md
@.planning/phases/07-device-identity-and-pki/07-RESEARCH.md
@.planning/phases/07-device-identity-and-pki/07-03-SUMMARY.md
@.planning/phases/07-device-identity-and-pki/07-05b-SUMMARY.md
@.planning/phases/07-device-identity-and-pki/07-06-SUMMARY.md
@.planning/phases/07-device-identity-and-pki/07-07-SUMMARY.md
@runtime/cli/boot-check
@scripts/provision/install-arlowe-cli.sh
</context>

<tasks>

<task type="auto">
  <name>Task 1: The arlowe-identity CLI</name>
  <files>runtime/cli/identity</files>
  <action>
Create `runtime/cli/identity` — a Python 3 script, `#!/usr/bin/env python3`, executable (`chmod +x`
and commit the exec bit; pi-gen skips host scripts lacking `+x`, and a non-exec CLI is a class of
bug this repo has already shipped).

**Filename is `identity`, not `arlowe-identity`.** `scripts/provision/install-arlowe-cli.sh` links
`/usr/local/sbin/arlowe-${cli} -> ${TARGET_DIR}/${cli}`. The one file in this repo that carried the
prefix in its own name shipped as a dangling symlink and `arlowe-ab` was "command not found" on the
device (F7 #21). Follow the convention every sibling follows.

Import the lib by inserting `os.environ.get("ARLOWE_LIB", "/opt/arlowe/runtime/lib")` at the front
of `sys.path` before importing `arlowe_identity`, `arlowe_pki`, `arlowe_cloud`, `arlowe_config` —
the same `ARLOWE_LIB` override `runtime/cli/boot-check` already uses.

Subcommands (`argparse`, with `--json` on every read-only command so Phase 8 and the Phase 11
dashboard can consume output without scraping):

**`init`** — offline, idempotent, no network.
`arlowe_identity.ensure_device_id()` then `arlowe_pki.ensure_keypair()` then
`arlowe_pki.ensure_csr(device_id)`. Print the device-id and the resolved hostname. Exit 0 on
success. This is the entire content of first boot: a device that has never been paired still has a
stable identity and a CSR ready to submit.

`init` must **fail loudly** if `/var/lib/arlowe/identity` does not exist — do not create it.
`scripts/provision/install-arlowe-fs.sh:71` creates it at `arlowe:arlowe 0700`, and on a running
device the owner_state partition (p4) is mounted there. An absent directory means the mount did not
happen, and a device that silently writes its identity to the underlying slot-A rootfs would lose it
on the next A/B flip. Exit 5 with a message naming the path. This loud failure is deliberately the
counterpart to 07-08b's unit having no `Condition*` guard.

**`status`** — read-only. Reports device-id, serial source, hostname, whether key / CSR / cert
exist, their modes, and `arlowe_pki.certificate_summary()` when a cert is present. `--json` emits
the machine shape. Exit 0 even when unprovisioned; unpaired is a correct state, not an error.

**`provision --ca-broker-url URL --owner-token TOKEN`** — the stubbed pairing trigger.
1. `init` (idempotent, so `provision` works on a device that has never run the boot unit).
2. `arlowe_cloud.request_certificate(url, token, device_id, csr_pem)`.
3. `arlowe_pki.store_certificate(resp["certificate_pem"])`.
4. Merge `certificate_id`, `certificate_arn`, `thing_name`, `credentials_endpoint`, `role_alias`
   and `provisioned_at` into `/var/lib/arlowe/identity/identity.json` **via
   `arlowe_identity.update_metadata(**fields)`** (plan 07-03).

   **Do not call `write_secret` on `METADATA_PATH` here, and do not "fix" this by removing `O_EXCL`
   from `write_secret`.** `identity.json` already exists at this point — `ensure_device_id` created
   it in step 1 — so a direct `write_secret` raises `FileExistsError`. `update_metadata` is the
   sanctioned read-merge-and-atomically-replace path (`O_EXCL` temp file + explicit chmod +
   `os.replace`); it preserves the 0600 mode guarantee and cannot lose the derivation fields to a
   power cut. `O_EXCL` on `write_secret` is the write-once property protecting `device.key`,
   `device-entropy` and `device-id` and must not be weakened to make a metadata update convenient.
5. Print the certificate id and the thing name; `--json` for the machine shape.

Defaults: `--ca-broker-url` falls back to `config["identity"]["provisioning_url"]` when omitted;
`--owner-token` also accepts `--owner-token-file PATH` and the `ARLOWE_OWNER_TOKEN` environment
variable, because a token on an argv line is visible in `ps`. Prefer the file/env forms in the
runbook.
**Non-interactive by contract.** No prompts, no TTY assumptions, no "press enter". Phase 8's pairing
daemon calls this; a prompt would deadlock it. Exit codes: 0 success; 2 usage; 3
`ProvisioningRejected`; 4 `CloudUnavailable`; 5 `NotProvisioned`/local state error. Distinct codes
because the caller is a program.
**Do not write `/etc/arlowe/config.yml`.** Its absence is the Phase 4 pre-pairing signal and writing
it is Phase 8's job. Provisioning results go to `identity.json` only.

**`check-cloud`** — the SC4 trigger. Calls `arlowe_cloud.fetch_credentials(force_refresh=True)`.
Prints the credential expiry and the key id **prefix only** — never the secret access key or the
session token, not even truncated, in normal output. Exit 0 on success; **exit 6 specifically on
`CertificateRevoked`**, 4 on `CloudUnavailable`, 5 on `NotProvisioned`. The distinct exit code is
what lets plan 07-09's SC4 script assert "refused because revoked" rather than "refused somehow".

Also print, in `--json`, the credential `expiration` timestamp as a top-level field. Plan 07-09
needs it to compute the residual-credential-lifetime half of the revocation bound; without it that
half of `max(poll_interval, remaining_credential_lifetime)` is unmeasurable from the CLI.

**`reset --force`** — removes every file in the identity store (device-id, entropy, key, csr, cert,
identity.json) and leaves the directory itself at 0700. Refuses without `--force`. Phase 8's
factory-reset flow (PAIR-07) calls this; building it now means Phase 8 has something to call instead
of inventing its own deletion logic.

Never print the private key. Never log the owner token.
  </action>
  <verify>
`test -x runtime/cli/identity` and `git ls-files -s runtime/cli/identity` shows mode 100755
`python3 -c "import ast; ast.parse(open('runtime/cli/identity').read())"`
Offline smoke: `D=$(mktemp -d); ARLOWE_IDENTITY_DIR=$D ARLOWE_SERIAL_ROOT=runtime/lib/tests/fixtures/identity/all_three ARLOWE_LIB=runtime/lib ARLOWE_DEFAULTS_PATH=config/defaults.yml ARLOWE_SCHEMA_PATH=config/schema.yml ARLOWE_CONFIG_PATH=/nonexistent ./runtime/cli/identity init` prints a device-id, then `... status --json | python3 -m json.tool` parses, then `ls -l $D` shows every file at `-rw-------`
`./runtime/cli/identity provision` with no URL and an empty `identity.provisioning_url` exits 2 with a usage message
`ARLOWE_IDENTITY_DIR=/nonexistent/nope ... ./runtime/cli/identity init` exits 5 naming the path
  </verify>
  <done>All five subcommands work; `provision` is fully non-interactive with distinct exit codes and merges its results through `update_metadata` without a `FileExistsError`; `check-cloud` exits 6 and only 6 on a revoked certificate and emits `expiration` in `--json`; no secret is ever printed.</done>
</task>

<task type="auto">
  <name>Task 2: CLI tests</name>
  <files>runtime/lib/tests/test_identity_cli.py</files>
  <action>
Tests at `runtime/lib/tests/test_identity_cli.py`, kept in the `runtime/lib` suite so CI's
`python-test` and `python-floor-bookworm` jobs both run them. Import the CLI as a module via
`importlib.util.spec_from_file_location` — the file has no `.py` extension — and drive `main(argv)`
in-process against `ARLOWE_IDENTITY_DIR=<tmp>` with `arlowe_cloud` mocked.

**Resolve the CLI path relative to the test file, not the cwd:**
`Path(__file__).resolve().parents[3] / "runtime/cli/identity"`
(`runtime/lib/tests/test_identity_cli.py` -> `parents[3]` is the repo root). 07-03 carries the same
rule for the banlist fixture and it applies identically here: a cwd-relative path makes the suite
pass or fail depending on where pytest was invoked from, and CI's `python-test` and
`python-floor-bookworm` jobs run from the repo root while a developer may not. Assert the path
exists and **fail** — do not skip — with a message naming it if it does not; a silently-skipped CLI
suite is indistinguishable from a passing one.

Cover:

- `init` twice is idempotent and returns the same device-id.
- `init` against a nonexistent identity directory exits 5 and creates nothing.
- `status --json` on an unprovisioned device exits 0 and reports `cert_present: false`.
- `provision` happy path stores the cert, writes `identity.json` with all six provisioned fields at
  mode 0600, **preserves the `device_id` / `serial_source` / `derived_at` keys `ensure_device_id`
  wrote in step 1**, and does not create `/etc/arlowe/config.yml`. The preservation assertion is the
  regression test for the `O_EXCL` collision: a naive `write_secret` would raise, and a naive
  unlink-then-overwrite would silently drop the derivation fields.
- `provision` maps `ProvisioningRejected` -> exit 3 and `CloudUnavailable` -> exit 4.
- `provision` reads the token from `--owner-token-file` and from `ARLOWE_OWNER_TOKEN`, and the token
  never appears in captured stdout/stderr.
- `check-cloud` exits 6 on `CertificateRevoked` and 4 on `CloudUnavailable`, and the mocked secret
  access key appears nowhere in captured output.
- `check-cloud --json` includes the credential `expiration`.
- `reset` without `--force` exits non-zero and deletes nothing; with `--force` the directory is
  empty and still mode 0700.

Generate any key or certificate the tests need at runtime. Commit no `.key`, `.crt`, `.csr` or
`.pem` fixture: `pi-gen/stage-arlowe/01-runtime/00-run-chroot.sh:95` rsyncs all of `runtime/` into
`/opt/arlowe/runtime/`, so a committed test key lands in the path plan 07-04's build gate scans.
  </action>
  <verify>
`PYTHONPATH=runtime/lib python3 -m pytest runtime/lib/tests/test_identity_cli.py -q` passes
`PYTHONPATH=runtime/lib ARLOWE_SCHEMA_PATH=config/schema.yml ARLOWE_DEFAULTS_PATH=config/defaults.yml ARLOWE_CONFIG_PATH=/nonexistent python3 -m pytest runtime/lib/tests/ -q` passes (full suite)
`git ls-files | grep -E '\.(key|crt|csr|pem|p12|pfx)$'` returns nothing
`bash tests/phase-7/test-identity-store-check.sh` still passes, and `check_identity_store <smoke-dir-root>` (device mode, not `--factory`) exits 0 against the task-1 smoke output
  </verify>
  <done>Every subcommand and every exit code has a test; the `identity.json` merge is covered by an assertion that would fail if anyone weakened `write_secret`'s `O_EXCL`.</done>
</task>

</tasks>

<verification>
- `PYTHONPATH=runtime/lib python3 -m pytest runtime/lib/tests/ -q` passes (full suite).
- `bash scripts/sanitize/check.sh` exits 0.
- The offline smoke sequence in task 1 produces a device-id, a 0600 key, a 0600 CSR whose CN is the device-id, and a hostname that does not contain `arlowe-1`.
- Net diff under 450 lines. **This is an honest number, not the 400 the earlier plans carry** — the declared `min_lines` alone floor it at 230, and a five-subcommand CLI with full exit-code coverage realistically lands at 350-430. `pr-checks.yml` still enforces a Phase-1-era cap of 1500 and will not catch an overrun, so this number is the only guard.
</verification>

<success_criteria>
- SC2 is satisfied end to end on the offline path: a device derives a device-unique ID from serial + per-device entropy, persists it to `/var/lib/arlowe/identity/device-id`, and uses it as the CSR subject.
- **IDENT-02's device half exists, and only that half.** `provision` requests the certificate and binds it to the device-unique ID **via the IoT Thing name**. The **customer-account binding is deferred to Phase 8** and is NOT delivered here: per the settled owner decision the broker compares a bearer token with `hmac.compare_digest` and does not know or care who issued it, which is token verification, not account binding. IDENT-02 must not be ticked as fully met at the end of Phase 7 — plan 07-09 updates its traceability row to span Phase 7 + Phase 8.
- The Phase 7/8 seam is real: Phase 8's pairing daemon calls `arlowe-identity provision` and nothing else.
- Trap 4's code half is closed, and the one mutable file in the identity store is updated through `update_metadata` rather than by weakening `O_EXCL`.
</success_criteria>

<output>
After completion, create `.planning/phases/07-device-identity-and-pki/07-08a-SUMMARY.md`.
Record: every subcommand with its flags and exit codes (07-09 scripts against them; Phase 8 calls
them), the token-input precedence (`--owner-token` / `--owner-token-file` / `ARLOWE_OWNER_TOKEN`),
the fact that `provision` does not write `/etc/arlowe/config.yml`, the `check-cloud --json` shape
including `expiration`, and that `provision` writes `identity.json` through
`arlowe_identity.update_metadata`.
</output>

**Budget note.** `pr-checks.yml`'s `size-check` excludes lockfiles only, not `.planning/`, so this plan's `SUMMARY.md` (~60-90 lines) counts against the net diff. Budget accordingly.
