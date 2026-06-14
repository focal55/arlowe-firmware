# WhisPlay Driver — Install Instructions

`WhisPlay.py` is the Python driver for the PiSugar Whisplay HAT
(SPI LCD, RGB LED, and button GPIO). It is **not committed to this repo** per
the existing `third_party/` strategy — obtain it from the upstream repo and
place it where the build expects it before running `scripts/verify-third-party.sh`
or the Phase 6 image build.

---

## License

**Apache License, Version 2.0** (PiSugar/Whisplay repository).

Required obligations when distributing or building into an image:
- Include a copy of the Apache 2.0 license text (the image build copies `LICENSE`).
- Retain copyright, patent, trademark, and attribution notices.
- Modified files must carry prominent notices of changes (we do not modify it).

Attribution: PiSugar (https://pisugar.com), https://github.com/PiSugar/Whisplay

---

## WM8960 Audio HAT note

The Whisplay repo bundles `WM8960-Audio-HAT.zip` (Waveshare-sourced audio HAT
driver). **Redistribution rights for this bundle are unresolved** — Waveshare's
general policy is permissive but no explicit license is present in the bundled copy.

**This is treated as fetch-at-build (not bundled):** `install_wm8960_drive.sh`
fetches/installs the kernel modules at image build time from the Waveshare or
PiSugar repo. `verify-third-party.sh` emits a WARNING about this (non-blocking)
so the image builder is aware. The WM8960 redistribution decision is tracked as
an open action — resolve before distributing a production image.

---

## Pinned upstream commit

The vendored `WhisPlay.py` must be sourced from this commit:

```
Repo:   https://github.com/PiSugar/Whisplay
Commit: (pin at first fetch — run: git -C <clone-dir> rev-parse HEAD)
```

On arlowe-1 (Phase 1 dev unit), the driver was cloned at:

```bash
git clone https://github.com/PiSugar/Whisplay.git --depth 1
```

The exact commit SHA used on arlowe-1 is available via:

```bash
ssh arlowe-1 'git -C ~/Library/Whisplay rev-parse HEAD'
```

Record the commit SHA in this file when the Phase 6 image build (06-06) pins it.

---

## How to obtain

```bash
git clone https://github.com/PiSugar/Whisplay.git /tmp/whisplay-src
# Note the commit:
git -C /tmp/whisplay-src rev-parse HEAD
```

---

## Where to place the files

The verify script checks these locations in order (for `WhisPlay.py`):

1. `$ARLOWE_WHISPLAY_SRC/WhisPlay.py` (env var override — set for CI or custom paths)
2. `third_party/whisplay-driver/WhisPlay.py` (repo-relative, not committed)
3. `/var/cache/arlowe-build/whisplay-driver/WhisPlay.py` (default build cache)

Both `WhisPlay.py` and `LICENSE` must be present for the check to pass.

```bash
# Option A: set the env var
export ARLOWE_WHISPLAY_SRC=/tmp/whisplay-src
# Files expected at: $ARLOWE_WHISPLAY_SRC/WhisPlay.py
#                    $ARLOWE_WHISPLAY_SRC/LICENSE

# Option B: repo-relative (never commit the .py itself — .gitignore covers it)
cp /tmp/whisplay-src/WhisPlay.py third_party/whisplay-driver/
cp /tmp/whisplay-src/LICENSE     third_party/whisplay-driver/

# Option C: default cache location
sudo mkdir -p /var/cache/arlowe-build/whisplay-driver
sudo cp /tmp/whisplay-src/WhisPlay.py /var/cache/arlowe-build/whisplay-driver/
sudo cp /tmp/whisplay-src/LICENSE     /var/cache/arlowe-build/whisplay-driver/
```

---

## Verification

After placing the files, run:

```bash
scripts/verify-third-party.sh
```

Expected output on success:

```
[OK]   WhisPlay.py                                        present (Apache 2.0)
[WARN] WM8960 audio HAT redistribution rights unresolved — fetch-at-build; not bundled
```

Expected output when files are missing:

```
[FAIL]  third_party/whisplay-driver/WhisPlay.py  not found
  See third_party/whisplay-driver/INSTALL.md for sourcing instructions.
```

---

## On arlowe-1.local (Phase 1 dev unit)

The driver is already present at `~/Library/Whisplay/Driver/WhisPlay.py`.
For dev use, set:

```bash
export ARLOWE_WHISPLAY_SRC=/home/focal55/Library/Whisplay/Driver
```

The Phase 6 image build (06-03) copies it from the verified location into the
image at `/opt/arlowe/third_party/whisplay-driver/`.
