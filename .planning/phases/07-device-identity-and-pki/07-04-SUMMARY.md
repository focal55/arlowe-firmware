---
phase: 07-device-identity-and-pki
plan: 04
subsystem: security
tags: [sc3, ident-03, image-build, shellcheck, boot-check, selfcheck-json]

requires:
  - phase: 03-service-user-and-filesystem-layout
    provides: install-arlowe-fs.sh creating /var/lib/arlowe/identity at arlowe:arlowe 0700
  - phase: 06-image-build
    provides: build-image.sh step 5 read-only slot-A loop-mount and the sanitize scan-dir gate
provides:
  - "check_identity_store <root> [--factory] — the reusable SC3 assertion"
  - "build-image.sh fails when key material ships in slot A or the identity store is non-empty"
  - "boot-check IDENTITY section + /var/lib/arlowe/state/identity-selfcheck.json"
affects: [07-05a, 07-05b, 07-06, 07-07, 07-08a, 11-dashboard-health]

tech-stack:
  added: []
  patterns:
    - "Root-prefixed assertions: one function serves both an image scan (mountpoint) and a device check (/); fixture trees are built at test runtime under mktemp -d so key-shaped files are never tracked"

key-files:
  created:
    - scripts/lib/identity-store-check.sh
    - tests/phase-7/test-identity-store-check.sh
  modified:
    - scripts/build-image.sh
    - runtime/cli/boot-check

key-decisions:
  - "The gate runs inside step 5's existing read-only mount, not as a new numbered step, because a second (and especially a read-write) loop-mount desyncs the .bmap generated later in the same script"
  - "An absent /var/lib/arlowe/identity is a violation on both surfaces, not an informational pass — absence means install-arlowe-fs.sh silently skipped"
  - "boot-check inlines the /opt/arlowe find predicate rather than shipping scripts/lib/ into the image; the library is named in-comment as the authority the two must agree on"
  - "Unpaired is OK, not FAIL: with /etc/arlowe/config.yml absent (the Phase 4 CONFIG-03 pairing trigger) missing identity material is correct state"

patterns-established:
  - "Every later Phase 7 plan is developed under this gate, so key handling is never retrofitted"
  - "boot-check sections take env overrides (ARLOWE_ROOT, ARLOWE_IDENTITY_OWNER) to stay testable off-device"

duration: 35min
completed: 2026-09-10
---

# Phase 07 Plan 04: Identity-Store Gate Summary

SC3 enforced mechanically: `check_identity_store` fails the image build on any key material outside `/var/lib/arlowe/identity/`, on wrong modes, or on a non-empty factory store — and `boot-check` reports the same shape on a running device as JSON.

## The assertion

`scripts/lib/identity-store-check.sh` exports `check_identity_store <root> [--factory]`. `<root>` is a filesystem prefix: `/` on a running device, a mountpoint when scanning an image. Two modes:

- **device mode** (no flag) — asserts no material under `/opt/arlowe`, `/etc/arlowe` or `/boot`; asserts the store exists, is a directory at `0700`, and every regular file inside is `0600`.
- **`--factory`** — all of the above plus the store must be **empty**. One image is flashed to every unit, so any material present would be an identical secret on every unit.

Returns 0 clean / 1 violation; emits `::error` annotations on stdout and human lines on stderr, matching `scripts/sanitize/check.sh`. Symlinks are matched by name and reported, never dereferenced. Fifteen self-test cases in `tests/phase-7/test-identity-store-check.sh`; every fixture tree is built at runtime under `mktemp -d` and removed via `trap`, so the only tracked file under `tests/phase-7/` is the script itself.

## Invocation in build-image.sh

Inside **step 5** (renamed "image gates"), after the sanitize gate `ok`s and before `cleanup_loop`:
`check_identity_store "${SLOT_A_MOUNTPOINT}" --factory`. It lives in step 5 rather than a new numbered step because step 5 already holds the only slot-A mount. A second mount — particularly a read-write one — rewrites the ext4 superblock after the `.bmap` is generated, and `bmaptool flash` then aborts on a checksum mismatch. `grep -c 'mount -o ro'` is still 1.

The `--factory` branch is live, not dead code: `install-arlowe-fs.sh:71` runs inside the pi-gen chroot and creates `/var/lib/arlowe/identity` at `arlowe:arlowe 0700` in the slot-A rootfs; the owner_state partition (p4) covers that path only at runtime. A slot-A scan therefore meets a present, empty, 0700 directory — the shape the self-test asserts explicitly.

## identity-selfcheck.json

`boot-check` writes `/var/lib/arlowe/state/identity-selfcheck.json` at 0644 (status file, not a secret) in a `umask 0022` subshell:

```json
{"paired": false, "identity_dir_ok": true, "device_id_present": false,
 "key_present": false, "cert_present": false, "modes_ok": true,
 "opt_arlowe_clean": true, "checked_at": "2026-09-10T02:23:24Z"}
```

Simulated unpaired factory-fresh run: **6 passed, 0 failed**. Paired-but-unprovisioned: 3 passed, 0 failed, 3 WARN. Injected 0644 `device.key` plus a `ca.pem` under `/opt/arlowe`: 2 FAIL, with `modes_ok` and `opt_arlowe_clean` both false in the JSON.

## Deviations from Plan

None. Per the plan, `boot-check`'s pre-existing "0 passed, 14 failed on a healthy unpaired device" defect was left alone.

## Verification

`bash tests/phase-7/test-identity-store-check.sh` 15/15 pass. The CI shellcheck glob run verbatim exits 0. `runtime/cli/boot-check` shows no new shellcheck findings vs its `HEAD` baseline (an SC2001 from a `sed` pipe was removed). `bash scripts/sanitize/check.sh` clean. `git ls-files | grep -E '\.(key|crt|csr|pem|p12|pfx)$'` empty.

## Next Phase Readiness

The gate exists before any key-generating code does, so 07-05a/05b and 07-07 are written under it. 07-06's repo-wide tracked-key-material check should reuse `IDENTITY_MATERIAL_GLOBS` rather than redefine it; Phase 11's dashboard health view consumes `identity-selfcheck.json` as shaped above.
