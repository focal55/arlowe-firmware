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

## Decisions for follow-up (Phase 4 cleanup) — resolved 2026-06-07 (issues #73–#75)

1. **Done (#73, PR #76):** dropped `video` + `dialout` from `install-arlowe-user.sh`
   (granted set now `{audio, gpio, spi}`); `01-user-shape.sh` group checks updated.
2. **Won't-fix (#74):** the gpiochip `DeviceAllow` is intentionally NOT narrowed and
   the `gpiomem` line is kept. Narrowing removes no real privilege — a `DeviceAllow`
   for a symlinked/absent node grants access to nothing — and risks breaking face on
   a kernel that enumerates the RP1 bank differently (gpiochip4 was a symlink to
   gpiochip0 on one boot and absent on another). The misleading "primary GPIO bank"
   comment in `91-arlowe-gpio-spi.rules` was corrected instead.
3. **Done (#73, PR #76):** founder-absence check split into image-only
   `06-image-sanitization.sh`; `01` is now dev-Pi-reusable.
4. **Done (#75):** NPU nodes tightened to **`0660 root:arlowe`** on the image. The
   deb's `axcl_host.rules` turned out to be a packaging bug — an unsubstituted
   `GROUP="<users>"` placeholder + `0666`, which is the actual cause of the
   `root:root 0666` nodes. Rather than out-sort a broken rule by filename (which
   would also break the staging harness's `9X-` naming), `install-arlowe-udev-polkit.sh`
   removes the broken deb rule so `90-arlowe-axera.rules` governs; the rule now
   covers all four exposed nodes (`axcl_host`, `ax_mmb_dev`, `msg_userdev`, `p2p`).

   **Decision / risk-acceptance (Joe, 2026-06-07):** tighten to `0660 root:arlowe`
   on the production image. Residual accepted: (a) `root` and the `arlowe` service
   keep NPU access — required for the LLM; (b) the dev Pi keeps the deb's
   `0666 root:root` (the production installer is not run there, so the daily-driver
   LLM running as `focal55` is unaffected). Tightening costs no firmware
   functionality — the NPU consumer runs as `arlowe` — and removes the NPU driver's
   ioctl/DMA surface from non-`arlowe` local UIDs (defense-in-depth on a device
   running network-facing services).

   **Runtime verification deferred to Phase 6:** applying the winning rule on the dev
   Pi would re-own the NPU away from `focal55` and break the daily-driver LLM, so it
   can only be verified on a clean image (arlowe user, no daily-driver). This change
   is verified syntactically + by `04-udev-polkit-shape.sh` shape assertions.

## Limits

- Staging shares hardware with the daily-driver, so the staging face service can't
  acquire the SPI/GPIO devices while the daily-driver face runs — and can't start
  at all pre-Phase-6 (no venv). The gpiochip-open question was answered from the
  daily-driver's live state, not the staging service.
- Staging units use remapped ports/names and are installed but not started (except
  the best-effort face probe), so production ports (3000/8080/…) are not exercised
  here — Phase 12 owns end-to-end port verification.
