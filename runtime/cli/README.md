# runtime/cli — Operator CLI Helpers

Operator-facing shell scripts for verifying and interacting with the Arlowe on-device runtime. These are the primary verification path for the operator during development and post-boot checks.

## Helpers

| Helper | Purpose | Used by |
|---|---|---|
| `face` | Set face state via HTTP on port 8080 | Manual ops, smoke test |
| `speak` | Run TTS once via Piper with optional face sync | Manual ops, smoke test |
| `stt` | Record mic and transcribe via STT server on port 8082 | Manual ops, smoke test |
| `record` | Capture mic audio to a file (debug/sampling) | Debug, wake-word collection |
| `boot-check` | Post-boot service and hardware verification (seed for Phase 11 BOOT-01) | Operator, systemd oneshot |
| `purge-logs` | Delete stale logs by age; truncate oversized debug log (seed for Phase 11 LOG-02) | logrotate timer |
| `run-logrotate` | Wraps logrotate with the Arlowe config | systemd timer |
| `wake-train` | Re-train the wake-word verifier from operator samples | Manual (Phase 8 personalization) |

## Env knobs

All scripts use `/opt/arlowe/` defaults and accept environment overrides for local dev and testing.

| Var | Default | Used by |
|---|---|---|
| `PIPER_BIN` | `/opt/arlowe/runtime/tts/bin/piper` | `speak` |
| `PIPER_VOICE` | `/opt/arlowe/models/piper-voices/en_US-lessac-medium.onnx` | `speak` |
| `ARLOWE_LOGS_DIR` | `/var/lib/arlowe/logs` | `purge-logs` |
| `ARLOWE_LOGROTATE_CONF` | `/opt/arlowe/runtime/cli/logrotate.conf` | `run-logrotate` |
| `ARLOWE_WAKE_WORD_DIR` | `/opt/arlowe/runtime/wake-word` | `wake-train` |
| `ARLOWE_VENV` | `/opt/arlowe/venv` | `wake-train` |
| `ARLOWE_SYSTEMCTL_FLAGS` | `--user` | `boot-check` |

`ARLOWE_SYSTEMCTL_FLAGS` defaults to `--user` for Phase 1 (services run as the current user during development). Set to empty string for system-level units once the image build lands (Phase 11).

## Known open items

**TODO(phase-5):** Every `plughw:2,0` site is marked with a comment. Phase 5 replaces this with audio auto-detection. Affected scripts: `record`, `stt`, `speak`, `boot-check`.

**TODO(phase-11):** `boot-check` uses `--user` systemctl mode by default. When the image build introduces a dedicated `arlowe` system user and system-level units, flip `ARLOWE_SYSTEMCTL_FLAGS` to empty.

## Excluded scripts

### `wifi-watchdog` — deleted

Research (§EXTRACT-08) flagged that the live `~/bin/wifi-watchdog` on the device hardcodes the founder's home Wi-Fi SSID as a literal string. This is a founder-identity literal that cannot ship in any form.

The script's function (reconnect to a known SSID on link loss) is replaced by the dashboard's `/api/connectivity/*` routes (NetworkManager-backed), which allow the device owner to configure their own network via the pairing flow (Phase 8). If a programmatic Wi-Fi-failure-recovery helper becomes necessary in a future phase, design it fresh using NetworkManager's D-Bus API, not a hardcoded SSID.

### `iol-sync`, `usage-stats`, `stats` — personal tools, out of scope

Per `docs/04-scope.md`, these three helpers are personal founder tools tied to the IOL/OpenClaw infrastructure. They are not extracted into the firmware.
