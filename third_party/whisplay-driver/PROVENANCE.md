# WhisPlay Driver Provenance

Investigated: 2026-05-02
Research reference: `.planning/phases/01-runtime-extraction/01-RESEARCH.md` §R3

---

## Pinned upstream (authoritative)

`WhisPlay.py` and `LICENSE` are committed in this directory, byte-identical to upstream,
and verified by `scripts/verify-third-party.sh` (check 4) against the values below. The
rationale, license analysis, update procedure and audit checklist are in
[ADR-0014](../../docs/architecture/0014-vendor-whisplay-driver.md).

Upstream: https://github.com/PiSugar/Whisplay (`Driver/WhisPlay.py`, and `LICENSE` at the repo root)

The values on the three lines below are machine-read (check 4 and
`tests/phase-8/test-whisplay-vendored.sh`); keep each alone on its line.

upstream-commit: bde2b831633de28981129a46826f0357aaec695b
sha256 WhisPlay.py: c7a3a04415847fb569d6ef9ac1bdd98349dab93e0e5ec9e567cb125180865169
sha256 LICENSE: c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4

The vendored `WhisPlay.py` is upstream at that commit, unmodified. It is the same file that
ran on the project's hardware from Phase 6 through 2026-09-30, which previously lived outside
the repo. Upstream has since removed `Driver/WhisPlay.py` and moved to a gpiod-based driver;
the pin deliberately stays on the last `RPi.GPIO`-era file (see ADR-0014).

The sections below are the original Phase 1 investigation notes and are historical where they
conflict with this section.

---

## Source

**Vendor:** PiSugar (https://pisugar.com)
**Product:** PiSugar Whisplay Hat
**GitHub:** https://github.com/PiSugar/Whisplay
**Clone command used on arlowe-1:**
```
git clone https://github.com/PiSugar/Whisplay.git --depth 1
```
**Files from the repo on arlowe-1 (`~/Library/Whisplay/Driver/`):**
- `WhisPlay.py` — the Python driver class (`WhisPlayBoard`); wraps SPI LCD, RGB LED, and button GPIO via `RPi.GPIO` and `spidev`
- `install_wm8960_drive.sh` — shell script that enables SPI/I2S/I2C in `/boot/firmware/config.txt`, installs kernel modules (`snd-soc-wm8960`, `snd-soc-wm8960-soundcard`), and sets up the WM8960 audio HAT systemd service
- `WM8960-Audio-HAT.zip` / `WM8960-Audio-HAT/` — Waveshare-sourced audio HAT driver files unpacked by the install script
- Docs: `README.md`, `README_CN.md`, `LICENSE`

The audio HAT installer (`install_wm8960_drive.sh`) notes that the WM8960 driver source is provided by Waveshare; it is bundled with the Whisplay repo but is Waveshare IP.

---

## License

The Whisplay repository (`~/Library/Whisplay/LICENSE`) is **Apache License, Version 2.0**.

This license permits:
- Reproduction and distribution in source or object form
- Modification and derivative works
- Sublicensing

Required obligations when distributing:
- Include a copy of the Apache 2.0 license
- Retain copyright, patent, trademark, and attribution notices
- Modified files must carry prominent notices of changes

The WM8960 audio HAT component (Waveshare-sourced) does not carry a separate license file in the bundled copy. Waveshare's general open-source hardware policy releases driver code under permissive terms, but this specific bundle is not independently licensed in the copy on arlowe-1. This is not a blocker for Phase 1 (driver is already installed system-wide); it is a question for Phase 6 (image build).

---

## Files needed at runtime

For `face.py` to import `WhisPlayBoard` successfully:
- `WhisPlay.py` — the Python class file (the only Python import)
- `RPi.GPIO` Python package. On Pi 5 this is supplied by apt `python3-rpi-lgpio`, an API-compatible
  shim over lgpio, NOT by apt `python3-rpi.gpio`: RPi.GPIO 0.7.1 predates BCM2712 and raises
  `RuntimeError: Cannot determine SOC peripheral base address` at `GPIO.setup()` even with the
  HAT attached. The module name is unchanged, so `WhisPlay.py` itself is not modified.
- `spidev` Python package (from `python3-spidev` or pip)

The audio kernel modules (`snd-soc-wm8960`, `snd-soc-wm8960-soundcard`) are required for audio output from the Whisplay HAT but are not needed for face rendering alone.

---

## Vendoring decision

**Decision: (a) Vendor `WhisPlay.py` under `third_party/whisplay-driver/`.**

Rationale:
- Apache 2.0 license explicitly permits redistribution in source form with attribution.
- `WhisPlay.py` is a small, self-contained file (~300 lines) with no compiled components.
- Vendoring removes the runtime dependency on `git clone` or a network fetch at boot.
- The WM8960 audio HAT component is **not** vendored here — it is installed by `install_wm8960_drive.sh` as a system-level kernel module operation, which belongs in the image build (Phase 6), not in this Python package.

Vendoring is complete: see the pinned values above and ADR-0014.

---

## Phase 1 implication

The Phase 1 smoke test on arlowe-1 is **unaffected** by this vendoring decision. The driver is already installed system-wide at `~/Library/Whisplay/Driver/WhisPlay.py`, and the `ARLOWE_WHISPLAY_DRIVER_PATH` env var can point at that path for dev use:

```bash
export ARLOWE_WHISPLAY_DRIVER_PATH=/home/focal55/Library/Whisplay/Driver
```

The vendoring decision affects Phase 6 (image build): a clean Pi image will not have the driver pre-installed, so the image build must either fetch it from the GitHub repo or copy it from `third_party/whisplay-driver/`.

---

## Action items

1. Done: `WhisPlay.py` and `LICENSE` are vendored and hash-pinned (ADR-0014).
2. Confirm Waveshare WM8960 HAT driver redistribution rights before including `WM8960-Audio-HAT.zip` in the image build. Waveshare's standard policy is permissive, but check the specific bundle's terms.
3. Add `ARLOWE_WHISPLAY_DRIVER_PATH` to the dev environment documentation so contributors know to set it on non-image environments.
4. The audio HAT install (`install_wm8960_drive.sh`) should be added to the Phase 6 image build script (`image/scripts/install-audio-hat.sh`), not run manually.
