# ADR-0003: Dashboard config write path — loosen-perms decision

<!-- status: accepted -->
**Status:** Accepted
**Date:** 2026-06-07
**Phase:** 4 (Config overlay)
**Closes:** CONFIG-02, CONFIG-03
**Supersedes:** FIXME(Phase 4) comment in `units/arlowe-dashboard.service`

## Context

Phase 3 provisioned `/etc/arlowe` as `root:arlowe 0755` (group has `r-x`, not write).
The `arlowe-dashboard.service` unit runs under `ProtectSystem=strict` with
`ReadWritePaths` scoped to `/var/lib/arlowe/dashboard` and `/var/lib/arlowe/logs/dashboard`
only. The unit file carried an explicit `FIXME(Phase 4)` noting that the dashboard's
`POST /api/config` route, which does a temp-file + rename write to `/etc/arlowe/config.yml`,
must go through a privileged helper because `/etc/arlowe` was not writable.

Two options were evaluated:

1. **Privileged helper via polkit or setuid.** A small root-owned helper validates then
   writes the overlay. Most restrictive, but requires a new polkit action or setuid binary —
   additional auditable surface with no proportional gain given the dashboard's existing
   trust level.
2. **Loosen perms (LOOSEN-PERMS).** Set `/etc/arlowe` to `root:arlowe 0770` (group-writable)
   and add `ReadWritePaths=/etc/arlowe` to the dashboard unit. The dashboard writes the
   overlay directly via temp-file + rename (already implemented correctly in `route.ts`).

The dashboard is already a trusted process: the Phase 3 polkit rule grants it the ability
to restart `arlowe-*`, `qwen-*`, and `whisper-stt.service` units without sudo. Adding a
write path into `/etc/arlowe` is a proportionate extension of that trust, not an
escalation.

## Decision

**LOOSEN-PERMS.** `/etc/arlowe` is provisioned `root:arlowe 0770` and
`ReadWritePaths=/etc/arlowe` is added to `arlowe-dashboard.service` (scoped to that
path only).

## Containment requirements

These constraints are MANDATORY and must not be relaxed without a superseding ADR:

1. **`ReadWritePaths` is scoped to `/etc/arlowe` exactly.** The entry in the dashboard
   unit is `ReadWritePaths=/etc/arlowe`, never a broader `/etc` path. The dashboard's
   write surface widens to one config directory — not to arbitrary `/etc` files.

2. **The loader's fail-fast schema validation (Plan 04-01) is retained regardless.**
   Loosening the write path does not relax validation. An invalid overlay still causes
   `ExecStartPre` (which runs `arlowe_config_validate`) to exit 78 (EX_CONFIG) and
   prevents the affected service from starting. The `ProtectSystem=strict` sandbox
   on all other units is unchanged.

3. **`ota.channel_url` and `support_mode.*` are flagged for re-hardening in Phase 10.**
   These knobs are defined in `config/schema.yml` and accepted by the loader today, but
   they govern privileged operations (firmware update source, remote support access).
   When Phase 10 (support-mode) lands, those specific knobs must move behind a
   re-authenticated privileged write path — the plain group-writable `/etc/arlowe`
   write is NOT the correct final surface for them. This ADR explicitly records that
   future-work item so the decision is revisitable.

## Consequences

**Positive:**
- Dashboard can persist `/etc/arlowe/config.yml` via the existing temp+rename path in
  `route.ts` without introducing a new privileged binary or polkit action.
- Implementation is minimal: one `install -d` mode change and one `ReadWritePaths` entry.
- The write surface is bounded by `ProtectSystem=strict` + scoped `ReadWritePaths`; the
  dashboard cannot write any `/etc` file outside `/etc/arlowe`.

**Negative / known gaps:**
- `ota.channel_url` and `support_mode.*` knobs are writable by the dashboard in Phase 4;
  re-hardening is deferred to Phase 10 (see containment requirement 3 above).
- The dashboard process has a broader write surface than in Phase 3, which is a trade-off
  accepted because the dashboard is already the most trusted runtime process.

## References

- Research: `.planning/phases/04-config-overlay/04-RESEARCH.md` §Pitfall 1, §Open-Question 1
- Plan: `.planning/phases/04-config-overlay/04-02-PLAN.md`
- Superseded comment: `units/arlowe-dashboard.service` FIXME(Phase 4) block (removed in this plan)
- Perms change: `scripts/provision/install-arlowe-fs.sh` `/etc/arlowe` line → `0770`
- Unit change: `units/arlowe-dashboard.service` `ReadWritePaths` → includes `/etc/arlowe`
