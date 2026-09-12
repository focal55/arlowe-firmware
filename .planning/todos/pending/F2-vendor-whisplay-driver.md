# F2 — Vendor WhisPlay driver into Phase 6 image

**UPDATE 2026-07-08 — checkpoint-unblocked, provenance gap OPEN.** The verify gate needs BOTH `WhisPlay.py` AND an Apache-2.0 `LICENSE` co-located in the source dir; the dev-unit dir had only the `.py`. For the checkpoint build we staged `~/whisplay-staging/{WhisPlay.py,LICENSE}` on arlowe-1 (dev-unit driver + LICENSE fetched from a fresh PiSugar/Whisplay clone) and verify went green. **Provenance is unresolved:** the proven dev-unit `WhisPlay.py` is 344 lines and DIFFERS MATERIALLY from upstream HEAD (`30df9903f6368da3486ff87ef94843228653899f`, `runtime/whisplay.py`, 662 lines) — the dev copy is an older/possibly-modified version with no change-notice header. We deliberately shipped the *proven* driver into the checkpoint image (Whisplay display is deferred in this checkpoint, so the driver isn't exercised) rather than 431 untested upstream lines. Before ANY distributable image: decide upstream-HEAD vs. pinned-older-commit, record the true SHA in `third_party/whisplay-driver/INSTALL.md` (currently an unrecorded placeholder), and file the Apache-2.0 provenance ADR. INSTALL.md's "pinned commit" was never actually pinned.

**STATUS 2026-06-19 — CONFIRMED OPEN, ACTIVE BLOCKER.** This was assumed satisfied by plan 06-03, but the first-ever image build (Phase 6 hardware checkpoint) proved otherwise: `scripts/verify-third-party.sh` hard-FAILs with "WhisPlay.py not found" and gates the build. The vendoring step copies from a fetch-at-build source dir (`ARLOWE_WHISPLAY_SRC` or `third_party/whisplay-driver/WhisPlay.py`), and that staging was never wired/run. On resume: stage `~/Library/Whisplay/Driver/WhisPlay.py` (verify it matches the PiSugar/Whisplay commit pinned in `third_party/whisplay-driver/INSTALL.md`), then re-run verify green before building.

**Origin:** Plan 13 (Phase 1 smoke test), Task 4 iteration 2. The runtime-extracted `runtime/face/face.py:14-24` honors `ARLOWE_WHISPLAY_DRIVER_PATH` (default `/opt/arlowe/third_party/whisplay-driver`) but the default path doesn't exist on arlowe-1 — the driver still lives at the founder's `~/Library/Whisplay/Driver/WhisPlay.py`.

**Target phase:** Phase 6 (image build with A/B partitions). Already in scope by ROADMAP §Phase-6 — this is just the explicit Phase-6 task for it.

## Problem

WhisPlay is a single-file Python module (`WhisPlay.py`) from PiSugar (Apache 2.0 — see `docs/architecture/0001-iol-router-extraction.md` decision log). Until Phase 6 vendors it into the image at `/opt/arlowe/third_party/whisplay-driver/`, every dev/test environment has to set `ARLOWE_WHISPLAY_DRIVER_PATH` manually.

## Fix shape

In Phase 6's image-build pipeline:

1. Add a vendoring step that copies the WhisPlay driver source into `third_party/whisplay-driver/` in the repo (vendoring at image build time, NOT committed to git per the existing `third_party/` pattern in Plan 09).
2. Image build copies `third_party/whisplay-driver/` to `/opt/arlowe/third_party/whisplay-driver/` on the target.
3. Update `runtime/face/README.md` to note that production deployments don't need the `ARLOWE_WHISPLAY_DRIVER_PATH` env var — Phase-6 vendored path is the default.

Acceptance:
- Fresh-flashed image has `/opt/arlowe/third_party/whisplay-driver/WhisPlay.py`.
- `runtime/face/face_service.py` starts cleanly on the image WITHOUT setting `ARLOWE_WHISPLAY_DRIVER_PATH`.
- License + provenance recorded in `docs/architecture/` ADR (the PiSugar Apache-2.0 decision).

## Effort estimate

Small — fits inside whatever Phase 6 plan handles `third_party/` vendoring. Maybe 1-2hr including the provenance ADR.

## Cross-references

- Plan 13 SUMMARY: F2
- Phase 6 ROADMAP §Phase 6 — image build pipeline
- Plan 09 (third_party manifest pattern): `.planning/phases/01-runtime-extraction/09-PLAN.md`
- Runtime hook already in place: `runtime/face/face.py:14-24`
- Driver source: `/home/focal55/Library/Whisplay/Driver/WhisPlay.py` (current location)
