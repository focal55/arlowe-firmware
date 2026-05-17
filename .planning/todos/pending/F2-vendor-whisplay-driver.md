# F2 — Vendor WhisPlay driver into Phase 6 image

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
