# WhisPlay Driver

`WhisPlay.py` is the Python driver for the PiSugar Whisplay HAT
(SPI LCD, RGB LED, and button GPIO). It is **committed to this repo** together with the
upstream Apache-2.0 `LICENSE`, byte-identical to upstream at a pinned commit. Nothing needs to
be fetched or placed by hand before running `scripts/verify-third-party.sh` or the image build.

The pin (upstream commit and the sha256 of both files) is recorded in `PROVENANCE.md`. The
reasons, license analysis, update procedure and audit checklist are in
[ADR-0014](../../docs/architecture/0014-vendor-whisplay-driver.md).

---

## License

**Apache License, Version 2.0** (PiSugar/Whisplay repository).

- The image build copies `LICENSE` to `/opt/arlowe/third_party/whisplay-driver/LICENSE`.
- Copyright, patent, trademark, and attribution notices are retained (the file is unmodified).
- Modified files must carry prominent notices of changes; we do not modify it.

Attribution: PiSugar (https://pisugar.com), https://github.com/PiSugar/Whisplay

---

## WM8960 Audio HAT note

The Whisplay repo bundles `WM8960-Audio-HAT.zip` (Waveshare-sourced audio HAT
driver). **Redistribution rights for this bundle are unresolved**, so it is not vendored.
`install_wm8960_drive.sh` and `WM8960-Audio-HAT*` stay gitignored and are fetched at image
build time. `verify-third-party.sh` emits a non-blocking WARNING about this. Resolve the
redistribution question before distributing a production image.

---

## Verification

```bash
scripts/verify-third-party.sh
```

Expected output on success:

```
[OK]   WhisPlay WhisPlay.py                               sha256 matches PROVENANCE.md
[OK]   WhisPlay LICENSE                                   sha256 matches PROVENANCE.md
```

The build fails if either file is missing or differs from the recorded hash. To change the
pinned version, follow the update procedure in ADR-0014.
