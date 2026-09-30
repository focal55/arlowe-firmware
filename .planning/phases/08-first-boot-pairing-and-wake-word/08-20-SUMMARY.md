---
phase: 08-first-boot-pairing-and-wake-word
plan: 20
subsystem: pairing
tags: [pairing, argon2, config, commit, systemd]
requires:
  - phase: 08-13
    provides: PairingFlow commit(form, provisioned) contract
  - phase: 08-14
    provides: arlowe-pair-commit.service and its request file
  - phase: 08-09
    provides: argon2.ts verifyPassword, credential.ts loadOwnerCredential
provides:
  - pair.commit.Committer (the flow's commit callable) and start_runtime()
  - pair.credential write_owner_credential, write_session_key, write_private
  - python3-argon2 in the image; pair-node-compat CI job
affects: [08-23 pairing daemon, 08-25 pairing unit, 08-21 dashboard login]
key-files:
  created: [runtime/pair/commit.py, runtime/pair/credential.py, runtime/pair/tests/test_commit.py, runtime/pair/tests/test_credential_node.py]
  modified: [pi-gen/stage-arlowe/00-packages/00-packages-nr, .github/workflows/phase-8.yml]
key-decisions:
  - "The committer re-derives the slug from display_name with validate_display_name, the same call the root helper makes, instead of trusting form['slug']"
  - "Validation runs arlowe_config_validate in a subprocess, exactly what the units' ExecStartPre runs"
duration: 35min
completed: 2026-09-29
---

# Phase 8 Plan 20: Pairing Commit Summary

**Crash-safe pairing commit: Argon2id owner credential and 32-byte session key (0600), hostname through the root oneshot, then a validated, fsynced `os.replace` of `/etc/arlowe/config.yml` as the single commit point. A separate `start_runtime()` starts the six units. python3-argon2 ships in the image in the same change.**

## Task Commits

1. **Task 1: Cases (RED)** - `c66b02b` (test)
2. **Task 2: Credential, commit, package (GREEN)** - `640da06` (feat)

## Interfaces for later plans

- `Committer(etc_dir="/etc/arlowe", run_dir="/run/arlowe-pair", state_dir="/var/lib/arlowe/dashboard", systemctl="systemctl", defaults_path=None, python=sys.executable, clock=utcnow)`. `defaults_path` falls back to `ARLOWE_DEFAULTS_PATH`, then `/opt/arlowe/config/defaults.yml`.
- `committer(form, provisioned)` raises `pair.commit.CommitError` (helper exit or validation failure) or `HostnameRejected`; the flow maps any exception to `setup_failed`. It uses `form["display_name"]`, `form["password"]`, `form["ssid"]` and `provisioned["broker_url"]`.
- `committer.start_runtime()` returns the exit code of `systemctl start --no-block` naming the six units and logs a non-zero one.
- The daemon (08-25) needs write access to `/etc/arlowe`, `/var/lib/arlowe/dashboard` and `/run/arlowe-pair`. Running it as `arlowe` gives `config.yml` arlowe:arlowe 0640 in the root:arlowe 0770 directory, and gives the credential files an owner the dashboard (User=arlowe) can read.

## Deviations from Plan

1. **[Plan text] Constructor shape.** The plan says `Committer(paths, runner, clock)`. The implementation takes explicit keyword paths plus a `systemctl` binary path and calls `subprocess.run`, so tests use a shim executable, as the execution notes describe. No `runner` object.
2. **[Contract, wave1-interfaces 08-14/08-20] Request file removed.** `commit-request.json` is removed in a `finally` after the helper runs, whether it succeeded or failed. The plan does not mention this; the orchestrator decision requires it.
3. **[Rule 1 - Bug, own test] SSID truncation case.** The first version of the case ("café" x 8) happened to cut at a character boundary, so it never exercised the multi-byte cut. It now uses "a" + "é" x 20, where the 32-byte cut falls inside a character. Fixed in `640da06`.
4. **Merge gate.** Cleared by the orchestrator (07.3-09 build B builds from c008e84). The package was checked against the snapshot: `python3-argon2` 21.1.0-2 exists in bookworm main arm64 at 20260915T000000Z, and it depends on libargon2-1 and the python3-cffi backend.

## Verification

- `pytest runtime/pair/tests` (argon2-cffi 21.1.0, Python 3.11): 78 passed. test_display.py was deselected because DejaVuSans is not installed on the Mac (`OSError: cannot open resource`). That is an environment gap, not a code failure: the CI container installs fonts-dejavu-core.
- `ARLOWE_REQUIRE_NODE=1 pytest runtime/pair/tests/test_credential_node.py` on Node 24.15, in a venv containing only argon2-cffi and pytest: 2 passed.
- The phase-8.yml jobs now include pair-node-compat. `scripts/sanitize/check.sh`: clean.
- Not verified here: that the daemon works on the device. That needs 08-23/08-25 and an image build.
