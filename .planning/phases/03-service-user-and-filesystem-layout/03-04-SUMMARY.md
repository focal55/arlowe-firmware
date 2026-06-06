---
phase: 03-service-user-and-filesystem-layout
plan: 04
status: complete
provides:
  - /usr/local/sbin/arlowe-{face,speak,stt,record,boot-check,purge-logs,run-logrotate,wake-train} symlinks (Phase 10 support-mode invocation pattern depends on these)
  - boot-check ARLOWE_SYSTEMCTL_FLAGS default flipped from '--user' to '' (Phase 11 boot-health depends on this; Phase 5 audio auto-detect calls boot-check)
  - No Phase 1 runtime/cli/* file behavior changed except boot-check's default; other CLI scripts ride the symlinks without modification
files_written:
  - scripts/provision/install-arlowe-cli.sh
  - runtime/cli/boot-check  (one-line default flip)
  - tests/phase-3/assertions/05-cli-symlinks.sh
---

## What landed

**`scripts/provision/install-arlowe-cli.sh`** — idempotent installer that creates 8
root-owned symlinks in `/usr/local/sbin/arlowe-*` pointing into
`/opt/arlowe/runtime/cli/<name>`. Uses `ln -sf` for idempotency. Picked up
automatically by the Phase 3 Docker harness auto-discovery loop (run-tests.sh
already contains the CLI pre-stage step gated on this file's existence).

**`runtime/cli/boot-check`** — single-line edit: `ARLOWE_SYSTEMCTL_FLAGS` default
changed from `--user` (Phase 1 legacy) to `""` (system-level, Phase 3+ image).
Backward-compat preserved — `ARLOWE_SYSTEMCTL_FLAGS=--user` env override still
works for ad-hoc invocations against dev-stash `--user` units.

**`tests/phase-3/assertions/05-cli-symlinks.sh`** — validates all 8 symlinks exist,
each points to the correct target and resolves to an existing file, each is
root-owned, and the boot-check default-flip is in place.

## Verification

Docker testbed (`bash tests/phase-3/docker/run-tests.sh`): all 5 assertions pass,
including 05-cli-symlinks.sh. Sanitization gate clean (139 files, 9 units).

## Cross-phase dependencies satisfied

- Phase 5 audio auto-detect calls `arlowe-boot-check`; symlink now in PATH.
- Phase 10 support-mode SSH invokes all 8 `arlowe-*` helpers; discoverable via `/usr/local/sbin`.
- Phase 11 boot-health reads service status via system-level `systemctl` (no `--user`); boot-check default now matches.
