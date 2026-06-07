# Phase 4: Config Overlay Scope

`config/schema.yml` is the canonical, authoritative inventory of every Arlowe firmware
config knob. This document points at that file rather than duplicating its contents.

## What schema.yml defines

Each knob in `config/schema.yml` carries: `type`, `default`, allowed values (`enum`
where applicable), and `description`. The schema is JSON Schema draft 2020-12 encoded
in YAML, consumed by:

- Python runtime services via `runtime/lib/arlowe_config.py` (jsonschema library)
- Dashboard (Phase 11) via ajv reading the same file

## Knob ownership table

| Knob | Requirement | Defined in Phase | Consumed in Phase |
|------|-------------|-----------------|-------------------|
| `device.hostname` | SANIT-02, CONFIG-06 | 4 | 7/8 (pairing resolves template) |
| `audio.capture_device` | AUDIO-03, CONFIG-06 | 4 | 5 (auto-detection), 11 (dashboard) |
| `audio.playback_device` | AUDIO-03, CONFIG-06 | 4 | 5 (auto-detection), 11 (dashboard) |
| `model.choice` | CONFIG-06 | 4 | 4 (qwen-api unit), 11 (dashboard setting) |
| `persona.sentiment_mapping` | CONFIG-06 | 4 | 4 (arlowe-face/sentiment_classifier) |
| `ports.face` | CONFIG-06 | 4 | 4 (service wiring) |
| `ports.stt` | CONFIG-06 | 4 | 4 (service wiring) |
| `ports.dashboard` | CONFIG-06 | 4 | 4 (service wiring) |
| `logs.transcript_retention_days` | LOG-02, LOG-03, CONFIG-06 | 4 | 11 (purge-logs) |
| `logs.transcript_logging_enabled` | LOG-03, CONFIG-06 | 4 | 11 (purge-logs, dashboard) |
| `support_mode.enabled` | SUPP-01, CONFIG-06 | 4 | 10 |
| `support_mode.window_hours` | SUPP-03, CONFIG-06 | 4 | 10 |
| `ota.channel` | OTA-06, CONFIG-06 | 4 | 9 |
| `ota.channel_url` | OTA-02, CONFIG-06 | 4 | 9 |

## File layout at runtime

| File | Location on device | Owner / perms |
|------|--------------------|---------------|
| `config/schema.yml` | `/opt/arlowe/config/schema.yml` | `root:arlowe 0644` |
| `config/defaults.yml` | `/opt/arlowe/config/defaults.yml` | `root:arlowe 0644` |
| overlay | `/etc/arlowe/config.yml` | `root:arlowe 0644` (written via privileged helper, Phase 4) |

## Merge contract

The loader (`runtime/lib/arlowe_config.py`) merges defaults and overlay before
validating. Absent overlay returns defaults unchanged — this is the factory/pre-pairing
state. `persona.sentiment_mapping` sub-keys are deep-merged so a partial overlay that
sets only one sentiment preserves the others.
