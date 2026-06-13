---
phase: 05-audio-device-auto-detection
plan: 06
type: summary
status: complete
pr: pending
---

# 05-06 Summary: Boot-check capture+playback sentinel

## What was built

- `selfcheck()` function in `runtime/lib/arlowe_audio.py` — capture RMS + playback tone sentinels with retry, JSON persistence, and `[arlowe-audio]` journal line.
- `--selfcheck` CLI subcommand added to `_cli_main()` — exits 0 on both ok, exits 1 if either fails.
- `runtime/cli/boot-check` audio section replaced — hardcoded `plughw:2,0` probe gone; calls `python3 -m arlowe_audio --selfcheck` instead.
- `runtime/lib/tests/test_arlowe_audio_selfcheck.py` — 38 tests, all green; no real audio hardware invoked.

## JSON status contract (Phase 11 consumer)

File: `/var/lib/arlowe/state/audio-selfcheck.json`

```json
{
  "check": "audio",
  "capture": {
    "device": "plughw:1,0",
    "ok": true
  },
  "playback": {
    "device": "plughw:1,0",
    "ok": false,
    "error": "<error message>"
  },
  "ts": "2026-06-13T12:00:00Z"
}
```

Keys:
- `check`: always `"audio"` (type discriminant for Phase 11 parser)
- `capture.device`: resolved plughw string, or `null` if no device found
- `capture.ok`: true = RMS above floor; false = silent buffer or exception
- `capture.error`: error description when ok=false; absent when ok=true
- `playback.device`: resolved plughw string, or `null` if no device found
- `playback.ok`: true = playback command exited 0; false = exception
- `playback.error`: error description when ok=false; absent when ok=true
- `ts`: ISO 8601 UTC timestamp of the check

Write semantics: atomic temp+rename in the same directory (mirrors Phase 4 convention). If the directory is unwritable, a WARN is emitted to stderr and the check continues without crashing.

## Journal line format

Emitted to stderr with `[arlowe-audio]` prefix (greppable pattern for journald):

```
[arlowe-audio] selfcheck capture=ok device=plughw:1,0 playback=FAIL device=plughw:0,0
```

Pattern for log grep: `grep '\[arlowe-audio\]'`

## Retry / floor choices

- **Retries**: 3 attempts per sentinel with 1 s sleep between (devices settle after USB enumeration).
- **RMS floor**: 10.0 — forgiving; plughw resampling can produce quiet but non-zero buffers; all-zero silence fails cleanly. Hardware-deferred calibration in 05-07.
- **Capture sentinel**: arecord S16_LE 16 kHz mono 1 s → RMS check.
- **Playback sentinel**: sox synth 0.3 sine 440 piped to aplay; success = exit 0 (no acoustic loopback — locked CONTEXT decision).

## WARN vs FAIL in boot-check

The old mic probe used `WARN`. The selfcheck follows the same idiom: audio failure emits `WARN` and does NOT increment `FAIL`. Rationale: functional-degraded over hard block (locked CONTEXT decision); a transient audio miss should not read as system-down.

## Deferred to 05-07

- Real RMS assertion on hardware: confirming non-silent buffers actually record audio (not just driver headers).
- Real tone-plays assertion: confirming aplay exits 0 on hardware.
- Boot-time run-user and `/var/lib/arlowe/state/` writability under the actual systemd unit context (research P9, Open Q4).
