---
phase: 07-device-identity-and-pki
plan: 05a
subsystem: infra
tags: [pki, aws-iot-core, staging, revocation, shellcheck, ops-tooling]

requires:
  - phase: 07-device-identity-and-pki
    provides: ADR-0007 (service selection) and the identity config block whose poll_interval floor the 900s credential duration is pinned against
provides:
  - scripts/pki/setup-staging.sh - idempotent staging PKI creation with credentialDurationSeconds=900
  - scripts/pki/teardown-staging.sh - full reversal including broker-minted certs and things
  - scripts/pki/revoke.sh - the SC4 lever, reporting observed rather than requested status
  - the six frozen ARLOWE_PKI_* names in the gitignored scripts/pki/.staging-env
affects: [07-05b, 07-07, 07-09]

tech-stack:
  added: []
  patterns:
    - "Ops-host scripts live under scripts/ and are structurally excluded from the image (no pi-gen reference)"
    - "Account-identifying values are confined to a gitignored env file because the sanitize banlist cannot catch them"

key-files:
  created:
    - scripts/pki/setup-staging.sh
    - scripts/pki/teardown-staging.sh
    - scripts/pki/revoke.sh
    - scripts/pki/README.md
  modified:
    - .gitignore
    - .github/workflows/pr-checks.yml

key-decisions:
  - "credentialDurationSeconds=900 lives in a named constant carrying the derivation, not a bare literal"
  - "teardown detaches ALL attached policies per cert, not just the prefix's, because a half-detached cert cannot be deleted"
  - "revoke.sh takes --status ACTIVE|INACTIVE|REVOKED so staging can be reset without minting a new cert"
  - "AWS_PROFILE/AWS_REGION stay out of .staging-env deliberately"

patterns-established:
  - "New scripts/ subdirectories must be added to the pr-checks shellcheck glob, which is explicit and not recursive"

duration: 18min
completed: 2026-09-10
---

# Phase 7 Plan 05a: Staging PKI as code Summary

**Four ops-host shell scripts that create, revoke against, and fully destroy an AWS IoT Core staging PKI, with the role alias pinned at `credentialDurationSeconds=900` so SC4's revocation bound is one polling interval rather than a hand-wave.**

## Performance

- **Duration:** 18 min
- **Tasks:** 2/2
- **Files:** 4 created, 2 modified
- **Net diff:** 420 lines before this SUMMARY

## Accomplishments

- **The staging PKI is reproducible and destroyable by script.** `setup-staging.sh` is create-or-update at every step (IAM role, role alias, IoT policy) so re-running never errors on existing resources; `teardown-staging.sh` is existence-checked at every step so it is safe to run twice.
- **Trap 3 is owned in code.** `CREDENTIAL_DURATION_SECONDS=900` carries the full derivation in a comment: revocation stops new credential exchanges but does not invalidate an already-issued STS token, so the honest bound is `max(poll_interval, remaining_credential_lifetime)`, and pinning 900 at or below `identity.poll_interval_seconds` (min 900, default 3600) collapses it to one interval.
- **No account identifier can reach a tracked file by accident.** `git grep -nE 'credentials\.iot\.[a-z0-9-]+\.amazonaws\.com|[0-9]{12}' -- scripts/pki` returns nothing, and `.staging-env` / `*.pem` are gitignored with the reason written down — the sanitize gate would not have caught either.

## Task Commits

1. **Task 1: setup-staging.sh + untracked-secret contract** — `6221187` (feat)
2. **Task 2: teardown, revoke, README** — `ddd83ac` (feat)

## Contracts frozen for 07-05b and 07-09

`scripts/pki/.staging-env` is written by `setup-staging.sh` as shell `KEY=value` lines, mode 0600, gitignored. **These six names must not be renamed:**

```
ARLOWE_PKI_PREFIX
ARLOWE_PKI_REGION
ARLOWE_PKI_ROLE_ALIAS
ARLOWE_PKI_POLICY
ARLOWE_PKI_CREDENTIALS_ENDPOINT
ARLOWE_PKI_ROLE_ARN
```

`AWS_PROFILE` and `AWS_REGION` are deliberately NOT in the file — all three scripts read them from the environment and fail with a named-variable message if either is unset or empty (`: "${VAR:?...}"`).

**`--prefix` defaults to `arlowe-staging`** on both `setup-staging.sh` and `teardown-staging.sh`, and derives every resource name: `${PREFIX}-device-role`, `${PREFIX}-role-alias`, `${PREFIX}-device-policy`, `${PREFIX}-ota-read` (inline IAM policy). Pass the same prefix to both or teardown misses everything.

**`revoke.sh <certificate-id> [--status ACTIVE|INACTIVE|REVOKED]`**, defaulting to `REVOKED`. It runs `update-certificate`, then re-reads with `describe-certificate --query certificateDescription.status`, prints `certificate <id> status: <OBSERVED>` on stdout, and exits 1 if observed != requested. Exit 2 on usage errors (no id, unknown flag, bad status). 07-09 can assert on `REVOKED` in that stdout line.

**Teardown ordering is an AWS constraint, not a style choice.** A certificate cannot be deleted while it is `ACTIVE` or while any policy or thing is still attached. `delete_certificate()` therefore: detaches every policy from `list-attached-policies` (not just the prefix's — a foreign attachment would block the delete just as hard), detaches and deletes every thing from `list-principal-things`, sets `INACTIVE`, then `delete-certificate --force-delete`. Certificates are discovered via `list-targets-for-policy` on the prefix's IoT policy, with a second sweep over prefix-named things to catch anything the broker registered without a policy-bearing cert.

## Deviations from Plan

**1. [Rule 3 - Blocking] The worktree was branched from the wrong base.** HEAD was `9206c63` (Phase 6 `#116` lineage), not `plan/phase-7-device-identity`, so `.planning/phases/07-device-identity-and-pki/` did not exist and the plan file could not be read. The working tree was clean, so this was resolved with `git reset --hard plan/phase-7-device-identity`. **Consequence for the orchestrator:** this branch does not contain `#116` (arm64 CI + flash-sd), so it will merge cleanly into the Phase 7 branch but is not a superset of main.

**2. Net diff is 420 lines before this SUMMARY, against a stated 400 budget.** Not resolved by trimming, per the plan's own instruction. The overage sits in `setup-staging.sh` (144) and `teardown-staging.sh` (132); the README was tightened from 72 to 71 lines and there is no further honest fat. `pr-checks.yml`'s size gate emits a **warning** at 400 and only **fails** at 1500, so this does not block. Trimming teardown coverage to hit a soft threshold would trade a recurring AWS bill for a green annotation.

## Issues Encountered

**Shellcheck SC2016 on the JMESPath filter.** `--query 'policyVersions[?isDefaultVersion==`false`].versionId'` trips SC2016 because backticks inside single quotes look like a suppressed expansion. Rewritten as `policyVersions[?!isDefaultVersion].versionId`, which is equivalent JMESPath with no backticks. Any future `scripts/pki/` query that needs a JMESPath literal will hit the same wall.

## Verification Evidence

- `shellcheck scripts/pki/*.sh` — clean (v0.11.0). `bash -n` clean on all three.
- `env -u AWS_PROFILE -u AWS_REGION bash scripts/pki/setup-staging.sh` → exit 1, message names `AWS_PROFILE`. Same for the empty-string form and for `teardown-staging.sh`.
- `bash scripts/pki/revoke.sh` (no args) → exit 2 + usage. `--status NOPE` → exit 2 + valid-values message.
- `git check-ignore -v scripts/pki/.staging-env` → `.gitignore:72`. `scripts/pki/broker.pem` → `.gitignore:73`.
- `grep -q "scripts/pki/\*.sh" .github/workflows/pr-checks.yml` → match.
- `grep -q "credential-duration-seconds 900" scripts/pki/setup-staging.sh` → match.
- `bash scripts/sanitize/check.sh` → exit 0 (235 tracked files, 11 unit files).
- `git ls-files scripts/pki` → 4 files, no `.staging-env`, no `.pem`.
- `grep -rn "scripts/pki" pi-gen/` → no output.

**Not verified: anything against a real AWS account.** No `aws` call in any of these scripts has been executed. Idempotency, the teardown ordering, and the 900s duration taking effect are all reasoned from the API contracts in 07-RESEARCH, not observed. Plan 07-09 is the first time this runs for real, and it is where `setup` → `revoke` → `teardown` either holds or does not.

## Next Phase Readiness

07-05b can write the CSR broker against the six frozen variable names and fill the `## Running the broker` placeholder heading left in `scripts/pki/README.md`. 07-07 must cap its credential cache TTL at or below 900s. 07-09 sources `.staging-env` and asserts residual validity <= 900s.
