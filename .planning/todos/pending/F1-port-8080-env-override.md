# F1 — face_service.py port 8080 env override

**Origin:** Plan 13 (Phase 1 smoke test), Task 4 iteration 2 verify-start. Surfaced because the runtime-extracted `runtime/face/face_service.py` couldn't run in parallel with the live `arlowe-face` service — they both bind tcp/8080.

**Target phase:** Phase 2 (sanitization gate) OR Phase 5 (audio device auto-detection, since that already touches device-config env vars). Most natural fit is Phase 2 — config-driven values is the sanitization theme.

## Problem

`runtime/face/face_service.py:179` (approximate) does something like `HTTPServer(('0.0.0.0', 8080), ControlHandler)` with the port literal. No env-var override. This means:
- Test runtime can't run alongside live runtime on the same host (port collision).
- Future multi-instance / dev / staging variants can't co-exist.
- Phase 6 image-build can't easily relocate the face service if needed.

## Fix shape

Mirror the pattern already established for other paths in `runtime/face/face.py`:

```python
FACE_CONTROL_PORT = int(os.environ.get("ARLOWE_FACE_CONTROL_PORT", "8080"))
# ... later:
server = HTTPServer(('0.0.0.0', FACE_CONTROL_PORT), ControlHandler)
```

Acceptance:
- Default behavior unchanged (still 8080 if env unset).
- Test environment can set the env to e.g. 8090 and run alongside live.
- Update `runtime/face/README.md` to document the env var.

## Effort estimate

~10 LOC change, single file. ~30min including a test that exercises the override.

## Cross-references

- Plan 13 SUMMARY: `.planning/phases/01-runtime-extraction/01-13-SUMMARY.md` deferred-followups F1
- Plan 13 test-units README: `.planning/phases/01-runtime-extraction/test-units/README.md`
- Pattern reference: `runtime/face/face.py:19-24` (the WhisPlay env-var hook)
