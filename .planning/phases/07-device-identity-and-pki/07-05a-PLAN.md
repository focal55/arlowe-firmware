---
phase: 07-device-identity-and-pki
plan: 05a
type: execute
wave: 2
depends_on: ["07-01"]
files_modified:
  - scripts/pki/README.md
  - scripts/pki/setup-staging.sh
  - scripts/pki/teardown-staging.sh
  - scripts/pki/revoke.sh
  - .gitignore
  - .github/workflows/pr-checks.yml
autonomous: true

must_haves:
  truths:
    - "The staging PKI can be created and destroyed by running a script, not by clicking in a console"
    - "No AWS account id, endpoint prefix, or token is ever written to a tracked file"
    - "The role alias is created with credentialDurationSeconds=900, so revocation latency collapses to one polling interval"
    - "Revocation is a one-command lever that reports the observed post-revocation status rather than assuming it"
  artifacts:
    - path: "scripts/pki/setup-staging.sh"
      provides: "creates IAM role, IoT role alias, IoT policy; emits the untracked staging env file"
      min_lines: 80
    - path: "scripts/pki/teardown-staging.sh"
      provides: "reverses every resource setup-staging created, leaving no billable residue"
      min_lines: 50
    - path: "scripts/pki/revoke.sh"
      provides: "the SC4 lever"
      contains: "update-certificate"
    - path: "scripts/pki/README.md"
      provides: "staging runbook prerequisites and the account-identifier rule"
      min_lines: 40
  key_links:
    - from: "scripts/pki/setup-staging.sh"
      to: "scripts/pki/.staging-env"
      via: "writes account-identifying values to a gitignored file"
      pattern: "staging-env"
    - from: ".gitignore"
      to: "scripts/pki/.staging-env"
      via: "ignore rule"
      pattern: "staging-env"
    - from: ".github/workflows/pr-checks.yml"
      to: "scripts/pki/*.sh"
      via: "shellcheck glob extended to cover the new directory"
      pattern: "scripts/pki"
---

<objective>
Build the AWS-side half of the staging PKI as code: create the resources, destroy the resources,
and revoke a certificate.

Purpose: SC4 must be verified end-to-end against a staging PKI. That needs a reproducible,
destroyable staging environment and a revocation lever before there is anything to revoke. This
plan owns every shell script under `scripts/pki/` and the `.staging-env` contract that plan 07-05b's
broker reads; splitting the broker out keeps both changes inside the atomic-PR cap.
Output: `scripts/pki/*.sh` + README — never shipped in the image, never containing an account
identifier.

Plan 07-05b adds the CSR broker against the `.staging-env` variables frozen here. Plan 07-09 runs
the whole thing against a real staging account.
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
@scripts/sanitize/check.sh
@.github/workflows/pr-checks.yml
@.gitignore
</context>

<tasks>

<task type="auto">
  <name>Task 1: setup-staging.sh and the untracked-secret contract</name>
  <files>scripts/pki/setup-staging.sh, .gitignore, .github/workflows/pr-checks.yml</files>
  <action>
Create `scripts/pki/setup-staging.sh`. It reads `AWS_PROFILE` and `AWS_REGION` from the environment
(failing loudly if unset), takes a `--prefix` argument defaulting to `arlowe-staging`, and is
**idempotent** — re-running must not error on already-existing resources. It creates:

1. An IAM role `${PREFIX}-device-role` with a trust policy allowing
   `credentials.iot.amazonaws.com` to assume it. Attach a minimal inline policy; for staging, a
   single `s3:GetObject` on a placeholder bucket ARN is enough to prove the credentials are real —
   the actual OTA permissions are Phase 9's problem.
2. An IoT role alias `${PREFIX}-role-alias` pointing at that role with
   `--credential-duration-seconds 900`.
   **900 is not arbitrary and must carry a comment.** Revoking a certificate prevents new credential
   exchanges but does not retroactively invalidate an already-issued STS token, so the honest bound
   is `max(poll_interval, remaining_credential_lifetime)`. 900 is the AWS minimum and is at or below
   `identity.poll_interval_seconds`' 900 floor and 3600 default, which collapses the bound to one
   polling interval — the number SC4 tests against (ADR-0007).
3. An IoT policy `${PREFIX}-device-policy` granting exactly one action:
   `iot:AssumeRoleWithCertificate` on the role-alias ARN. Nothing else.
4. Discovers the credentials endpoint with
   `aws iot describe-endpoint --endpoint-type iot:CredentialProvider`.

Output goes to `scripts/pki/.staging-env` as shell `KEY=value` lines. **These six names are the
frozen contract that plan 07-05b's broker and plan 07-09's harness both read — do not rename them
later:**
`ARLOWE_PKI_PREFIX`, `ARLOWE_PKI_REGION`, `ARLOWE_PKI_ROLE_ALIAS`, `ARLOWE_PKI_POLICY`,
`ARLOWE_PKI_CREDENTIALS_ENDPOINT`, `ARLOWE_PKI_ROLE_ARN`.

**`scripts/pki/.staging-env` must be gitignored.** The credentials endpoint is
`<account-specific-prefix>.credentials.iot.<region>.amazonaws.com` — that prefix is
account-identifying, and it is NOT on `scripts/sanitize/banlist.txt`, so the sanitize gate will not
catch it. Add `scripts/pki/.staging-env` and `scripts/pki/*.pem` to `.gitignore` and say why in a
comment. The same rule applies to the broker URL. Never write either as a literal into tracked
source; they reach the device through `identity.credentials_endpoint` / `identity.role_alias` /
`identity.provisioning_url` or through the provisioning response.

Add `scripts/pki/*.sh` to the shellcheck glob list in `.github/workflows/pr-checks.yml`. The list is
explicit, not recursive — a new directory that is not added is silently unchecked.
  </action>
  <verify>
`shellcheck scripts/pki/setup-staging.sh` is clean
`bash -n scripts/pki/setup-staging.sh`
`AWS_PROFILE= AWS_REGION= bash scripts/pki/setup-staging.sh` exits non-zero with a clear message naming the missing variable
`git check-ignore -v scripts/pki/.staging-env` reports a match
`grep -q "scripts/pki/\*.sh" .github/workflows/pr-checks.yml`
`grep -q "credential-duration-seconds 900" scripts/pki/setup-staging.sh`
`bash scripts/sanitize/check.sh` exits 0
  </verify>
  <done>`setup-staging.sh` is shellcheck-clean, idempotent, fails loudly without AWS config, creates the role alias with a 900-second credential duration, and writes the six frozen `.staging-env` variables to a gitignored file.</done>
</task>

<task type="auto">
  <name>Task 2: teardown, revoke, and the README</name>
  <files>scripts/pki/teardown-staging.sh, scripts/pki/revoke.sh, scripts/pki/README.md</files>
  <action>
`scripts/pki/teardown-staging.sh` reverses everything `setup-staging.sh` created, including
detaching and deleting any certificates created by the broker under the prefix, so a staging run
leaves no billable residue. Make it safe to run twice. Note that AWS requires certificates be set
`INACTIVE` and have their principals/policies detached before deletion — handle that ordering
explicitly rather than letting the delete fail and be swallowed.

`scripts/pki/revoke.sh <certificate-id>` runs
`aws iot update-certificate --certificate-id "$1" --new-status REVOKED` then
`aws iot describe-certificate --certificate-id "$1"` and prints the observed status, so the caller
has proof rather than an assumption. Add `--status ACTIVE|INACTIVE|REVOKED` so the same script can
reactivate during iteration. Exit non-zero if the observed status does not match the requested one.

`scripts/pki/README.md` documents: prerequisites (`aws` CLI v2, credentials for a **staging**
account, never production), the setup/revoke/teardown sequence, the fact that nothing here ships in
the firmware image, the six `.staging-env` variable names, and the account-identifier rule from
task 1. Leave a placeholder heading `## Running the broker` for plan 07-05b to fill — do not
describe the broker here, it does not exist yet.
  </action>
  <verify>
`shellcheck scripts/pki/teardown-staging.sh scripts/pki/revoke.sh` is clean
`bash -n scripts/pki/teardown-staging.sh scripts/pki/revoke.sh`
`bash scripts/pki/revoke.sh` with no argument exits non-zero with a usage message
`grep -q "update-certificate" scripts/pki/revoke.sh && grep -q "describe-certificate" scripts/pki/revoke.sh`
`grep -q "ARLOWE_PKI_CREDENTIALS_ENDPOINT" scripts/pki/README.md`
`bash scripts/sanitize/check.sh` exits 0
  </verify>
  <done>Teardown and revoke scripts exist, are shellcheck-clean, are safe to run twice, and `revoke.sh` reports the status it observed rather than the status it requested. The README documents the sequence and the account-identifier rule.</done>
</task>

</tasks>

<verification>
- `shellcheck scripts/pki/*.sh` clean.
- `bash scripts/sanitize/check.sh` exits 0.
- `git ls-files scripts/pki` lists no `.staging-env` and no `.pem`, and no file containing an AWS account id or an endpoint prefix: `git grep -nE 'credentials\.iot\.[a-z0-9-]+\.amazonaws\.com|[0-9]{12}' -- scripts/pki` returns nothing.
- No file under `scripts/pki/` is referenced by any `pi-gen/stage-arlowe/**` script: `grep -rn "scripts/pki" pi-gen/` returns nothing.
- Net diff under **400** lines. **This is an honest number, not the 350 an earlier draft carried.**
  The declared `min_lines` alone (80 + 50 + 40, plus `revoke.sh`) floor this near 200, and four
  shell scripts with `set -euo pipefail`, argument validation, idempotent create/delete paths and
  the `.gitignore` change realistically land at 310-400. Both figures clear the 600-line atomic-PR
  cap, so the work is correctly sized — only the stated number was wrong, and a stated number that
  the plan's own artifact list exceeds is worse than no number, because it invites an executor to
  trim the teardown paths to hit it. Do not trim teardown coverage: an unreversed staging resource
  is a recurring bill.
</verification>

<success_criteria>
- A staging PKI can be stood up and torn down by script, with the role alias at `credentialDurationSeconds=900`.
- The revocation lever exists and reports the observed post-revocation status rather than assuming it.
- Trap 3 is owned: the 900-second credential duration is set here, with the reasoning in the script.
- The `.staging-env` variable names are frozen for 07-05b and 07-09 to consume.
</success_criteria>

<output>
After completion, create `.planning/phases/07-device-identity-and-pki/07-05a-SUMMARY.md`.
Record: the six `.staging-env` variable names verbatim (07-05b's broker reads four of them and
07-09's harness sources the file), the `--prefix` default, `revoke.sh`'s flags and exit behaviour,
and the teardown ordering constraint AWS imposes on certificate deletion.
</output>

**Budget note.** `pr-checks.yml`'s `size-check` excludes lockfiles only, not `.planning/`, so this plan's `SUMMARY.md` (~60-90 lines) counts against the net diff. Budget accordingly.
