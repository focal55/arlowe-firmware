---
phase: 08-first-boot-pairing-and-wake-word
plan: 04
subsystem: runtime-units
tags: [systemd, boot-check, pairing, gating]
requires: [PR #201 (no default login)]
provides: [six units gated on /etc/arlowe/config.yml, paired-aware boot-check, tests/phase-8 gating and boot-check suites]
affects: [08 pairing daemon (writes config.yml, then starts the six), 7.1 SC6 procedure]
key-files:
  created: [tests/phase-8/test-unit-gating.sh, tests/phase-8/test-boot-check.sh]
  modified: [units/{arlowe-dashboard,arlowe-face,arlowe-voice,qwen-api,qwen-tokenizer,whisper-stt}.service, runtime/cli/boot-check, pi-gen/stage-arlowe/03-firstboot/00-run-chroot.sh, pi-gen/stage-arlowe/03-firstboot/files/arlowe-firstboot.service, provision/polkit/50-arlowe-systemctl.rules, docs/operations/phase-7.1-substrate.md]
decisions:
  - "The six units stay enabled at build; ConditionPathExists=/etc/arlowe/config.yml is the only gate, so writing config.yml is pairing's single commit point"
  - "boot-check exits 1 on any FAIL, 2 on a usage error; unpaired runtime checks are SKIP, not FAIL"
completed: 2026-09-28
---

# Phase 8 Plan 04: Gate units on config.yml Summary

The six runtime units now skip on an unpaired device via `ConditionPathExists=/etc/arlowe/config.yml`, and `boot-check` reports that state as `SKIP ... (not paired)` plus `READY TO PAIR` instead of 13 FAILs, exiting non-zero on real failures.

## Tasks

| Task | Commit | |
|---|---|---|
| 1 RED: gating and boot-check cases | ca99bec | 7 gating and 19 boot-check cases failed for the reason under test |
| 2 GREEN: gate six units, paired-aware boot-check | 2d45206 | both suites pass except `[gate-no-stale-comment]` |
| 3 Correct stale comments | 2a1c17c | all pass |

## Verification (local, macOS)

- `tests/phase-8/test-unit-gating.sh`: all pass; `[gate-verify]` SKIPPED (no `systemd-analyze` on macOS).
- `tests/phase-8/test-boot-check.sh`: all pass.
- `shellcheck` on `runtime/cli/boot-check`, both new tests, `03-firstboot/00-run-chroot.sh`: clean.
- `scripts/sanitize/check.sh --grep-only`: clean.
- `tests/phase-07.1/test-recovery-stub-units.sh`: 5/5.
- `tests/phase-07.1/test-verify-unit-execstart.sh`: exits 127 per case on macOS (Linux tooling such as dpkg is missing), so CI on Linux is the evidence.
- The `phase8-shell` CI job belongs to 08-02. If this merges first, the new suites have only run locally.
- Not verified: behaviour on hardware. That needs an image build, and nobody has booted a gated image.

## Deviations from Plan

1. **[Rule 3] Precondition check is literal-wrong.** `git show main:pi-gen/config | grep -c FIRST_USER_PASS` prints 1. The one match is the comment saying the variable is deliberately unset. `grep -c '^FIRST_USER_PASS='` prints 0 and PR #201 is merged, so the intent holds. Proceeded.
2. **[Rule 1] The stale-comment regex was widened** to `installed[-* ]+but[-* ]+disabled|ship(s)? disabled|disabled by design`. The plan's regex missed the runbook's `**installed but disabled**` (bold, spaces) and "disabled by design", so it would have passed with the stale text still present.
3. **[Rule 1] The `[bc-no-openai]` case asserts on `OpenAI`, not `qwen-openai`.** boot-check prints the description "Qwen OpenAI Wrapper", so the literal needle passed against the unfixed script.
4. **[Rule 3] Fixed the SC2086 findings on the existing `check_service` and `check_port` lines.** Shellcheck on boot-check could not pass without it. `$svc` and `$port` are now quoted, and `SYSTEMCTL_FLAGS` is left unquoted on purpose, with a disable comment.
5. **Runbook scope.** Beyond the plan's lines, steps 6 and 7 are also marked pre-Phase-8, because an unpaired unit no longer runs voice or the dashboard. The stale `qwen-openai` was dropped from the step-5 dependency order.

## Next Phase Readiness

- Pairing must write a config.yml that **validates**: face, voice and qwen-tokenizer run `arlowe_config_validate` in `ExecStartPre`. Then it runs `systemctl start` on the six. No `enable` is needed.
- The `arlowe-pair.service` named in the unit comments does not exist yet. The pairing plan must create it under that name, gated on `ConditionPathExists=!/etc/arlowe/config.yml`.
