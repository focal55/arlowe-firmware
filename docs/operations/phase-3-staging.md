# Phase 3 staging harness — operations record

## Overview

Phase 3's SC4 requirement reads: *"a test on the dev image verifies that the
runtime cannot write outside `/var/lib/arlowe/`."* The Docker testbed validated
SC1–SC4 synthetically; this harness closes the **real-hardware** gap without a
full Phase 6 image build, by installing the production Phase 3 provisioning under
a parallel `arlowe-staging` user on the dev Pi — side-by-side with the live
daily-driver (`focal55`) setup, which it never touches — exercising SC4 against
real systemd, then tearing the staging user down.

It relates forward to Phase 6 (image build consumes plans 01–04 as a pi-gen
stage) and Phase 12 (first-flash integration inherits the SC1–SC4 suite).

## Procedure

1. **SSH prereq:** alias `arlowe-1` with key auth (override host via
   `ARLOWE_STAGING_HOST`).
2. **Daily-driver face service:** the harness does **not** require stopping it.
   The plan/README list a `systemctl --user stop arlowe-face` prereq so that
   `07-hardware-speculative.sh` can start the staging face service and `lsof` its
   gpiochip fds. On a pre-Phase-6 Pi the staging face service can't start anyway
   (no populated venv), so stopping the daily-driver buys nothing — and the
   gpiochip question is answerable directly from the running daily-driver face
   (it holds `/dev/gpiochip0`). The stop-prereq only becomes meaningful once a
   real runtime is populated (Phase 6+).
3. **Run:** from the repo root on the Mac, `bash tests/phase-3/staging/run-staging.sh`.
   Each phase's exit code is captured (not aborted on) so the full run is visible.
4. **Tear down:** `ssh arlowe-1 'sudo bash /tmp/arlowe-firmware/scripts/provision/uninstall-arlowe-on-arlowe1-staging.sh'`.

## Observed run — 2026-06-06

- Host: `arlowe-1` — Pi 5, Debian 13 (trixie), kernel `6.12.47+rpt-rpi-2712`,
  **systemd 257** (not Bookworm/systemd 252 — the plan assumed Bookworm; SC1–SC4
  behaviour was identical on trixie).
- Staging install: `arlowe-staging` uid=999, layout under `/opt/arlowe-staging`
  + `/var/lib/arlowe-staging`, six `*-staging.service` units, CLI symlinks, udev +
  polkit `-staging` rules. Clean.

**SC4 — sandbox write-deny (PASS, against real systemd):**

| Target | Result |
|---|---|
| `/var/lib/arlowe-staging/logs/face` (declared RW) | write OK |
| `/opt/arlowe-staging` | denied — Read-only file system |
| `/etc` | denied — Read-only file system |
| `/root` | denied — Permission denied |
| `/home/focal55` (founder home) | denied — Permission denied |

The founder home is unreachable from a service account under the production
sandbox directives. **SC4 is closed on real hardware.**

**SC2 — filesystem layout:** PASS, re-run via `ARLOWE_USER=arlowe-staging`
override with zero edits to the assertion. Confirms the env-var contract works
and Docker↔trixie layout parity holds.

**SC1 — user shape:** the user-shape sub-checks pass (uid=999 < 1000, HOME
`/var/lib/arlowe-staging`, shell `/usr/sbin/nologin`, groups present), but the
script exits non-zero on its bundled founder-absence check (`getent passwd
focal55 && fail`). That check is an **image-only sanitization assertion** and
cannot pass on the founder's own dev Pi. See follow-ups.

**Speculative groups / devices (research §12):**

| Question | Finding | Decision |
|---|---|---|
| `video` group needed? | `/dev/fb0` absent; WhisPlay is an SPI LCD (face holds `/dev/spidev0.0` + `/dev/gpiochip0`), not a framebuffer | **drop** |
| `audio` group needed? | `/dev/snd` present (`wm8960-soundcard` + 2× vc4-hdmi); voice uses ALSA | keep |
| `gpio` / `spi` needed? | face holds `/dev/gpiochip0` and `/dev/spidev0.0` | keep |
| `dialout` group needed? | only serial node is `/dev/ttyAMA10` (held by `agetty` console); WM8960 codec is I2C + in-kernel; voice holds no serial/tty/i2c fd | **drop** |
| gpiochip0 vs gpiochip4? | `/dev/gpiochip4` is a symlink → `gpiochip0`; `/dev/gpiomem` absent on this kernel; WhisPlay opens `gpiochip0` | narrow DeviceAllow to `gpiochip0`; the gpiomem udev line is a no-op here |
| axcl deb conflict? | deb ships `/etc/udev/rules.d/axcl_host.rules` setting `axcl_host`/`ax_mmb_dev` to `0666 root:root`; it sorts **after** our `90-arlowe-axera.rules`, so the deb wins — our rule is inert on real hw, and `0666` is looser than our intended `0660 root:arlowe` | rename ours to sort last (`95-`/`99-`) or reconcile |

## Decisions for follow-up (Phase 4 cleanup)

1. Drop `video` and `dialout` from `install-arlowe-user.sh`; tighten the granted
   set to `{audio, gpio, spi}`. Update `01-user-shape.sh` group checks to match.
2. Narrow the gpiochip `DeviceAllow` in `units/arlowe-face.service` to
   `/dev/gpiochip0`; drop the dead `/dev/gpiomem` udev line.
3. Split the founder-absence check out of `01-user-shape.sh` into an image-only
   assertion so 01 is cleanly reusable by the staging harness.
4. Rename `90-arlowe-axera.rules` to sort after the axcl deb's `axcl_host.rules`
   (or reconcile the two), and decide whether `0666 root:root` on the NPU node is
   acceptable or should be tightened to `0660 root:arlowe`.

## Limits

- Staging shares hardware with the daily-driver, so the staging face service can't
  acquire the SPI/GPIO devices while the daily-driver face runs — and can't start
  at all pre-Phase-6 (no venv). The gpiochip-open question was answered from the
  daily-driver's live state, not the staging service.
- Staging units use remapped ports/names and are installed but not started (except
  the best-effort face probe), so production ports (3000/8080/…) are not exercised
  here — Phase 12 owns end-to-end port verification.
