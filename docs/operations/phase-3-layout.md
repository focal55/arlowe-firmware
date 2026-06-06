# Phase 3 filesystem layout reference

**Established by:** plan 03-01 (`scripts/provision/install-arlowe-{user,fs}.sh`)
**Status:** canonical — downstream phases cite this doc when adding files to the tree.

## Overview

Phase 3 establishes the ownership and mode contract for the three top-level
directories that the arlowe runtime uses: `/opt/arlowe/` (code root), `/var/lib/arlowe/`
(owner state), and `/etc/arlowe/` (config overlay dir). Phase 3 creates the directory
skeleton and sets ownership/modes. Later phases populate file contents within the
skeleton — they must not change ownership or modes established here without updating
this doc and the corresponding assertion scripts in `tests/phase-3/assertions/`.

Verification: `bash tests/phase-3/docker/run-tests.sh`

## Layout tree

Source of truth: `.planning/phases/03-service-user-and-filesystem-layout/03-RESEARCH.md` §4.

```
/opt/arlowe/                                 root:arlowe  0750  Code root; read-only at runtime; OTA-mutable at update.
├── runtime/                                 root:arlowe  0755
│   ├── voice/                               root:arlowe  0755
│   ├── face/                                root:arlowe  0755
│   ├── stt/                                 root:arlowe  0755
│   ├── tts/                                 root:arlowe  0755
│   ├── llm/                                 root:arlowe  0755
│   ├── dashboard/                           root:arlowe  0755  Next.js standalone bundle
│   ├── wake-word/                           root:arlowe  0755
│   └── cli/                                 root:arlowe  0755  CLI helper scripts
├── third_party/                             root:arlowe  0755  Vendored deps (Phase 6)
├── models/                                  root:arlowe  0755  LLM, TTS, wake-word models (Phase 6)
├── venvs/                                   root:arlowe  0755  Python venvs; baked at image build (Phase 6)
└── config/                                  root:arlowe  0755  Dir reserved; defaults.yml content owned by Phase 4

/etc/arlowe/                                 root:arlowe  0755  Config overlay dir; Phase 3 creates empty
└── (config.yml absent — its absence is the "not yet paired" signal per CONFIG-03)

/var/lib/arlowe/                             arlowe:arlowe  0750  Owner state; mount point of owner-state partition (Phase 6)
├── logs/                                    arlowe:arlowe  0750  Per-service log directories
│   ├── voice/                               arlowe:arlowe  0750
│   ├── face/                                arlowe:arlowe  0750
│   ├── stt/                                 arlowe:arlowe  0750
│   ├── tts/                                 arlowe:arlowe  0750
│   ├── llm/                                 arlowe:arlowe  0750
│   └── dashboard/                           arlowe:arlowe  0750
├── conversations/                           arlowe:arlowe  0700  Conversation cache; sensitive
├── identity/                                arlowe:arlowe  0700  PKI cert + key (Phase 7); empty in Phase 3 image
├── state/                                   arlowe:arlowe  0750  Service state files
├── wake-word/                               arlowe:arlowe  0750  Owner training samples + verifier.pkl (Phase 8)
└── dashboard/
    └── cache/                               arlowe:arlowe  0750  NEXT_PRIVATE_CACHE_DIR target
```

## Path × owner × mode × purpose table

| Path | Owner | Mode | Writable by arlowe? | Purpose | Phase that populates |
|---|---|---|---|---|---|
| `/opt/arlowe/` | root:arlowe | 0750 | NO | Code root | Phase 6 image build; Phase 9 OTA |
| `/opt/arlowe/runtime/` | root:arlowe | 0755 | NO | Component runtimes | Phase 6 / OTA |
| `/opt/arlowe/runtime/voice/` | root:arlowe | 0755 | NO | Voice orchestrator code | Phase 6 |
| `/opt/arlowe/runtime/face/` | root:arlowe | 0755 | NO | Face display code | Phase 6 |
| `/opt/arlowe/runtime/stt/` | root:arlowe | 0755 | NO | STT server code | Phase 6 |
| `/opt/arlowe/runtime/tts/` | root:arlowe | 0755 | NO | TTS binary + helpers | Phase 6 |
| `/opt/arlowe/runtime/llm/` | root:arlowe | 0755 | NO | LLM router + ax-llm runner | Phase 6 |
| `/opt/arlowe/runtime/dashboard/` | root:arlowe | 0755 | NO | Next.js standalone bundle | Phase 6 |
| `/opt/arlowe/runtime/wake-word/` | root:arlowe | 0755 | NO | Wake-word detection code | Phase 6 |
| `/opt/arlowe/runtime/cli/` | root:arlowe | 0755 | NO | CLI helper scripts (plan 03-04 symlinks) | Phase 6 / plan 03-04 |
| `/opt/arlowe/third_party/` | root:arlowe | 0755 | NO | Vendored deps (ax-llm, whisplay-driver, axcl) | Phase 6 |
| `/opt/arlowe/models/` | root:arlowe | 0755 | NO | LLM, TTS, wake-word models | Phase 6 |
| `/opt/arlowe/venvs/` | root:arlowe | 0755 | NO | Python venvs; empty in Phase 3 | Phase 6 |
| `/opt/arlowe/config/` | root:arlowe | 0755 | NO | Config dir; parent reserved by Phase 3 | Phase 3 (dir only) |
| `/opt/arlowe/config/defaults.yml` | root:arlowe | 0644 | NO | Default config knobs | Phase 4 |
| `/etc/arlowe/` | root:arlowe | 0755 | NO | Config overlay dir | Phase 3 (empty) |
| `/etc/arlowe/config.yml` | root:arlowe | 0640 | NO (privileged helper) | Owner overlay | Phase 8 pairing creates; Phase 4 schema-validates |
| `/var/lib/arlowe/` | arlowe:arlowe | 0750 | YES | Owner state mount point | Phase 6 ext4 partition |
| `/var/lib/arlowe/logs/` | arlowe:arlowe | 0750 | YES | Per-service log root | Phase 3 reserve |
| `/var/lib/arlowe/logs/<service>/` | arlowe:arlowe | 0750 | YES | Per-service log dirs | Phase 3 (voice/face/stt/tts/llm/dashboard) |
| `/var/lib/arlowe/conversations/` | arlowe:arlowe | 0700 | YES | Conversation cache; sensitive | Runtime |
| `/var/lib/arlowe/identity/` | arlowe:arlowe | 0700 | YES | Device cert + key (Phase 7); pairing writes here | Phase 7 / Phase 8 |
| `/var/lib/arlowe/state/` | arlowe:arlowe | 0750 | YES | Service state files | Runtime |
| `/var/lib/arlowe/wake-word/` | arlowe:arlowe | 0750 | YES | Owner training data + verifier.pkl | Phase 8 |
| `/var/lib/arlowe/dashboard/cache/` | arlowe:arlowe | 0750 | YES | NEXT_PRIVATE_CACHE_DIR target | Runtime |

## What Phase 3 does NOT do

1. Does NOT create `/etc/arlowe/config.yml`. Its absence is the CONFIG-03 pairing trigger.
   Phase 8 pairing daemon creates this file after the owner completes the pairing flow.

2. Does NOT create `/opt/arlowe/config/defaults.yml`. Phase 4 owns the file content and
   schema. Plan 03-01 only reserves the parent directory (`/opt/arlowe/config/`).

3. Does NOT create `/var/lib/arlowe/.ssh/`. Phase 10 (support mode) creates it at runtime
   when support mode activates. Its absence in the factory image is the Phase 10 baseline.

4. Does NOT populate venv contents. `/opt/arlowe/venvs/` is an empty directory in Phase 3.
   Phase 6 bakes Python venvs from per-service `requirements.txt` during image build.

5. Does NOT stage model files. `/opt/arlowe/models/` is an empty directory. Phase 6 stages
   Qwen, Piper, and wake-word models during image build.

6. Does NOT write the Axera udev rule or polkit rule. Plan 03-03 (udev + polkit) owns those.

7. Does NOT install CLI symlinks in `/usr/local/sbin/`. Plan 03-04 owns the symlink install.

## OTA-01 amendment notice

**OTA-01 (original wording in REQUIREMENTS.md):**
> OTA agent runs as a systemd service on the `arlowe` user.

**OTA-01 (amended, assumed by Phase 3 plan 01):**
> OTA agent runs as a system-level systemd service with strictly sandboxed root:
> `ProtectSystem=strict`, `ReadWritePaths=/opt/arlowe`, `NoNewPrivileges=yes`,
> tight `SystemCallFilter=`. Rationale: `/opt/arlowe/` is root-owned and
> read-only at runtime; the only writer is the OTA agent. Running OTA as `arlowe`
> would require either making `/opt/arlowe` writable by `arlowe` (defeats USER-02)
> or wiring polkit grants (more complex, harder to audit). Phase 9 must honor this
> contract or raise an ADR amendment when it lands.

This amendment is assumed-accepted. Phase 9 should confirm or escalate at plan time.
The GSD frontmatter scanner should pick this up from this doc's `provides:` block.

## Phase 8 pairing daemon reservation

Phase 8 will need to:
- Write `/var/lib/arlowe/identity/` — already writable by `arlowe` user (mode 0700
  arlowe:arlowe). The pairing daemon can write as `arlowe` or as root.
- Write `/etc/arlowe/config.yml` — this path is under `ProtectSystem=strict` for all
  service units. The recommendation from research §9 and §12.2 is to run the pairing
  daemon as a root one-shot (`Type=oneshot`, `Restart=no`) with
  `ReadWritePaths=/etc/arlowe /var/lib/arlowe/identity` and `ProtectSystem=strict`.
  Phase 8 may revise this if the privileged-helper pattern from Phase 4 is sufficient.

Phase 8 must not assume `/etc/arlowe/config.yml` exists at pairing daemon start — its
absence is the trigger, not a precondition to check.

## Verification

Primary (Docker, runs on Mac + the dev Pi):
```bash
bash tests/phase-3/docker/run-tests.sh
```

Hardware-loop validation (SC4 sandbox write denial on real Pi hardware) is owned by
plan 03-05. That plan runs the assertion scripts via
`ARLOWE_USER=arlowe-staging bash tests/phase-3/assertions/01-user-shape.sh`
against a side-by-side staging user on the dev Pi to confirm gpio/spi/audio group
access against real kernel devices without disturbing the live setup.
