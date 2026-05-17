# F4 — Re-run plan 13 hybrid smoke test post-Phase-6

**Origin:** Plan 13 (Phase 1 smoke test). The plan was closed as passed-with-notes; the wake-phrase end-to-end loop was never actually exercised on hardware. The canonical test-unit files survive in `.planning/phases/01-runtime-extraction/test-units/`, so a clean re-run is cheap.

**Target:** A post-Phase-6 plan (Phase 7+ or a dedicated mini-plan). NOT Phase 12 — Phase 12 owns the fully-sanitized first-flash variant; F4 is the hybrid live/test variant that should have closed plan 13 cleanly.

## Why bother if Phase 12 covers it?

Phase 12 is the v1 ship-gate hardware integration test. It's heavy: factory-fresh Pi, no founder identity, all services from new tree. If Phase 12 fails, we lose information about whether the failure is in:
- The new `runtime/` tree code (would be caught by F4 cheaper)
- The image-build / partition layout (Phase 6)
- The pairing flow (Phase 8)
- The auto-detection / config overlay (Phases 4, 5)

F4 isolates the new-runtime-tree question. Cheap signal before the expensive Phase 12 gate.

## Prerequisites

- **F2** must land first (Phase 6 vendors WhisPlay). Without F2, F4 needs `ARLOWE_WHISPLAY_DRIVER_PATH` in the unit again — fine but defeats the "this should be production-shaped" intent.
- **F1** ideally lands first (port 8080 env override) so live face doesn't need to be stopped during the test — cleaner isolation.
- **F3** ideally lands first (persistent user journald on arlowe-1) so iteration is faster if a new bug surfaces.

If F1, F2, F3 are all in: F4 should be a one-shot pass.

## Fix shape

1. Use the canonical units in `.planning/phases/01-runtime-extraction/test-units/` as the starting point.
2. If F1 landed, remove the port-8080 override note from the smoke-test doc; if not, keep the live-face-stop step.
3. If F2 landed, remove the `ARLOWE_WHISPLAY_DRIVER_PATH` line from the face-test unit.
4. Re-stage on arlowe-1 (`/tmp/arlowe-runtime-test/`), start units, walk to Pi, speak phrase, observe, tear down.
5. Update `docs/operations/phase-1-smoke-test.md` `## Observed run` section with the actual result.
6. Close `.planning/phases/01-runtime-extraction/01-13-SUMMARY.md`'s "wake-phrase loop NOT exercised" note — or write a follow-up note recording the re-run result.

Acceptance:
- Wake → STT → LLM → TTS → face round-trip observed end-to-end at least once.
- STT transcript, LLM response text, and approximate round-trip time captured.
- Tear-down verified; live state preserved.

## Effort estimate

If F1+F2+F3 are in: ~30min plus 3min at the Pi.

If only F2 is in: ~1hr plus 5min at the Pi (still need live-face stop dance).

If none are in: don't bother — it's just re-running iteration 3 with the same iteration drag.

## Cross-references

- Plan 13 SUMMARY: F4 (this todo) + deferred follow-ups list
- Canonical test units: `.planning/phases/01-runtime-extraction/test-units/`
- Smoke-test doc: `docs/operations/phase-1-smoke-test.md`
- Plan 13 itself: `.planning/phases/01-runtime-extraction/13-PLAN.md`
- Phase 12 (the harder bigger test): ROADMAP §Phase 12
