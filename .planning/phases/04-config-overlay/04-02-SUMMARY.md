---
phase: 04-config-overlay
plan: 02
type: summary
status: complete
date: 2026-06-07
pr: pending
---

## What was done

Implemented the settled LOOSEN-PERMS decision (ADR-0003) for the dashboard→`/etc/arlowe/config.yml` write path, installed schema and defaults into the image layout, and stood up the phase-4 Docker harness.

## Files changed

| File | Change |
|------|--------|
| `docs/architecture/0003-dashboard-config-write-path.md` | New ADR: records loosen-perms decision, three containment requirements, Phase 10 re-hardening flag |
| `scripts/provision/install-arlowe-fs.sh` | `/etc/arlowe` mode changed from `0755` → `0770` (group-writable, ADR-0003) |
| `scripts/provision/install-arlowe-config.sh` | New: installs `schema.yml`, `defaults.yml`, `arlowe_config.py`, `arlowe_config_validate.py`; never creates `config.yml` |
| `units/arlowe-dashboard.service` | Replaced FIXME(Phase 4) block with ADR-0003 citation; added `/etc/arlowe` to `ReadWritePaths` (scoped, not broader `/etc`) |
| `tests/phase-4/assertions/01-config-install-shape.sh` | New: stat-only assertion — `/etc/arlowe` is `770 root:arlowe`; config files installed; `config.yml` absent |
| `tests/phase-4/docker/run-tests.sh` | New: phase-4 harness reusing the phase-3 Dockerfile; auto-discovers installers + loops `tests/phase-4/assertions/*.sh` |
| `tests/phase-3/assertions/02-fs-layout.sh` | Updated `/etc/arlowe` expected mode from `755` → `770` to match the installer change |

## Verification

- All new scripts pass `bash -n` syntax check.
- `grep -q 'm 0770 /etc/arlowe' scripts/provision/install-arlowe-fs.sh` passes.
- `grep -qE 'ReadWritePaths=.*/etc/arlowe' units/arlowe-dashboard.service` passes.
- `grep -q 'tests/phase-4/assertions' tests/phase-4/docker/run-tests.sh` passes.
- `grep -q 'phase-3/docker' tests/phase-4/docker/run-tests.sh` passes (confirms Dockerfile reuse).
- ADR contains "0770" and "Phase 10" per plan verification criteria.
- Sanitize gate: clean (grep gate + units gate, 152 files).
- `install-arlowe-config.sh` never creates `/etc/arlowe/config.yml`.

## Requirements satisfied

- **CONFIG-02**: `defaults.yml` ships in the image via `install-arlowe-config.sh`.
- **CONFIG-03**: `/etc/arlowe/config.yml` absent on factory image (absence contract enforced in installer + asserted in `01-config-install-shape.sh`).
- **ADR-0003**: loosen-perms decision documented with all three containment requirements.

## Notes

- Phase-3 assertion `02-fs-layout.sh` updated to expect `770` (not `755`) for `/etc/arlowe` — this is required correctness, not scope creep; the assertion must match the installer.
- Validator execution (pytest + `arlowe_config_validate`) is NOT exercised in the Docker testbed by design; it runs in 04-01's repo-root pytest and on the Pi. The harness comment states this explicitly.
- `ota.channel_url` and `support_mode.*` re-hardening is deferred to Phase 10 as documented in ADR-0003.
