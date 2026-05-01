# Requirements: arlowe-firmware

**Defined:** 2026-05-01
**Core Value:** A factory-fresh Pi 5 + AX accelerator + Whisplay can flash this image, boot, pair to an owner, and run wake → STT → LLM → TTS → face entirely on-device, with no founder identity present anywhere in the image.

## v1 Requirements

### Extraction (`EXTRACT`)

- [ ] **EXTRACT-01**: `voice_client.py` extracts to `runtime/voice/`; retains wake → STT → LLM → TTS → face orchestration
- [ ] **EXTRACT-02**: `face_service.py`, `face.py`, `sentiment_classifier.py`, `audio_sync.py` extract to `runtime/face/`; tcp/8080 face service preserved
- [ ] **EXTRACT-03**: `stt_server.py` extracts to `runtime/stt/`; faster-whisper HTTP server on tcp/8082 preserved
- [ ] **EXTRACT-04**: TTS invocation (currently `~/bin/speak`) extracts to `runtime/tts/` with a Piper voice asset manifest
- [ ] **EXTRACT-05**: ax-llm runtime invocation (`run_api.sh`, `qwen2.5_tokenizer_uid.py`, `openai_wrapper.py`) extracts to `runtime/llm/`
- [ ] **EXTRACT-06**: `arlowe-dashboard` Next.js app extracts to `runtime/dashboard/`; tcp/3000 preserved
- [ ] **EXTRACT-07**: Wake-word training pipeline (`~/wake_word/`) extracts to `runtime/wake-word/`; generic-model swap path documented
- [ ] **EXTRACT-08**: CLI helpers (`face`, `speak`, `stt`, `record`, `boot-check`, `purge-logs`, `run-logrotate`, `wake-train`, `wifi-watchdog`) extract to `runtime/cli/`, sanitized
- [ ] **EXTRACT-09**: `ax-llm` vendored as a git submodule under `third_party/ax-llm/` (not copied)
- [ ] **EXTRACT-10**: `axcl_host_aarch64_V3.10.2.deb` pinned by version + checksum; hash verified at image build
- [ ] **EXTRACT-11**: `iol_router.py` reviewed; clean version extracted OR stubbed; founder IOL integration paths excised
- [ ] **EXTRACT-12**: `arlowe-scheduled-summary.service` reviewed; extracted if generic, stripped if founder-only; decision recorded as ADR

### Sanitization & identity hygiene (`SANIT`)

- [ ] **SANIT-01**: All references to `focal55` removed from runtime, scripts, systemd units, configs
- [ ] **SANIT-02**: All `arlowe-1` hostname references replaced with config-driven device name (default `arlowe-${device_serial}`)
- [ ] **SANIT-03**: All `casa_ybarra_chelsea` references removed; Wi-Fi SSID becomes owner-provisioned at pairing
- [ ] **SANIT-04**: All `/home/focal55/...` paths replaced with `/opt/arlowe/` (code) or `/var/lib/arlowe/` (state)
- [ ] **SANIT-05**: All references to founder email (`joe@focal55.com`) removed
- [ ] **SANIT-06**: All `~/iol-monorepo/...` path references removed from extracted code
- [ ] **SANIT-07**: CI grep gate fails the build if any banned literal reappears: `focal55`, `arlowe-1`, `casa_ybarra_chelsea`, `/home/focal55`, `joe@focal55`, `iol-monorepo`
- [ ] **SANIT-08**: No founder-only services in the image: `openclaw-*`, `trace-*`, `workforce-metrics-snapshot.*` blocked at image-build time

### Service user & filesystem layout (`USER`)

- [ ] **USER-01**: Dedicated `arlowe` system user created during image provisioning; HOME=`/var/lib/arlowe`; no shell login by default
- [ ] **USER-02**: Code installed read-only at `/opt/arlowe/` (root-owned, readable by `arlowe` group)
- [ ] **USER-03**: All runtime state at `/var/lib/arlowe/` (owned by `arlowe`): logs, conversation cache, paired-owner secrets, config overlay
- [ ] **USER-04**: All systemd units are system-level (no `--user` units), running as `arlowe`
- [ ] **USER-05**: Service capabilities/sandboxing applied per unit (`PrivateTmp`, `ProtectSystem`, `ReadWritePaths`)

### Audio device handling (`AUDIO`)

- [ ] **AUDIO-01**: USB audio capture device auto-detected at boot; first compatible 16 kHz S16_LE source selected by default
- [ ] **AUDIO-02**: USB audio output device auto-detected; 3.5mm fallback when no USB output present
- [ ] **AUDIO-03**: Owner can override input/output device selection from dashboard; selection persisted in `/etc/arlowe/config.yml`
- [ ] **AUDIO-04**: Boot-check verifies capture and playback path works (loopback or sentinel sample); failures surface in dashboard

### Configuration overlay (`CONFIG`)

- [ ] **CONFIG-01**: `config/schema.yml` defines every knob with type, default, allowed values, and docstring
- [ ] **CONFIG-02**: `/opt/arlowe/config/defaults.yml` ships in image; covers every literal flagged in `docs/04-scope.md`
- [ ] **CONFIG-03**: `/etc/arlowe/config.yml` is the owner-mutable overlay; absent on factory image (forces pairing)
- [ ] **CONFIG-04**: Runtime loads `defaults.yml` + overlay at startup, validates against schema, fails fast on schema violation
- [ ] **CONFIG-05**: Dashboard writes the overlay atomically; affected services reload (or restart) on change
- [ ] **CONFIG-06**: Knobs cover at minimum: hostname, audio devices, model choice (7B vs 1.5B), persona/face assets, log retention, support-mode policy, OTA channel URL

### Device identity & PKI (`IDENT`)

- [ ] **IDENT-01**: Managed-PKI provisioning server selected (specific service named in ADR); not a self-rolled CA
- [ ] **IDENT-02**: Device requests an X.509 cert during first-boot pairing; cert is bound to device-unique ID + customer account
- [ ] **IDENT-03**: Device cert + private key stored in `/var/lib/arlowe/identity/` with `0600` perms; never in `/opt/arlowe/`
- [ ] **IDENT-04**: Device cert presented as the auth credential for cloud calls (OTA fetch, optional cloud features, support-mode key issuance)
- [ ] **IDENT-05**: Cert revocation path implemented and tested; a revoked unit refuses cloud calls within 1 polling interval
- [ ] **IDENT-06**: Device-unique ID derived from CPU serial + per-device entropy generated at first boot; persisted to `/var/lib/arlowe/identity/device-id`

### First-boot pairing (`PAIR`)

- [ ] **PAIR-01**: Absent `/etc/arlowe/config.yml` at boot triggers the pairing daemon
- [ ] **PAIR-02**: Pairing daemon exposes either a Wi-Fi captive portal or BLE provisioning channel (mechanism decided in phase planning)
- [ ] **PAIR-03**: Pairing flow captures: owner account credentials/token, Wi-Fi SSID + password, device display name
- [ ] **PAIR-04**: After pairing, daemon requests device cert, writes `/etc/arlowe/config.yml`, starts runtime services
- [ ] **PAIR-05**: Whisplay shows pairing status (waiting / connecting / paired / error) throughout the flow
- [ ] **PAIR-06**: Pairing failure modes (bad Wi-Fi creds, server unreachable, account auth fail) surface clearly on Whisplay + companion device
- [ ] **PAIR-07**: Factory-reset flow clears `/etc/arlowe/config.yml` + `/var/lib/arlowe/identity/` + paired data; returns unit to pairing state

### Wake word (`WAKE`)

- [ ] **WAKE-01**: Generic "Hey Arlowe" model trained on diverse voices ships with the v1 image
- [ ] **WAKE-02**: Wake-word service detects the keyword and emits an event consumed by the voice orchestrator
- [ ] **WAKE-03**: Dashboard surfaces a wake-word personalization toggle (off by default in v1)

### Image build pipeline (`IMAGE`)

- [ ] **IMAGE-01**: pi-gen pipeline produces a flashable `.img` file from repo contents + pinned dependencies
- [ ] **IMAGE-02**: Image stages: base (Pi OS), hardware deps (`axcl_host.deb`, ALSA, NetworkManager, Python), runtime (`/opt/arlowe/runtime/`), models (`/opt/arlowe/models/`), first-boot (pairing daemon armed)
- [ ] **IMAGE-03**: Image build is reproducible — same inputs produce the same image hash (where pi-gen permits)
- [ ] **IMAGE-04**: Image size verified ≤ 16 GB target; flash time documented
- [ ] **IMAGE-05**: `scripts/build-image.sh` runs the full pipeline; `scripts/flash-sd.sh` writes to a connected SD card
- [ ] **IMAGE-06**: `scripts/dev-deploy.sh` rsyncs `runtime/` to a connected Pi for fast iteration without re-flashing

### A/B partition layout (`PART`)

- [ ] **PART-01**: Image provisions four partitions: `/boot`, system A (active root), system B (standby root), `/var/lib/arlowe` (owner state)
- [ ] **PART-02**: Boot-time A/B selector reads a flag (U-Boot env or `/boot/active.txt`) and selects the active root
- [ ] **PART-03**: First boot lands on system A; system B is empty/standby in v1
- [ ] **PART-04**: `/var/lib/arlowe` partition is shared across A/B, ext4, mounted with appropriate options (noatime, etc.)
- [ ] **PART-05**: Partition sizes documented: system A and B equal-sized (image + 25% headroom); owner state sized for ~1 GB conversation cache + logs + paired data
- [ ] **PART-06**: Bricked-system fallback — recovery SD card image documented as v1 fallback (since OS OTA delivery defers to v2+)

### App-only OTA (`OTA`)

- [ ] **OTA-01**: OTA agent runs as a systemd service on the `arlowe` user
- [ ] **OTA-02**: Agent polls a signed manifest from a configured CDN URL on schedule
- [ ] **OTA-03**: Manifest signature is verified against a public key embedded in the image
- [ ] **OTA-04**: Agent rsyncs only changed files into `/opt/arlowe/runtime/`, atomic per service
- [ ] **OTA-05**: After successful rsync, affected systemd services restart; rsync or restart failures roll back to the previous version
- [ ] **OTA-06**: OTA channel (stable / beta / off) is owner-configurable from the dashboard
- [ ] **OTA-07**: Update history logged to `/var/lib/arlowe/logs/ota.log` and surfaced in the dashboard

### Owner-consented support access (`SUPP`)

- [ ] **SUPP-01**: Dashboard shows a "Support Mode" toggle, default off
- [ ] **SUPP-02**: Enabling support mode requires owner re-authentication
- [ ] **SUPP-03**: Support mode provisions a time-bound (24h default, configurable up to 7 days) SSH key for the founder identity
- [ ] **SUPP-04**: Generated key auto-revokes when the window expires; a systemd timer enforces revocation
- [ ] **SUPP-05**: All SSH activity during support mode logs to `/var/lib/arlowe/logs/support.log`; owner can review in the dashboard
- [ ] **SUPP-06**: Support mode can be revoked instantly by the owner from the dashboard
- [ ] **SUPP-07**: Support SSH access is scoped — no `sudo`, restricted file access, no direct read of conversation cache without documented support tooling

### Dashboard surfaces (`DASH`)

- [ ] **DASH-01**: Dashboard reachable on the local network at `http://<device-name>.local:3000` (or device IP)
- [ ] **DASH-02**: Owner authenticates with the credentials captured during pairing
- [ ] **DASH-03**: Health view shows: services status, audio device status, network status, model loaded, last boot time, time-to-ready
- [ ] **DASH-04**: Activity view shows: recent voice interactions (count, length, sentiment); raw transcripts viewable only locally
- [ ] **DASH-05**: Settings view exposes: persona/face, wake-word personalization toggle, audio device override, OTA channel, support mode, factory reset
- [ ] **DASH-06**: No links to founder/private services, founder repos, or workforce-internal endpoints anywhere in the UI
- [ ] **DASH-07**: All UI text passes a "no founder identity" review (CI snapshot test against banned-literal list)

### Boot health & service ordering (`BOOT`)

- [ ] **BOOT-01**: Post-boot validation script (extends `~/bin/boot-check`) runs after services come up; checks audio, network, AX accelerator, model load, dashboard
- [ ] **BOOT-02**: Failed boot checks surface on Whisplay (degraded face) + dashboard error indicator
- [ ] **BOOT-03**: Service start order codified in systemd unit dependencies: `qwen-tokenizer` → `qwen-api` → `qwen-openai`; `whisper-stt` independent; `arlowe-face` → `arlowe-voice`
- [ ] **BOOT-04**: Time-to-ready (boot to "ready to interact") measured and displayed in dashboard health
- [ ] **BOOT-05**: Persistent boot failures (≥3 consecutive) trigger an owner-facing dashboard alert with diagnostic hints

### Log management (`LOG`)

- [ ] **LOG-01**: All services log via systemd journal + per-service file appenders under `/var/lib/arlowe/logs/`
- [ ] **LOG-02**: Voice transcript logs default to 7-day retention + size-based truncation (extends `~/bin/purge-logs`)
- [ ] **LOG-03**: Owner can adjust transcript retention or disable transcript logging entirely from the dashboard

## v2 Requirements

Deferred to future release. Tracked but not in current roadmap.

### Wake-word personalization (`WAKE`)

- **WAKE-04**: Personalization flow records owner samples, retrains a personalized model overlay, swaps the active model atomically
- **WAKE-05**: Wake-word false-positive / false-negative rates measured and surfaced as dashboard health metric

### OS OTA (`OS-OTA`)

- **OS-OTA-01**: OS OTA agent fetches signed image payload, writes to inactive system partition (B if A active, vice versa)
- **OS-OTA-02**: After successful write + verification, A/B selector flips; reboot lands on new partition
- **OS-OTA-03**: Boot-failure detection on new partition automatically rolls back to previous partition
- **OS-OTA-04**: Owner-visible update flow with progress, release notes, and rollback option

### Model OTA (`MOD-OTA`)

- **MOD-OTA-01**: Model OTA agent fetches signed model artifacts (Qwen, Piper voices, wake-word) from CDN
- **MOD-OTA-02**: Verified artifacts written to `/opt/arlowe/models/`; running services hot-reload or restart
- **MOD-OTA-03**: Owner-visible model update flow with disk-space pre-checks

### Messaging adapters (`MSG`)

- **MSG-01**: Owner-bound Discord adapter (post-pairing): notifications, opt-in summaries
- **MSG-02**: Owner-bound Telegram adapter
- **MSG-03**: Adapters use the device cert for outbound auth; no founder credentials anywhere

### Advanced log management (`LOG`)

- **LOG-04**: System logs (service starts/stops, errors, network events) retained 30 days
- **LOG-05**: Opt-in log shipping off-device for support diagnostics; owner controls in dashboard

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| OS OTA delivery in v1 | Partitions designed in v1; image-swap delivery defers to v2+. v1 fallback is a recovery SD card image. |
| Model OTA in v1 | v1 ships fixed model artifacts in the image. Defers to v1.1+. |
| Multi-device coordination | One Arlowe per home; no fleet awareness across homes. |
| Cloud-required features | Every cloud path is opt-in; defaults are local. Privacy is the differentiator. |
| Custom hardware / PCB redesigns | Pi 5 + AX accelerator + Whisplay is the v1 platform. |
| Founder remote dev access on customer units | Only the owner-consented, time-bound, audit-logged support mode. |
| `openclaw-*`, `trace-*`, `workforce-metrics-snapshot.*` services | Founder-only; not a customer product capability. |
| `agentic-workforce` repo / `~/.claude/` config on customer units | Founder dev tooling, not customer product. The #1 mass-production trap. |
| Buildroot / Yocto image system | Premature; reconsider only if pi-gen image size or boot time become real constraints. |
| Custom CA / self-rolled crypto | Use a managed PKI service. |
| Discord / Telegram / messaging adapters in v1 | Deferred until pairing/identity exist; v2. |

## Traceability

Every v1 requirement is mapped to exactly one phase in `.planning/ROADMAP.md`.

| Requirement | Phase | Status |
|-------------|-------|--------|
| EXTRACT-01 | Phase 1 | Pending |
| EXTRACT-02 | Phase 1 | Pending |
| EXTRACT-03 | Phase 1 | Pending |
| EXTRACT-04 | Phase 1 | Pending |
| EXTRACT-05 | Phase 1 | Pending |
| EXTRACT-06 | Phase 1 | Pending |
| EXTRACT-07 | Phase 1 | Pending |
| EXTRACT-08 | Phase 1 | Pending |
| EXTRACT-09 | Phase 1 | Pending |
| EXTRACT-10 | Phase 1 | Pending |
| EXTRACT-11 | Phase 1 | Pending |
| EXTRACT-12 | Phase 1 | Pending |
| SANIT-01 | Phase 2 | Pending |
| SANIT-02 | Phase 2 | Pending |
| SANIT-03 | Phase 2 | Pending |
| SANIT-04 | Phase 2 | Pending |
| SANIT-05 | Phase 2 | Pending |
| SANIT-06 | Phase 2 | Pending |
| SANIT-07 | Phase 2 | Pending |
| SANIT-08 | Phase 2 | Pending |
| USER-01 | Phase 3 | Pending |
| USER-02 | Phase 3 | Pending |
| USER-03 | Phase 3 | Pending |
| USER-04 | Phase 3 | Pending |
| USER-05 | Phase 3 | Pending |
| AUDIO-01 | Phase 5 | Pending |
| AUDIO-02 | Phase 5 | Pending |
| AUDIO-03 | Phase 5 | Pending |
| AUDIO-04 | Phase 5 | Pending |
| CONFIG-01 | Phase 4 | Pending |
| CONFIG-02 | Phase 4 | Pending |
| CONFIG-03 | Phase 4 | Pending |
| CONFIG-04 | Phase 4 | Pending |
| CONFIG-05 | Phase 4 | Pending |
| CONFIG-06 | Phase 4 | Pending |
| IDENT-01 | Phase 7 | Pending |
| IDENT-02 | Phase 7 | Pending |
| IDENT-03 | Phase 7 | Pending |
| IDENT-04 | Phase 7 | Pending |
| IDENT-05 | Phase 7 | Pending |
| IDENT-06 | Phase 7 | Pending |
| PAIR-01 | Phase 8 | Pending |
| PAIR-02 | Phase 8 | Pending |
| PAIR-03 | Phase 8 | Pending |
| PAIR-04 | Phase 8 | Pending |
| PAIR-05 | Phase 8 | Pending |
| PAIR-06 | Phase 8 | Pending |
| PAIR-07 | Phase 8 | Pending |
| WAKE-01 | Phase 8 | Pending |
| WAKE-02 | Phase 8 | Pending |
| WAKE-03 | Phase 8 | Pending |
| IMAGE-01 | Phase 6 | Pending |
| IMAGE-02 | Phase 6 | Pending |
| IMAGE-03 | Phase 6 | Pending |
| IMAGE-04 | Phase 6 | Pending |
| IMAGE-05 | Phase 6 | Pending |
| IMAGE-06 | Phase 6 | Pending |
| PART-01 | Phase 6 | Pending |
| PART-02 | Phase 6 | Pending |
| PART-03 | Phase 6 | Pending |
| PART-04 | Phase 6 | Pending |
| PART-05 | Phase 6 | Pending |
| PART-06 | Phase 6 | Pending |
| OTA-01 | Phase 9 | Pending |
| OTA-02 | Phase 9 | Pending |
| OTA-03 | Phase 9 | Pending |
| OTA-04 | Phase 9 | Pending |
| OTA-05 | Phase 9 | Pending |
| OTA-06 | Phase 9 | Pending |
| OTA-07 | Phase 9 | Pending |
| SUPP-01 | Phase 10 | Pending |
| SUPP-02 | Phase 10 | Pending |
| SUPP-03 | Phase 10 | Pending |
| SUPP-04 | Phase 10 | Pending |
| SUPP-05 | Phase 10 | Pending |
| SUPP-06 | Phase 10 | Pending |
| SUPP-07 | Phase 10 | Pending |
| DASH-01 | Phase 8 | Pending |
| DASH-02 | Phase 8 | Pending |
| DASH-03 | Phase 11 | Pending |
| DASH-04 | Phase 11 | Pending |
| DASH-05 | Phase 11 | Pending |
| DASH-06 | Phase 2 | Pending |
| DASH-07 | Phase 2 | Pending |
| BOOT-01 | Phase 11 | Pending |
| BOOT-02 | Phase 11 | Pending |
| BOOT-03 | Phase 11 | Pending |
| BOOT-04 | Phase 11 | Pending |
| BOOT-05 | Phase 11 | Pending |
| LOG-01 | Phase 11 | Pending |
| LOG-02 | Phase 11 | Pending |
| LOG-03 | Phase 11 | Pending |

**Phase 12 (First-flash integration on real hardware) does not introduce new REQ-IDs; it verifies the integration of all prior requirements end-to-end on real hardware as the v1 ship gate.**

**Coverage:**
- v1 requirements: 92 total
- Mapped to phases: 92
- Unmapped: 0

---
*Requirements defined: 2026-05-01*
*Traceability mapped: 2026-04-30 (12-phase v1 roadmap)*
