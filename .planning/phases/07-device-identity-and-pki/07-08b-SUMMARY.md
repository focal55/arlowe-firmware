---
phase: 07-device-identity-and-pki
plan: 08b
subsystem: identity
tags: [systemd, first-boot, pi-gen, image-wiring, sandbox, sc2]
requires: ["07-08a: runtime/cli/identity", "07-03: store paths", "06: pi-gen stage-arlowe + owner_state partition"]
provides: ["units/arlowe-identity-init.service: enabled-on-factory-image first-boot identity derivation", "arlowe-identity on the device PATH"]
affects: ["07-09 SC2/SC3 verification scripts", "08 pairing daemon (starts the six runtime units, calls `identity provision`)"]
tech-stack: {added: [python3-yaml, python3-jsonschema], patterns: ["RequiresMountsFor instead of ConditionPathExists for store presence", "wants-symlink enablement guarded by a unit-file existence check", "docker testbed pre-stage derived from the repo tree, not a literal list"]}
key-files: {created: [units/arlowe-identity-init.service], modified: [scripts/provision/install-arlowe-cli.sh, pi-gen/stage-arlowe/03-firstboot/00-run-chroot.sh, pi-gen/stage-arlowe/00-packages/00-packages-nr, tests/phase-3/docker/run-tests.sh, tests/phase-4/docker/run-tests.sh]}
key-decisions: ["unit runs `init`, not `provision` -- provisioning needs a broker URL and owner token that do not exist until Phase 8", "RequiresMountsFor=/var/lib/arlowe, no Condition* of any kind", "enabled on the factory image, unlike the six runtime units", "chroot step exits non-zero rather than link a wants symlink to a missing unit"]
duration: 78min
completed: 2026-09-11
---

# Phase 7 Plan 08b: First-boot identity unit and image wiring Summary

**A factory device now derives its device-id, P-256 key and CSR before any human touches it, and the two ways that could have silently not happened -- a skipped unit and a dangling symlink -- were each made to fail out loud and then watched failing.**

## The enablement decision

`arlowe-identity-init.service` is **enabled** on the factory image. The six Phase 3 runtime units ship installed-but-disabled because Phase 8's pairing daemon starts them after pairing; this one is the exception and the chroot step says so in a comment, because the obvious "cleanup" is to make it match its siblings.

It runs `identity init`, not `provision`. `provision` needs a broker URL and an owner token, neither of which exists before Phase 8 pairing. `init` is the entirely offline half -- device-id derivation, keypair, CSR -- which is exactly what SC2 asks for: a device that boots and has an identity with no human, no network and no account.

## Why RequiresMountsFor and not ConditionPathExists

`ConditionPathExists=/var/lib/arlowe/identity` reads like the right guard and is the trap. A failed `Condition*` makes systemd **skip** the unit: one journal line, `Result=success`, `is-failed` reports `inactive`. Nothing is red. On the SC2-critical unit that means a shipped device with no identity and no signal.

Run under real systemd (PID 1, bookworm 252.39, privileged container) with `/var/lib/arlowe` removed, both variants of the same unit:

| Variant | `systemctl start` rc | `is-failed` | `Result` | Journal |
| --- | --- | --- | --- | --- |
| As shipped (`RequiresMountsFor`, no `Condition*`) | 1 | `failed` | `exit-code` (226/NAMESPACE) | names `/run/systemd/unit-root/var/lib/arlowe/identity` |
| With `ConditionPathExists` added | **0** | **`inactive`** | **`success`** | "was skipped because of an unmet condition check" |

The second row is the failure class that cost this repo roughly seven weeks (F7 #18 stage-root package list, #21 dangling CLI symlink, #25 A/B flip). It is now a measured counterfactual sitting next to the shipped behaviour rather than an argument.

`RequiresMountsFor=/var/lib/arlowe` pulls in the owner_state (p4) mount unit and fails if it is absent. `ProtectSystem=strict` + `ReadWritePaths=/var/lib/arlowe/identity` is what actually produces the 226 in the table: systemd cannot build the mount namespace when the only writable path does not exist. That is a blunt error message, so the CLI's own guard covers the subtler case -- store path present but not the expected one -- with `ExecMainStatus=5` and the full explanation in the journal:

```
arlowe-identity: identity store /var/lib/arlowe/identity/nope does not exist; the
owner_state partition is not mounted. Refusing to create it -- identity written to
the underlying rootfs would be lost on the next A/B flip.
```

**Which demonstration was run:** the strong one. Real systemd as PID 1, the unit installed by `units/install-units.sh` and enabled by the real chroot step, started with the store genuinely absent -- not the `ARLOWE_IDENTITY_DIR` approximation the plan offered as a fallback. The approximation was also run, as case 3 above, because it exercises a different code path.

## UMask=0077, stated honestly

`UMask=0077` is present and was confirmed active on the running unit (`systemctl show -p UMask`). The plan's rationale -- that systemd's default 0022 would yield 0644 and fail SC3 -- is **not what the measurement shows**. Running `init` under `umask 0022` produces 0600 on all five files anyway, because `write_secret()` opens with `O_EXCL` and an explicit mode and then `chmod`s. The unit-level umask is not load-bearing today; it is there so the next file someone adds to the store is 0600 by default rather than 0644 by default. The unit comment says that rather than the tidier claim.

On the happy path under systemd: `Result=success`, and

```
device-entropy 600 arlowe:arlowe   device-id 600 arlowe:arlowe
device.csr     600 arlowe:arlowe   device.key 600 arlowe:arlowe
identity.json  600 arlowe:arlowe
```

No chown step: the unit runs as `arlowe`, so the files land owned correctly.

`RestrictAddressFamilies=AF_UNIX` (journal socket only) is a scope check, not decoration -- if someone later makes `init` phone home, the unit fails rather than quietly acquiring a network dependency at boot. `ProtectSystem=strict` scoping was verified adversarially: a process in the same sandbox cannot create `/opt/arlowe/runtime/PWNED`.

## The chroot guard's error path

`systemctl enable` does not work without systemd as PID 1, so the chroot step creates the wants symlink directly. systemd **silently ignores** a wants symlink whose target unit is missing -- same silent-no-op family -- so the step first checks `/etc/systemd/system/arlowe-identity-init.service` exists (installed earlier by `units/install-units.sh`, 01-runtime step 4) and exits 1 naming that path if it does not. The check runs *before* `install -d` and `ln -sf`, so a failed run leaves nothing behind. Demonstrated by deleting the unit and re-running: exit 1, path named, no symlink.

## CLI symlink

`identity` added to the `CLIS` array in `install-arlowe-cli.sh` -- the **bare** name, because the file is `runtime/cli/identity` and the installer links `arlowe-${cli} -> ${TARGET_DIR}/${cli}`. The one file that ever carried the prefix in its own name (`runtime/cli/arlowe-ab`) pointed `arlowe-ab` at a nonexistent `cli/ab` and made SC3 untestable for months (F7 #21).

Resolution was checked **with the rootfs prefix** -- inside the container, where `/` is the rootfs -- not by resolving an absolute link against the build host, which is the bad test that produced a false DANGLING alarm in Phase 6.

The installer's header still claimed transient dangling symlinks were "expected"; it now records that the symlink step runs after the runtime rsync so the existence check has something to check.

## Deviations from Plan

### 1. [Rule 2 - Missing Critical] `python3-yaml` and `python3-jsonschema` were never in the image

`runtime/cli/identity` imports `arlowe_cloud` -> `arlowe_config` -> `yaml`, `jsonschema` at module scope. Neither package was in `pi-gen/stage-arlowe/00-packages/00-packages-nr`. They were installed on the CI host and in the CI test container only, so every green Phase 7 test run was green against an environment the built image does not have.

On hardware, `arlowe-identity init` would have died at import with `ModuleNotFoundError` before reaching a line of its own code -- `arlowe-identity-init.service` failing on **every** factory device, SC2 unreachable. Found by installing exactly what `00-packages-nr` declares into the verification container instead of a convenient set; the first two runs died on `requests` and then `jsonschema`.

Both added. `build-image.sh` asserts every declared package is `install ok installed` in the built rootfs, so this is now verified by the image build rather than assumed. Commit `5a67b27`.

### 2. [Rule 1 - Bug] Docker testbeds pre-staged a hardcoded CLI list

`tests/phase-{3,4}/docker/run-tests.sh` copied eight named files into `/opt/arlowe/runtime/cli` before invoking `install-arlowe-cli.sh`. That list has been stale since `runtime/cli/ab` landed, and the installer hard-fails on a missing target -- so both testbeds were already failing for a reason that was not a bug, and `identity` would have looked like more of the same. Now copies whatever `runtime/cli/` holds. Commit `2830a5b`.

Neither testbed runs in CI (`pr-checks.yml` shellchecks a fixed path list that excludes `tests/`), which is why the staleness went unnoticed. Worth a phase-8 ticket.

## Verification

| Check | Result |
| --- | --- |
| `systemd-analyze verify` on the installed unit (bookworm 252.39, populated rootfs) | clean |
| `grep '^Condition'` on the unit | 0 matches |
| `UMask=0077` / `RequiresMountsFor=/var/lib/arlowe` / `RestrictAddressFamilies=AF_UNIX` | present |
| `shellcheck` on both edited shell scripts | clean |
| `bash scripts/sanitize/check.sh` | 0 (254 files, 11 units) |
| `bash tests/phase-7/test-identity-store-check.sh` | all cases pass |
| Scratch-rootfs: symlink resolves, guard fires, exit 5, 0600 modes | 15/15 pass |
| Real systemd: enabled, starts, succeeds, fails loudly when store absent | pass |
| Net diff vs. base (excluding this file) | +129 lines |

`systemd-analyze verify` needs the referenced binaries to exist, so it is only meaningful against a populated rootfs -- run against a bare container it reports the same "not executable" noise for `arlowe-face.service`. Both were checked so the clean result is attributable to the unit, not the environment.

## Next Phase Readiness

07-09 can assert SC2 end-to-end: the unit is enabled, offline, and produces device-id + key + CSR at 0600. Phase 8's pairing daemon calls `arlowe-identity provision` against the same store this unit seeds.

**Concern for 08:** the six runtime units run under `/opt/arlowe/venvs/*/bin/python`, and `/opt/arlowe/venvs` is empty on the built image. This plan's unit dodges that by using system `python3`, but the venv gap is still open and will bite whoever starts those units first.

**Concern for 08:** neither Docker testbed runs in CI, so the pre-stage bug above lived undetected. Same class as "no CI pytest job" already tracked.
