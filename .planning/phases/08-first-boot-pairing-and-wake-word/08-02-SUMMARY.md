---
phase: 08-first-boot-pairing-and-wake-word
plan: 02
subsystem: config
tags: [json-schema, dashboard, ci, bookworm]
requires:
  - phase: 08-01
    provides: no default login in the image (PR #201)
provides:
  - device.display_name, owner.paired_at, network.wifi_label in config/schema.yml
  - buildSaveBody merges a partial overlay over CONFIG_DEFAULTS instead of discarding it
  - .github/workflows/phase-8.yml (pair-bookworm, phase8-shell, pki-broker)
affects: [pairing daemon, factory reset, dashboard settings, every later Phase 8 test]
key-files:
  created: [tests/phase-8/test_schema_pairing_keys.py, .github/workflows/phase-8.yml]
  modified: [config/schema.yml, config/defaults.yml, runtime/dashboard/app/audio/save-body.ts, runtime/dashboard/tests/unit/audio-save-body.test.ts]
key-decisions:
  - "pair-bookworm's apt set is derived from 00-packages-nr; only python3-lgpio and python3-rpi-lgpio are excluded as Pi-archive-only, and the job fails if either ever resolves from Debian"
  - "isFullConfig kept: the existing identity test imports it"
duration: 10min
completed: 2026-09-28
---

# Phase 8 Plan 02: Pairing Schema and Phase 8 CI Summary

**The schema accepts the pairing overlay's display_name, owner and network keys and still rejects any other key, the dashboard's audio save no longer drops a partial overlay, and a Phase 8 workflow runs tests in a bookworm container whose packages are derived from the image's own package list.**

## Task Commits

1. **Task 1: Schema cases (RED)** - `24c79d0` (test). RED: 2 of 6 pytest cases failed (pairing overlay, display_name default); 2 of 24 dashboard cases failed (display_name default, pairing overlay survives).
2. **Task 2: Schema, defaults and save-body (GREEN)** - `6ec24cb` (feat)
3. **Task 3: The Phase 8 CI workflow** - `01c4c22` (ci)

## Verification

- `tests/phase-8/test_schema_pairing_keys.py`: 6 passed.
- runtime/lib + runtime/voice + tests/phase-8 (host venv, the ci.yml env): 184 passed, 1 skipped.
- runtime/face/tests/test_persona_overlay.py: 2 passed. scripts/pki/tests: 19 passed.
- Dashboard `test:unit` 24/24, `typecheck` clean, eslint clean on the changed files.
- The pair-bookworm steps, extracted from the workflow and run under `bash -eo pipefail` in an amd64 `debian:bookworm` container: install rc=0, derived set `python3-spidev python3-cryptography python3-requests python3-yaml python3-jsonschema python3-numpy python3-pil python3-scipy python3-sklearn python3-joblib python3-pyaudio`, cryptography 38.0.4, 6 passed.
- Both of the workflow's shell scripts pass shellcheck. The sanitize check passes.

## Deviations from Plan

1. **[Rule 1 - Bug] python3-spidev is not Pi-archive-only.** The plan listed it with lgpio and rpi-lgpio. `apt-cache policy` in amd64 bookworm shows candidate `3.6-1+b1`, so the job installs it. The ci.yml comment that says spidev has no amd64 equivalent is wrong too; this plan leaves it unchanged.
2. **Precondition grep prints 1, not 0.** `git show main:pi-gen/config | grep -c FIRST_USER_PASS` matches the comment that says the variable is deliberately unset. No assignment exists and PR #201 is merged, so the intent is met.
3. **The loader deep-merges.** The plan and the header of schema.yml both say the top-level merge is shallow. `arlowe_config.deep_merge` actually recurses. So the `device` description gives a different reason for writing the block whole: no consumer of the raw overlay should ever see the hostname template.
4. **Test-only change to the host environment.** The host python had no `cryptography`, so the runtime/lib suites ran in a scratch venv. The dashboard needed `pnpm@10.15.0` via npx because the global pnpm is 11.

## Next Phase Readiness

- Later plans put Python tests in `tests/phase-8/` or `runtime/pair/tests/` and shell tests in `tests/phase-8/test-*.sh`. No CI edit is needed. pair-bookworm runs with `--import-mode=importlib` and `PYTHONPATH=runtime:runtime/lib`.
- A new Python dependency must be declared in `00-packages-nr`. pair-bookworm only sees packages declared there.
- The `wake` block is not in the schema. Phase 8.1 adds it.
