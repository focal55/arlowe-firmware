---
phase: 03-service-user-and-filesystem-layout
plan: 05
status: complete
closure: passed-with-notes
provides:
  - Phase 3 SC4 closure — real-hardware sandbox write-deny verified on arlowe-1 against arlowe-staging under real systemd 257 (positive RW + 4 negative denials incl. founder home). Observed run 2026-06-06; see docs/operations/phase-3-staging.md.
  - Resolution of speculative groups — video and dialout confirmed UNUSED on real hardware (no /dev/fb0; WM8960 codec is I2C/in-kernel, only serial node is the agetty console). Granted set should tighten to {audio, gpio, spi} in Phase 4.
  - gpiochip enumeration resolved — /dev/gpiochip4 is a symlink to gpiochip0, /dev/gpiomem absent on the 6.12 rpt kernel; WhisPlay opens gpiochip0. DeviceAllow can narrow to gpiochip0.
  - Axera udev rule conflict CONFIRMED — the axcl deb ships /etc/udev/rules.d/axcl_host.rules (0666 root:root) that sorts after and overrides our 90-arlowe-axera.rules; ours is inert on real hardware.
  - arlowe-1 staging harness — install/uninstall scripts + 06 (SC4) + 07 (hardware) assertion scripts; reusable for re-verification after Phase 4-6 changes touching user/layout/units.
  - Env-var contract on plan 01/02 assertions verified in a production-like setting — 02-fs-layout.sh re-targets cleanly via ARLOWE_USER override (zero edits); 01-user-shape.sh's bundled founder-absence check is image-only and cannot pass on the dev Pi.
affects:
  - Phase 4 (config overlay) — pick up cleanups: drop video+dialout groups, narrow gpiochip DeviceAllow, split founder-absence out of 01-user-shape.sh, rename 90-arlowe-axera.rules to sort after the axcl deb.
  - Phase 6 (image build) — consumes plans 01-04 install scripts as a pi-gen stage; consumes the group-narrowing + axcl-rule-ordering decisions recorded here.
  - Phase 12 (first-flash integration) — inherits the SC1-4 assertion suite for the real-hardware closure gate.
files_written:
  - scripts/provision/install-arlowe-on-arlowe1-staging.sh
  - scripts/provision/uninstall-arlowe-on-arlowe1-staging.sh
  - tests/phase-3/staging/run-staging.sh
  - tests/phase-3/staging/06-sandbox-write-deny.sh
  - tests/phase-3/staging/07-hardware-speculative.sh
  - tests/phase-3/staging/README.md
  - docs/operations/phase-3-staging.md
  - .sanitize-allowlist
---

## What landed

A staging harness that runs the production Phase 3 provisioning under a parallel
`arlowe-staging` user on the real dev Pi, side-by-side with the `focal55`
daily-driver (never touched), then tears it down. It closes **SC4 on real
hardware** — the one Phase 3 success criterion the Docker testbed could only prove
synthetically.

**`install/uninstall-arlowe-on-arlowe1-staging.sh`** — the install sed-transforms
copies of the production user/fs/cli scripts (no edits to committed plans 01/02/04)
and transforms+renames the plan-03 udev/polkit rule files directly. Units are
prefix-renamed (`arlowe-face` → `arlowe-staging-face`, `qwen-api` →
`qwen-staging-api`, `whisper-stt` → `whisper-stt-staging`) so the polkit
`indexOf("arlowe-staging-")` grant matches. Hostname-scoped, refuses to coexist
with a production `arlowe` user. Uninstall is idempotent and restores the Pi.

**`tests/phase-3/staging/{run-staging,06-sandbox-write-deny,07-hardware-speculative}.sh`
+ README** — Mac-side runner (env-overrides plan 01/02 assertions onto the staging
tree), SC4 verifier via `systemd-run`, and the hardware/group probe.

## Verification — observed run 2026-06-06 (Pi 5, Debian 13, systemd 257)

- **SC4: PASS** against real systemd. Declared RW path writable; `/opt`, `/etc`,
  `/root`, `/home/focal55` all denied. Founder home unreachable from the sandbox.
- **SC2: PASS** via env override, zero assertion edits.
- **SC1:** user-shape sub-checks pass; the bundled founder-absence check fails on
  the dev Pi by design (focal55 is the login) — image-only, see follow-up.
- Tear-down verified clean: `arlowe-staging` gone, all staging units/trees/rules/
  symlinks removed, `focal55` + all 6 daily-driver services intact.

## Notes carried to Phase 4 (why this is passed-with-notes, not pass)

1. Drop `video` + `dialout` groups (both confirmed unused) → tighten to
   `{audio, gpio, spi}`; update 01's group checks.
2. Narrow gpiochip `DeviceAllow` to `/dev/gpiochip0`; drop the dead `/dev/gpiomem`
   udev line.
3. Split the founder-absence check out of `01-user-shape.sh` into an image-only
   assertion so 01 is reusable in staging without spurious failure.
4. Reorder `90-arlowe-axera.rules` after the axcl deb's `axcl_host.rules` (or
   reconcile) and decide whether `0666 root:root` on the NPU node is acceptable.

## Incidental fix

Added `tests/phase-3/assertions/05-cli-symlinks.sh` to `.sanitize-allowlist` — it
carries banned literals in a negative grep check (same rationale as `04-...`) but
shipped in plan 03-04 without the entry, leaving the sanitize gate red on main.
Worth checking why CI didn't block #71.
