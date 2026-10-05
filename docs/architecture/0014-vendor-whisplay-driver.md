# ADR-0014: Vendor the Whisplay display driver, pin it by hash, fail the build without it

<!-- status: accepted -->
**Status:** Accepted (project owner decision of 2026-10-05)
**Date:** 2026-10-05
**Phase:** 8 (First-boot pairing; image build)
**Issue:** #289

## Context

On 2026-10-05 the image built from commit `633c5d4` was found on hardware to contain no Whisplay
driver. `/opt/arlowe/third_party/whisplay-driver/` held only `PROVENANCE.md`: no `WhisPlay.py`
and no Apache-2.0 `LICENSE`. `arlowe-pair` crash-looped with
`ModuleNotFoundError: No module named 'WhisPlay'` (97 restarts), so no QR code was shown, and
`arlowe-face` imports the same module.

The build checked one source and installed from another:

- `scripts/verify-third-party.sh` check 4 resolved the driver from `$ARLOWE_WHISPLAY_SRC`, then
  `third_party/whisplay-driver/`, then `/var/cache/arlowe-build/whisplay-driver/`. It passed
  against a directory outside the repo.
- `pi-gen/stage-arlowe/01-runtime/00-run.sh` staged only the repo's `third_party/whisplay-driver/`.
- The chroot step in `00-run-chroot.sh` ("vendoring WhisPlay driver") printed
  `WARNING ... not found - skipping` and the build succeeded.
- Earlier builds passed only because a hand-placed, gitignored copy sat in the build host's
  checkout. A clean-clone sync removed it.
- The file was never hash-pinned. Check 4 tested presence, not content.

The repository also contradicted itself: `PROVENANCE.md` recorded "Decision: (a) Vendor
WhisPlay.py under third_party/whisplay-driver", while `INSTALL.md` and `.gitignore` said the
file is not committed.

## Decision

Commit `third_party/whisplay-driver/WhisPlay.py` and `third_party/whisplay-driver/LICENSE`,
byte-identical to upstream (`https://github.com/PiSugar/Whisplay`) at a named commit, and record
that commit and the sha256 of both files in `PROVENANCE.md`.

- `scripts/verify-third-party.sh` check 4 reads only the in-repo files and verifies both against
  the sha256 values in `PROVENANCE.md`. `ARLOWE_WHISPLAY_SRC` and the `/var/cache` fallback are
  removed.
- The vendoring step in `00-run-chroot.sh` fails the build (non-zero exit) when `WhisPlay.py` or
  `LICENSE` is missing. `README.md` and `PROVENANCE.md` remain optional.
- `.gitignore` no longer lists `WhisPlay.py` or `LICENSE`.

The vendored file is the file that ran on project hardware from Phase 6 through 2026-09-30
(sha256 `c7a3a04415847fb569d6ef9ac1bdd98349dab93e0e5ec9e567cb125180865169`, 344 lines). It is
byte-identical to upstream at the pinned commit.

### Deliberate divergence from upstream HEAD

Upstream removed `Driver/WhisPlay.py` in `a137810` (2026-05-10, "refactor: project structure")
and moved to `runtime/whisplay.py` (class `WhisplayBoard`, gpiod-based, with Orange Pi and Radxa
platform detection). Before that, `1a5e1b0` (2026-04-03) migrated the driver from `RPi.GPIO` to
gpiod.

We pin the last `RPi.GPIO`-era file because the image provides `RPi.GPIO` through
`python3-rpi-lgpio` and our code imports `WhisPlay.WhisPlayBoard`. Upstream HEAD's driver has a
different module name case, a different class name and a gpiod dependency the image does not
provision. Adopting it is a future port with its own tests, not a vendoring bump.

## Alternatives considered

1. **Out of repo, pinned by hash (keep the external source, add sha256 checks).** Rejected. It
   keeps the failure that caused the incident: a build that depends on a file on one host that a
   clean clone does not carry. A hash would make the build fail loudly instead of ship silently,
   but the build would still not be reproducible from the repository alone.
2. **Fetch from upstream at build time.** Rejected. It adds a network dependency to the image
   build, and the pinned commit lives in an upstream repository we do not control (history can be
   rewritten, the repository removed, and upstream already removed this path once). The file is
   about 340 lines with no compiled components, so the cost of vendoring is small.
3. **Status quo (check presence, warn in the chroot).** Rejected. It is the cause of the incident.
4. **Adopt upstream HEAD's gpiod driver now.** Rejected for this change. It requires changes to
   `face.py` and the image package set and needs its own tests and hardware validation. Tracked as
   a future port.

## License obligations

Upstream is licensed under the Apache License, Version 2.0, which permits reproduction and
distribution in source and object form. The obligations and how each is met:

| Obligation (Apache-2.0 section 4) | How it is met |
|---|---|
| Give recipients a copy of the License | `LICENSE` is committed and installed into the image at `/opt/arlowe/third_party/whisplay-driver/LICENSE`. The build fails if it is missing. |
| Retain copyright, patent, trademark and attribution notices | `WhisPlay.py` and `LICENSE` are unmodified and hash-pinned, so upstream notices are preserved. Attribution to PiSugar is also recorded in `PROVENANCE.md` and `INSTALL.md`. |
| Modified files carry prominent change notices | Not applicable: no modifications are made. Any future modification must add a change notice in the file and be recorded in `PROVENANCE.md`; the hash pin then no longer equals upstream, and this ADR must be updated. |
| Distribute any upstream NOTICE file | Upstream has no NOTICE file at the pinned commit. Re-check on each update. |

## Provenance

- Upstream: `https://github.com/PiSugar/Whisplay`
- Upstream paths: `Driver/WhisPlay.py` and `LICENSE` (repository root)
- Commit: `bde2b831633de28981129a46826f0357aaec695b` (2026-01-02, "new MP4 example", on upstream `main`)
- sha256 `WhisPlay.py`: `c7a3a04415847fb569d6ef9ac1bdd98349dab93e0e5ec9e567cb125180865169`
- sha256 `LICENSE`: `c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4`

The same values are recorded in `third_party/whisplay-driver/PROVENANCE.md`, which is the file the
build gate reads. A test (`tests/phase-8/test-whisplay-vendored.sh`) checks that this ADR and
`PROVENANCE.md` agree.

## Exclusions

The WM8960 audio HAT bundle (`WM8960-Audio-HAT.zip` and `install_wm8960_drive.sh`) is not
vendored. The bundle is Waveshare-sourced and carries no license file in the upstream copy, so
redistribution rights are unresolved. It stays fetch-at-build and gitignored
(`third_party/whisplay-driver/install_wm8960_drive.sh`, `third_party/whisplay-driver/WM8960-Audio-HAT*`).
`verify-third-party.sh` emits a non-blocking warning about it. Vendoring it requires a separate
decision once the rights are confirmed.

## Update procedure

1. Choose the target upstream commit. Note that upstream HEAD does not contain
   `Driver/WhisPlay.py` (see the divergence above); a bump to a commit that lacks it, or to a
   gpiod-based driver, is a port, not an update under this procedure.
2. Extract both files from a clone at that commit without modification:
   `git show <commit>:Driver/WhisPlay.py > third_party/whisplay-driver/WhisPlay.py` and
   `git show <commit>:LICENSE > third_party/whisplay-driver/LICENSE`.
3. Compute `sha256sum` of both files.
4. Update the `upstream-commit`, `sha256 WhisPlay.py` and `sha256 LICENSE` lines in
   `third_party/whisplay-driver/PROVENANCE.md`.
5. Update the Provenance section of this ADR with the same three values (the test enforces this)
   and record the reason for the change.
6. Check the new commit for a NOTICE file and for license changes.
7. Run `bash tests/phase-8/test-whisplay-vendored.sh` and `scripts/verify-third-party.sh`.
8. Validate on hardware: `arlowe-pair` shows the QR and `arlowe-face` renders.

## Audit checklist

Run from a clean checkout:

```bash
# 1. Committed hashes match PROVENANCE.md and this ADR
sha256sum third_party/whisplay-driver/WhisPlay.py third_party/whisplay-driver/LICENSE
grep -E '^(upstream-commit|sha256 )' third_party/whisplay-driver/PROVENANCE.md
grep -F -e bde2b831633de28981129a46826f0357aaec695b \
        -e c7a3a04415847fb569d6ef9ac1bdd98349dab93e0e5ec9e567cb125180865169 \
        -e c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4 \
        docs/architecture/0014-vendor-whisplay-driver.md

# 2. The files are byte-identical to upstream at the pinned commit
git clone https://github.com/PiSugar/Whisplay.git /tmp/whisplay-audit
git -C /tmp/whisplay-audit show bde2b831633de28981129a46826f0357aaec695b:Driver/WhisPlay.py \
  | sha256sum
git -C /tmp/whisplay-audit show bde2b831633de28981129a46826f0357aaec695b:LICENSE | sha256sum

# 3. The files are tracked, not ignored
git ls-files third_party/whisplay-driver
git check-ignore -v third_party/whisplay-driver/WhisPlay.py third_party/whisplay-driver/LICENSE  # no output

# 4. The build gate and the regression test pass
scripts/verify-third-party.sh
bash tests/phase-8/test-whisplay-vendored.sh

# 5. The image ships the LICENSE and the driver (mounted image root at $ROOT)
ls -l "$ROOT"/opt/arlowe/third_party/whisplay-driver/{WhisPlay.py,LICENSE}
sha256sum "$ROOT"/opt/arlowe/third_party/whisplay-driver/{WhisPlay.py,LICENSE}

# 6. The WM8960 bundle is absent from the repo and the image
git ls-files third_party/whisplay-driver | grep -i -e wm8960 && echo "UNEXPECTED"
find "$ROOT"/opt/arlowe/third_party/whisplay-driver -iname '*wm8960*'   # no output
```
