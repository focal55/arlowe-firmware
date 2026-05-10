# Arlowe Dashboard

Local-network control panel for the Arlowe device. Serves on port 3000 and provides
health monitoring, voice assistant control, NPU diagnostics, log viewing, and
Wi-Fi management.

Part of the Arlowe firmware runtime tree at `runtime/dashboard/`.

## Routes

| Route | Description |
|---|---|
| `/` (Overview) | System health cards + voice assistant start/stop toggle |
| `/npu` (NPU Lab) | NPU process status, benchmark runner, local LLM chat playground |
| `/logs` (Logs) | Voice interaction history and systemd service event log |
| `/connectivity` (Connect) | Wi-Fi scan, connect, and saved-network management |

## Runtime contract

### Reads

| Source | Used by | Notes |
|---|---|---|
| `/etc/arlowe/config.yml` | `GET /api/config` | YAML config overlay; returns `{paired: false}` when absent |
| `/var/lib/arlowe/logs/voice_YYYY-MM-DD.log` | `GET /api/logs` | Voice interaction log files written by the voice service |
| `journalctl` | `GET /api/logs` | Filtered to the product service set (see below) |
| `axcl-smi` | `GET /api/health` | NPU temperature and utilization |
| `systemctl` | `GET /api/voice`, `GET /api/health` | Mode controlled by `ARLOWE_SYSTEMCTL_MODE` |
| `nmcli` | `GET /api/connectivity/*` | Network manager queries |

### Writes

| Target | Used by | Notes |
|---|---|---|
| `/etc/arlowe/config.yml` | `POST /api/config` | Atomic write via temp file + rename |

### journalctl service set

`GET /api/logs` reads events from:
- `arlowe-voice`
- `arlowe-face`
- `arlowe-dashboard`
- `qwen-tokenizer`
- `qwen-api`
- `qwen-openai`
- `whisper-stt`

In Phase 1 these run as `--user` units. Phase 11 migrates them to system units.

## Environment variables

See `.env.example` for the full documented list. Key knobs:

| Variable | Default | Description |
|---|---|---|
| `ARLOWE_SYSTEMCTL_MODE` | `user` | `user` for Phase 1 dev; `system` for Phase 11+ production image |
| `ARLOWE_CONFIG_PATH` | `/etc/arlowe/config.yml` | Config overlay path read and written by `/api/config` |
| `ARLOWE_LOGS_DIR` | `/var/lib/arlowe/logs` | Voice log directory read by `/api/logs` |
| `DASHBOARD_API_SECRET` | (unset) | Bearer token for protected routes; Phase 7 wires owner-pairing |

## Running locally on arlowe-1

```bash
cd runtime/dashboard
pnpm install
ARLOWE_SYSTEMCTL_MODE=user pnpm dev
```

The dashboard starts at http://localhost:3000.

`/etc/arlowe/config.yml` does not need to exist for the dashboard to start — the
config endpoint returns a `paired: false` state when the file is absent.

## API surface

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/health` | CPU, memory, temp, disk, NPU status |
| `GET` / `POST` | `/api/voice` | Voice service status; POST body `{action: "start"|"stop"|"toggle"}` |
| `GET` / `POST` | `/api/config` | Read / write `/etc/arlowe/config.yml` |
| `GET` | `/api/logs` | Voice + service log stream; query params: `type`, `start`, `end`, `q`, `limit` |
| `GET` | `/api/connectivity/status` | Active connection details |
| `GET` | `/api/connectivity/networks` | Wi-Fi scan results |
| `GET` | `/api/connectivity/saved` | Saved Wi-Fi profiles |
| `POST` | `/api/connectivity/connect` | Connect to a network |
| `GET` | `/api/npu/status` | NPU process check |
| `GET` | `/api/npu/benchmark` | Benchmark via local ax-llm endpoint |
| `GET` / `POST` | `/api/npu/chat` | Chat via local ax-llm endpoint |

## Authentication

Phase 7 wires owner-pairing credentials. For Phase 1, the dashboard is open on
localhost with no authentication required. `DASHBOARD_API_SECRET` can be set to
enable bearer-token protection on protected routes for manual testing.

## References

- Requirements: EXTRACT-06 (Phase 1 runtime extraction)
- Research: `.planning/phases/01-runtime-extraction/01-RESEARCH.md` §EXTRACT-06, §R2
- Config overlay: `/etc/arlowe/config.yml`
- Log directory: `/var/lib/arlowe/logs/`
