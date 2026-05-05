---
phase: 01-runtime-extraction
plan: 10
type: summary
status: complete
---

# Plan 10 Summary: Extract sanitized CLI helpers to runtime/cli/

## Helpers extracted

| Helper | Source LOC | Destination | Notes |
|---|---|---|---|
| `face` | 27 | `runtime/cli/face` | Clean; no sanitization needed beyond header tweak |
| `speak` | 41 | `runtime/cli/speak` | Parameterized Piper paths; `plughw:2,0` TODO(phase-5) |
| `stt` | 14 | `runtime/cli/stt` | `plughw:2,0` TODO(phase-5) |
| `record` | 7 | `runtime/cli/record` | `plughw:2,0` TODO(phase-5) |
| `boot-check` | 60 | `runtime/cli/boot-check` | High sanitization; see below |
| `purge-logs` | 25 | `runtime/cli/purge-logs` | Log path parameterized |
| `run-logrotate` | 3 | `runtime/cli/run-logrotate` | Config path parameterized; state path moved to `/var/lib/arlowe/` |
| `wake-train` | 23 | `runtime/cli/wake-train` | Wake-word dir and venv parameterized |

Total extracted: ~200 LOC across 8 scripts.

## Sanitization edits per script

**`boot-check`** (highest priority):
- Deleted `check_service openclaw-gateway "OpenClaw Gateway"` line entirely
- Deleted `check_port 18789 "OpenClaw Gateway API"` line entirely
- Parameterized systemctl via `ARLOWE_SYSTEMCTL_FLAGS` env var (default `--user`)
- Added `arlowe-dashboard` service check (product service)
- Added port 3000 check for dashboard
- Stripped decorative emoji characters (not appropriate for machine-parseable output)

**`speak`**:
- `~/models/piper/piper` replaced with `${PIPER_BIN:-/opt/arlowe/runtime/tts/bin/piper}`
- `~/models/piper-voices/en_US-lessac-medium.onnx` replaced with `${PIPER_VOICE:-/opt/arlowe/models/piper-voices/en_US-lessac-medium.onnx}`
- `plughw:2,0` left in place with `# TODO(phase-5)` comment
- Header stripped device-specific label

**`purge-logs`**:
- `$HOME/whisplay/logs` replaced with `${ARLOWE_LOGS_DIR:-/var/lib/arlowe/logs}`

**`run-logrotate`**:
- `~/.config/logrotate/arlowe.conf` replaced with `${ARLOWE_LOGROTATE_CONF:-/opt/arlowe/runtime/cli/logrotate.conf}`
- logrotate state file moved from `~/.config/logrotate/status` to `/var/lib/arlowe/logrotate.status`

**`wake-train`**:
- `cd ~/wake_word` replaced with `cd "${ARLOWE_WAKE_WORD_DIR:-/opt/arlowe/runtime/wake-word}"`
- `python3` replaced with `"${ARLOWE_VENV:-/opt/arlowe/venv}/bin/python3"` throughout

**`stt`**, **`record`**: `plughw:2,0` left in place with `# TODO(phase-5)` comment.

**`face`**: No sanitization required; clean as-is.

## Excluded helpers

| Helper | Reason |
|---|---|
| `wifi-watchdog` | Hardcodes founder home Wi-Fi SSID literal; dashboard `/api/connectivity/*` routes replace the functionality |
| `iol-sync` | Personal founder tool; out of scope per `docs/04-scope.md` |
| `usage-stats` | Personal founder tool; out of scope per `docs/04-scope.md` |
| `stats` | Personal founder tool; out of scope per `docs/04-scope.md` |

## Artifacts created

- `runtime/cli/face` — executable, 25 LOC
- `runtime/cli/speak` — executable, 44 LOC (sanitized)
- `runtime/cli/stt` — executable, 16 LOC (sanitized)
- `runtime/cli/record` — executable, 9 LOC (sanitized)
- `runtime/cli/boot-check` — executable, 58 LOC (sanitized, seed for Phase 11 BOOT-01)
- `runtime/cli/purge-logs` — executable, 27 LOC (sanitized, seed for Phase 11 LOG-02)
- `runtime/cli/run-logrotate` — executable, 9 LOC (sanitized)
- `runtime/cli/wake-train` — executable, 39 LOC (sanitized)
- `runtime/cli/logrotate.conf` — minimal default config (written fresh; not present on Pi stash)
- `runtime/cli/README.md` — 50 LOC helpers index, env knobs, exclusion rationale

## Open TODOs for future phases

**Phase 5 (audio auto-detection):**
- `runtime/cli/record`: replace `plughw:2,0` with auto-detected device
- `runtime/cli/stt`: same
- `runtime/cli/speak`: same
- `runtime/cli/boot-check`: same

**Phase 11 (system units / image build):**
- `runtime/cli/boot-check`: flip `ARLOWE_SYSTEMCTL_FLAGS` from `--user` to empty for system-level units

## EXTRACT-08 status

Complete. All acceptance criteria met.
