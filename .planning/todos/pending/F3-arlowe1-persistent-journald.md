# F3 — Enable persistent systemd-user journald on arlowe-1

**Origin:** Plan 13 (Phase 1 smoke test), Task 4 iteration 3. `journalctl --user -u arlowe-voice-test -f` returned "No journal files were found" — meaning the `--user` instance of journald isn't writing persistent journal files. This hid the actual failure trace for `arlowe-voice-test` during the smoke test, contributing to the iteration's inability to confirm whether the unit had actually started.

**Target:** Workforce infra / dev-env (NOT a project phase). Joe-managed task on arlowe-1, separate from the firmware codebase.

## Problem

systemd `--user` units write to a per-user journal. Without persistent storage configured, that journal lives only in memory and is sometimes not even reachable by `journalctl --user -u <name>` from a fresh ssh session — the message "No journal files were found" is the symptom.

This makes debugging failed `--user` units painful: the unit fails, we can't see why, and `systemctl --user status` only shows the last few lines of the most recent run if any.

## Fix shape

On arlowe-1:

```bash
# Option A: per-user persistent journal directory
mkdir -p ~/.local/state/log/journal
systemctl --user restart systemd-journald  # or whichever the user-instance is

# Option B: set Storage=persistent in a user journald.conf override
mkdir -p ~/.config/systemd/user/systemd-journald.service.d/
cat > ~/.config/systemd/user/systemd-journald.service.d/override.conf <<'EOF'
[Service]
Environment=SYSTEMD_LOG_LEVEL=info
EOF

# Verify after either:
journalctl --user --list-boots  # should now show boot entries
```

Acceptance:
- After restart, `journalctl --user -u <some-running-user-unit>` returns log lines (not "No journal files found").
- Failures of `--user` units are inspectable via `journalctl --user -u <unit> --no-pager | tail -50`.

## Effort estimate

~15min. Includes verification by starting a test unit and reading its journal.

## Cross-references

- Plan 13 SUMMARY: F3
- Plan 13 iteration 3 failure context: `docs/operations/phase-1-smoke-test.md` Task 3 bug-fix iteration section
- Not blocking any phase — but if F4 (post-Phase-6 plan 13 re-run) happens before this is fixed, expect the same iteration drag
