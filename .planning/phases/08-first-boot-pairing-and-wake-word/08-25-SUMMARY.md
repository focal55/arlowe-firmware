---
phase: 08-first-boot-pairing-and-wake-word
plan: 25
subsystem: pairing
tags: [pairing, systemd, sandbox, polkit]
requires:
  - phase: 08-04
    provides: config.yml gating of the six units
  - phase: 08-08
    provides: arlowe-radio-init.service
  - phase: 08-18
    provides: arlowe-factory-reset-resume.service, reset template
  - phase: 08-23
    provides: python3 -m pair
provides:
  - units/arlowe-pair.service (PAIR-01 wired)
  - tests/phase-8/test-pair-unit.sh
affects: [08-27b hardware checkpoint, image build]
key-files:
  created: [units/arlowe-pair.service, tests/phase-8/test-pair-unit.sh]
  modified: []
key-decisions:
  - "Requires= and After= arlowe-radio-init.service (orchestrator 08-25), not the plan's Wants="
  - "ReadWritePaths is /etc/arlowe, /var/lib/arlowe/identity, /var/lib/arlowe/dashboard only; state and logs dropped because nothing in the pairing path writes them"
  - "No sandbox change to arlowe-face or arlowe-dashboard: both already allow AF_UNIX and their syscall filter lets systemctl reach PID1"
duration: 35min
completed: 2026-09-29
---

# Phase 8 Plan 25: Pairing Unit Summary

**`arlowe-pair.service` runs `python3 -m pair` as arlowe when `/etc/arlowe/config.yml` is absent. It Requires= and is ordered after radio-init, and is ordered after identity-init, firstboot, NetworkManager and the reset resume. It gets CAP_NET_BIND_SERVICE and nothing else, the face's DeviceAllow, groups and SystemCallFilter (mbind included), RuntimeDirectory=arlowe-pair as its CWD, and write access to three paths. There is no Conflicts= with the face, and Restart=on-failure, so the exit 0 after the paired handoff is final.**

## Tasks
1. RED: 28 static assertions plus systemd-analyze verify when present, including the face/dashboard AF_UNIX check (b4c38fb)
2. GREEN: the unit (c000e67)

## Reset triggers over D-Bus (face @button, dashboard @dashboard)
- RestrictAddressFamilies: both units list AF_UNIX. The test asserts this.
- SystemCallFilter: both use `@system-service ~@privileged @resources mbind`. On the bench Pi (trixie, systemd 257, not the bookworm image), a transient unit ran `systemctl show` and `systemctl start [--no-block]` as a non-root user under exactly that sandbox, with PrivateDevices both yes and no. It reached PID1 and got polkit's answer ("Interactive authentication required" for a user with no rule). No SIGSYS and no EAFNOSUPPORT. The control run without AF_UNIX failed with "Address family not supported".
- polkit: `arlowe-factory-reset@button.service` and `@dashboard.service` start with `arlowe-`, and 50-arlowe-systemctl.rules returns YES for manage-units on that prefix. test-reset-units.sh already asserts this.
- Nothing needed changing. Still unproven on the bookworm image with the real rule: 08-27b.

## arlowe-firstboot ordering (reported, not decided)
The ordering is After= only. A failed firstboot (boot-check exits 1 on any FAIL) does not block pairing, because After= does not propagate failure. Two side effects:
- firstboot is a Type=oneshot with no TimeoutStartSec, so its start timeout is infinite. A hung `arlowe-grow-models` or `axcl-smi` would hold pairing's start forever.
- The sentinel is touched only by ExecStartPost, after success. On a unit whose boot-check FAILs (for example a dead NPU), firstboot and grow-models run again on every boot, and pairing waits for them each time.

## Deviations from Plan
1. Requires=arlowe-radio-init.service instead of Wants= (orchestrator contract for 08-25).
2. ReadWritePaths drops /var/lib/arlowe/state and /var/lib/arlowe/logs. No pair, identity or commit code writes them, and a listed path that is missing fails the unit at namespace setup.
3. RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX was added. The plan's spec did not name the families.
4. The test adds AF_UNIX checks on the face and dashboard, a Requires= radio-init check and a no-CA-override check.

## Verification
- tests/phase-8/test-pair-unit.sh: all PASS on macOS (systemd-analyze SKIP). In debian:bookworm with systemd it also passes, and the only thing `systemd-analyze verify` reports is the /usr/bin/python3 missing from the container.
- tests/phase-07.1/test-verify-unit-execstart.sh: all cases pass in bookworm. On macOS the fixture fails 60 cases, which is environmental.
- test-unit-gating, test-reset-units, test-boot-check, test-network-substrate: pass. shellcheck clean. sanitize clean.
- run-import-check.sh: see PR.
- Needs hardware or an image build: pairing actually starting on an unpaired boot, the polkit grant on the image (08-27b).
