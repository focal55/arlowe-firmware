# Roadmap: arlowe-firmware

## Overview

Twelve phases take the runtime from "lives on the founder's dev unit inside a private monorepo" to "factory-fresh Pi 5 + AX + Whisplay flashes the image, boots into pairing, an owner pairs over Wi-Fi, and wake -> STT -> LLM -> TTS -> face works end-to-end on-device with no founder identity present anywhere." Phase 1 carves the runtime out of `iol-monorepo`. Phase 2 stands up the sanitization CI gate so personal literals can't sneak back in. Phases 3-5 land the `arlowe` system user, config overlay, and audio auto-detection so the runtime is parameterized rather than hardcoded. Phase 6 builds the pi-gen image with A/B partitions provisioned from day one. Phases 7-8 add managed-PKI device identity and first-boot pairing (plus the generic wake-word model). Phase 9 ships app-only OTA. Phase 10 builds the owner-consented support-access path. Phase 11 wires up boot health, dashboard surfaces, and log management. Phase 12 is the on-real-hardware integration gate that proves first-flash -> first-interaction works.

## Phases

**Phase Numbering:**
- Integer phases (1-12): Planned v1 work
- Decimal phases (e.g., 2.1): Reserved for urgent insertions during execution

- [ ] **Phase 1: Runtime extraction** - Carve `whisplay/` and `arlowe-dashboard/` out of `iol-monorepo` into `runtime/`; vendor `ax-llm`; pin Axera kernel module
- [ ] **Phase 2: Sanitization gate** - CI grep gate fails the build on any banned literal; founder-only services blocked at image-build time; UI snapshot test enforces no-founder copy
- [ ] **Phase 3: Service user and filesystem layout** - Dedicated `arlowe` system user; code at `/opt/arlowe/`; state at `/var/lib/arlowe/`; system-level systemd units with sandboxing
- [ ] **Phase 4: Config overlay** - Schema-validated `defaults.yml` + `/etc/arlowe/config.yml` overlay; every personal literal flows through config
- [ ] **Phase 5: Audio device auto-detection** - USB audio enumerated at boot; owner override via dashboard; loopback verification in boot-check
- [ ] **Phase 6: Image build with A/B partitions** - pi-gen pipeline produces a flashable `.img` with A/B system partitions and shared owner-state partition
- [ ] **Phase 7: Device identity and PKI** - Managed-PKI provisioning server selected; X.509 device cert issued at first boot; cert-based auth for cloud calls
- [ ] **Phase 8: First-boot pairing and wake word** - Pairing daemon captures Wi-Fi + account + display name; generic "Hey Arlowe" model ships with image; factory reset returns unit to pairing
- [ ] **Phase 9: App-only OTA** - Signed-manifest OTA agent rsyncs `/opt/arlowe/runtime/` from a CDN; atomic per-service restart with rollback
- [ ] **Phase 10: Owner-consented support access** - Dashboard "Support Mode" toggle provisions a time-bound founder SSH key; auto-revokes; full audit log
- [ ] **Phase 11: Boot health, dashboard surfaces, and log management** - Post-boot validation; dashboard health/activity/settings views; log retention defaults
- [ ] **Phase 12: First-flash integration on real hardware** - Factory-fresh Pi 5 + AX + Whisplay flashes the image, boots, pairs, and runs wake -> STT -> LLM -> TTS -> face end-to-end on-device

## Phase Details

### Phase 1: Runtime extraction

**Goal**: Extract the customer-facing runtime out of `iol-monorepo` into this repo's `runtime/` tree, vendor third-party dependencies cleanly, and excise founder-only integrations. Nothing else in v1 can start until this is done.

**Depends on**: Nothing (first phase; unblocks all subsequent work)

**Requirements**: EXTRACT-01, EXTRACT-02, EXTRACT-03, EXTRACT-04, EXTRACT-05, EXTRACT-06, EXTRACT-07, EXTRACT-08, EXTRACT-09, EXTRACT-10, EXTRACT-11, EXTRACT-12

**Success Criteria** (what must be TRUE):
  1. `runtime/voice/`, `runtime/face/`, `runtime/stt/`, `runtime/tts/`, `runtime/llm/`, `runtime/dashboard/`, `runtime/wake-word/`, and `runtime/cli/` exist and contain the corresponding components from `iol-monorepo`, runnable on a Pi 5 dev unit with the Axera SDK installed.
  2. `third_party/ax-llm/` is a git submodule pinned to a specific upstream commit, and `axcl_host_aarch64_V3.10.2.deb` is committed (or fetched) by version + checksum, with the hash verified at build time.
  3. `iol_router.py` and `arlowe-scheduled-summary.service` decisions are recorded as ADRs in `docs/architecture/`, and any retained code has founder-IOL paths excised.
  4. The voice orchestrator on a sanitized Pi 5 dev unit runs the wake -> STT -> LLM -> TTS -> face flow end-to-end at least once (manual smoke test, not yet CI-gated).

**Plans**: TBD

### Phase 2: Sanitization gate

**Goal**: Make it mechanically impossible for founder identity literals to reappear in the codebase, and block founder-only services from ever shipping in an image. The gate must land alongside extraction so later phases can't introduce regressions.

**Depends on**: Phase 1

**Requirements**: SANIT-01, SANIT-02, SANIT-03, SANIT-04, SANIT-05, SANIT-06, SANIT-07, SANIT-08, DASH-06, DASH-07

**Success Criteria** (what must be TRUE):
  1. CI runs a grep gate on every PR and fails the build if any of `focal55`, `arlowe-1`, `casa_ybarra_chelsea`, `/home/focal55`, `joe@focal55`, or `iol-monorepo` appears anywhere in tracked files (with documented allow-list for this gate file itself).
  2. The image build refuses to package any unit named `openclaw-*`, `trace-*`, or `workforce-metrics-snapshot.*`; a deliberate test case attempting to add one fails the build.
  3. A snapshot test against rendered dashboard UI text (and screenshots from a headless run) fails on any banned literal, including links to founder repos or workforce-internal endpoints.
  4. The current `runtime/` tree passes all sanitization checks: zero references to founder hostname, account, SSID, email, home path, or monorepo path.

**Plans**: TBD

### Phase 3: Service user and filesystem layout

**Goal**: Establish the `arlowe` system user, the `/opt/arlowe/` (code) and `/var/lib/arlowe/` (state) layout, and the systemd unit conventions that every later phase depends on.

**Depends on**: Phase 1, Phase 2

**Requirements**: USER-01, USER-02, USER-03, USER-04, USER-05

**Success Criteria** (what must be TRUE):
  1. On a freshly provisioned dev image, `id arlowe` returns a system user with HOME=`/var/lib/arlowe` and no login shell; the founder account is not present.
  2. `/opt/arlowe/` is root-owned and readable by the `arlowe` group; `/var/lib/arlowe/` is owned by `arlowe` and contains the runtime's logs, conversation cache, paired-owner secrets, and config overlay.
  3. Every shipping systemd unit is system-level (no `--user` units), runs as the `arlowe` user, and applies `PrivateTmp`, `ProtectSystem`, and unit-appropriate `ReadWritePaths`.
  4. A test on the dev image verifies that the runtime cannot write outside `/var/lib/arlowe/` (and explicit allow-listed paths) when running under the configured sandbox.

**Plans**: TBD

### Phase 4: Config overlay

**Goal**: Replace every personal literal in the runtime with config-driven values via a schema-validated two-file overlay (`defaults.yml` shipped in the image + `/etc/arlowe/config.yml` written by pairing/dashboard).

**Depends on**: Phase 3 (needs `/opt/arlowe/` and `/var/lib/arlowe/` layout); Phase 2 (sanitization gate must already block raw literals)

**Requirements**: CONFIG-01, CONFIG-02, CONFIG-03, CONFIG-04, CONFIG-05, CONFIG-06

**Success Criteria** (what must be TRUE):
  1. `config/schema.yml` defines every knob (hostname, audio devices, model choice, persona/face assets, log retention, support-mode policy, OTA channel URL) with type, default, allowed values, and docstring.
  2. Runtime services load `/opt/arlowe/config/defaults.yml` and the optional `/etc/arlowe/config.yml` overlay, validate against the schema, and refuse to start on schema violation with a clear error in the journal.
  3. Absent `/etc/arlowe/config.yml` is a recognized state that signals "not yet paired" (consumed in Phase 8); no service crashes or loops in this state.
  4. The dashboard writes the overlay atomically (temp file + rename), and at least one knob change end-to-end (e.g., persona) restarts the affected service and takes effect on the next interaction.

**Plans**: TBD

### Phase 5: Audio device auto-detection

**Goal**: Eliminate `plughw:2,0`. USB audio enumerates at boot, sensible defaults are picked, owner can override from the dashboard, and a loopback verification surfaces audio failures clearly.

**Depends on**: Phase 4 (overrides persist via config overlay); Phase 3 (services run as `arlowe` user)

**Requirements**: AUDIO-01, AUDIO-02, AUDIO-03, AUDIO-04

**Success Criteria** (what must be TRUE):
  1. With a USB capture device plugged in, the runtime selects the first compatible 16 kHz S16_LE source automatically; with one unplugged and re-plugged, the next boot picks it up without manual config.
  2. With no USB output present, audio output falls back to the 3.5mm jack; with USB output present, USB is preferred by default.
  3. An owner override saved through the dashboard persists in `/etc/arlowe/config.yml`, survives reboot, and is honored over auto-detection.
  4. The boot-check verifies a capture and playback sentinel and surfaces failures on the dashboard health view (consumed in Phase 11) plus the systemd journal.

**Plans**: TBD

### Phase 6: Image build with A/B partitions

**Goal**: Produce a flashable `.img` from this repo via pi-gen, with the A/B partition layout provisioned from day one (even though OS OTA delivery defers to v2+). Make the build reproducible enough for CI and small enough to fit on a 16 GB SD card.

**Depends on**: Phase 1 (runtime to package), Phase 3 (filesystem layout to provision), Phase 4 (defaults.yml to ship)

**Requirements**: IMAGE-01, IMAGE-02, IMAGE-03, IMAGE-04, IMAGE-05, IMAGE-06, PART-01, PART-02, PART-03, PART-04, PART-05, PART-06

**Success Criteria** (what must be TRUE):
  1. `scripts/build-image.sh` produces a `.img` file from a clean checkout that, when flashed via `scripts/flash-sd.sh` to a 16 GB+ SD card, boots a Pi 5 to a "ready to pair" state (config overlay absent, pairing daemon armed).
  2. The flashed card has four partitions: `/boot`, system A (active), system B (empty/standby in v1), and `/var/lib/arlowe` (owner state, ext4, noatime); partition sizes are documented and within the 16 GB budget.
  3. The boot-time A/B selector reads its flag (U-Boot env or `/boot/active.txt`) and lands on system A by default; flipping the flag manually and rebooting selects system B (which boots to a recovery prompt in v1, since B is empty).
  4. `scripts/dev-deploy.sh` rsyncs `runtime/` to a connected Pi over SSH for fast iteration without re-flashing, and the recovery SD-card image procedure is documented in `docs/`.
  5. Two clean builds from the same commit produce images with the same hash for inputs pi-gen permits to be reproducible (documented exceptions allowed).

**Plans**: TBD

### Phase 7: Device identity and PKI

**Goal**: Each Arlowe gets a managed-PKI-issued X.509 device cert at first-boot pairing, bound to a device-unique ID + customer account. Cert is the auth credential for every cloud-facing call from the device.

**Depends on**: Phase 6 (cert/key live on the `/var/lib/arlowe` partition); Phase 4 (config knobs for provisioning server URL)

**Requirements**: IDENT-01, IDENT-02, IDENT-03, IDENT-04, IDENT-05, IDENT-06

**Success Criteria** (what must be TRUE):
  1. An ADR records the specific managed-PKI service selected (no self-rolled CA) and the cert lifecycle (issuance, renewal, revocation).
  2. A device boots, derives a device-unique ID from CPU serial + per-device entropy, persists it to `/var/lib/arlowe/identity/device-id`, and uses it as the CSR subject when the pairing flow runs.
  3. The issued cert and private key land in `/var/lib/arlowe/identity/` with `0600` perms and never appear in `/opt/arlowe/`; an automated check enforces this on the dev image.
  4. A revoked unit refuses cloud calls (OTA fetch, support-mode key issuance) within one polling interval after revocation; this is verified end-to-end against a staging PKI.

**Plans**: TBD

### Phase 8: First-boot pairing and wake word

**Goal**: A factory-fresh image boots into a pairing daemon, captures Wi-Fi + owner account + device name, requests a device cert, writes the config overlay, and starts the runtime services. The generic "Hey Arlowe" model ships in the image. Factory reset returns the unit to the pairing state.

**Depends on**: Phase 4 (config overlay), Phase 6 (image), Phase 7 (PKI for cert request)

**Requirements**: PAIR-01, PAIR-02, PAIR-03, PAIR-04, PAIR-05, PAIR-06, PAIR-07, WAKE-01, WAKE-02, WAKE-03, DASH-01, DASH-02

**Success Criteria** (what must be TRUE):
  1. With `/etc/arlowe/config.yml` absent at boot, the pairing daemon launches, the Whisplay shows "waiting for pairing", and either the captive-portal or BLE provisioning channel is reachable from a phone or laptop (mechanism decision recorded as an ADR).
  2. A successful pairing flow captures owner account credentials/token, Wi-Fi SSID + password, and device display name; obtains a device cert; writes `/etc/arlowe/config.yml`; starts the runtime services; and lands the device on the dashboard at `http://<device-name>.local:3000` authenticated with the pairing credentials.
  3. Each pairing failure mode (bad Wi-Fi creds, server unreachable, account auth fail, cert issuance fail) produces a distinct, owner-readable error on both the Whisplay and the companion device.
  4. Factory reset (triggered from dashboard or recovery SD card) clears `/etc/arlowe/config.yml` + `/var/lib/arlowe/identity/` + paired data, and the next boot lands back in pairing mode.
  5. The shipped generic "Hey Arlowe" model wakes the orchestrator on at least three independent voices (verified by manual test) without per-customer training; the dashboard exposes a personalization toggle that is off by default.

**Plans**: TBD

### Phase 9: App-only OTA

**Goal**: An OTA agent on the device polls a signed manifest from a configured CDN, rsyncs only changed files into `/opt/arlowe/runtime/`, and atomically restarts affected services with rollback on failure. OS OTA stays out of scope (v2+); model OTA stays out of scope (v1.1+).

**Depends on**: Phase 7 (cert-based auth to fetch manifests), Phase 4 (CDN URL + channel config), Phase 6 (deployable image baseline)

**Requirements**: OTA-01, OTA-02, OTA-03, OTA-04, OTA-05, OTA-06, OTA-07

**Success Criteria** (what must be TRUE):
  1. The OTA agent runs as a systemd service under the `arlowe` user, polls the configured CDN URL on schedule, and rejects any manifest whose signature does not verify against the public key embedded in the image.
  2. A signed test manifest delivers a runtime change end-to-end: agent rsyncs only the changed files, restarts only the affected services, and the new behavior takes effect without a reboot.
  3. A deliberately broken update (rsync mid-failure or post-restart health-check fail) rolls back to the previous version automatically and logs the rollback reason.
  4. The owner sets the OTA channel (stable / beta / off) from the dashboard, and the change takes effect on the next poll cycle.
  5. `/var/lib/arlowe/logs/ota.log` records every check, every applied update, and every rollback, and the dashboard surfaces this history.

**Plans**: TBD

### Phase 10: Owner-consented support access

**Goal**: A "Support Mode" toggle in the dashboard lets the owner grant the founder a time-bound, audit-logged, scope-restricted SSH key. Auto-revoke is enforced by a systemd timer. Default is denied.

**Depends on**: Phase 7 (cert-based auth to issue support keys), Phase 9 (OTA infrastructure validates the cert/manifest pattern), Phase 4 (config knobs for support policy)

**Requirements**: SUPP-01, SUPP-02, SUPP-03, SUPP-04, SUPP-05, SUPP-06, SUPP-07

**Success Criteria** (what must be TRUE):
  1. With Support Mode off (default), no founder SSH key is authorized on the device; an automated check verifies `/home/arlowe/.ssh/authorized_keys` (and any equivalent location) contains no founder key.
  2. Enabling Support Mode requires owner re-authentication, prompts for a window length (24h default, configurable up to 7 days), provisions a time-bound founder key, and starts a systemd timer that revokes the key when the window expires.
  3. Every SSH session and command during Support Mode is logged to `/var/lib/arlowe/logs/support.log` and viewable in the dashboard; a session is verifiable end-to-end against a staging founder key.
  4. The owner can revoke Support Mode instantly from the dashboard; revocation kills active sessions and removes the authorized key within seconds.
  5. The provisioned support key is scoped: no `sudo`, restricted file access (no direct read of `/var/lib/arlowe/conversations/` without going through documented support tooling), and these restrictions are enforced by sshd config or `ForceCommand`, not by trust.

**Plans**: TBD

### Phase 11: Boot health, dashboard surfaces, and log management

**Goal**: Surface device health to the owner end-to-end. Post-boot validation runs and reports; the dashboard health, activity, and settings views are wired up; log retention defaults are in place; persistent failures alert the owner.

**Depends on**: Phase 5 (audio status), Phase 7 (network/identity), Phase 8 (dashboard auth + activity), Phase 9 (OTA channel + history), Phase 10 (support-mode toggle)

**Requirements**: BOOT-01, BOOT-02, BOOT-03, BOOT-04, BOOT-05, DASH-03, DASH-04, DASH-05, LOG-01, LOG-02, LOG-03

**Success Criteria** (what must be TRUE):
  1. The post-boot validation script (extending `~/bin/boot-check`) runs after services come up, checks audio + network + AX accelerator + model load + dashboard, records pass/fail per check, and surfaces failures on the Whisplay (degraded face) and the dashboard health indicator.
  2. The dashboard health view shows: per-service status, audio device status, network status, model loaded, last boot time, time-to-ready; the activity view shows recent voice interactions (count, length, sentiment) with raw transcripts viewable only locally; the settings view exposes persona/face, wake-word personalization, audio device override, OTA channel, support mode, and factory reset.
  3. systemd unit dependencies codify the proven order: `qwen-tokenizer` -> `qwen-api` -> `qwen-openai`; `whisper-stt` independent; `arlowe-face` -> `arlowe-voice`; a fresh boot brings the system to "ready to interact" without manual intervention.
  4. All services log via the systemd journal plus per-service appenders under `/var/lib/arlowe/logs/`; voice transcripts default to 7-day retention with size-based truncation (extending `~/bin/purge-logs`); the owner can change retention or disable transcript logging entirely from the dashboard.
  5. Three consecutive failed boots trigger an owner-facing dashboard alert with diagnostic hints (link to relevant log paths and a "send to support" hint that respects the support-mode contract).

**Plans**: TBD

### Phase 12: First-flash integration on real hardware

**Goal**: Prove end-to-end that the v1 ship target works. Flash a factory-fresh Pi 5 + AX accelerator + Whisplay from a freshly built image, pair it as a fake owner, and run the full wake -> STT -> LLM -> TTS -> face loop. This is the v1 acceptance gate.

**Depends on**: Every prior phase

**Requirements**: (no new REQ-IDs; this phase verifies the integration of all prior requirements)

**Success Criteria** (what must be TRUE):
  1. A factory-fresh Pi 5 + AX + Whisplay flashed from a clean image build boots to the pairing state on the first try, with no founder identity present anywhere on disk (verified by grep against the mounted SD card).
  2. A fresh "owner" pairs the unit through the chosen pairing channel, the device receives a real (staging-PKI) cert, the runtime services start, and the dashboard is reachable at `http://<device-name>.local:3000` with the pairing credentials.
  3. Saying "Hey Arlowe, what time is it?" within 5 minutes of pairing produces wake -> STT -> LLM -> TTS -> face end-to-end with no cloud round-trip in the default path; this is verified by network traffic capture during the interaction.
  4. App OTA delivers a runtime change end-to-end on this unit (signed manifest -> rsync -> restart) and rolls back cleanly on a deliberately broken follow-up.
  5. The owner enables Support Mode, the founder identity successfully SSHes in within the window, the audit log captures the session, and the key auto-revokes when the window expires.
  6. Factory reset returns the unit to the pairing state, and a second pairing as a different "owner" works without contamination from the first owner's data.

**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7 -> 8 -> 9 -> 10 -> 11 -> 12

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Runtime extraction | 0/TBD | Not started | - |
| 2. Sanitization gate | 0/TBD | Not started | - |
| 3. Service user and filesystem layout | 0/TBD | Not started | - |
| 4. Config overlay | 0/TBD | Not started | - |
| 5. Audio device auto-detection | 0/TBD | Not started | - |
| 6. Image build with A/B partitions | 0/TBD | Not started | - |
| 7. Device identity and PKI | 0/TBD | Not started | - |
| 8. First-boot pairing and wake word | 0/TBD | Not started | - |
| 9. App-only OTA | 0/TBD | Not started | - |
| 10. Owner-consented support access | 0/TBD | Not started | - |
| 11. Boot health, dashboard surfaces, and log management | 0/TBD | Not started | - |
| 12. First-flash integration on real hardware | 0/TBD | Not started | - |

---
*Roadmap created: 2026-04-30*
*Coverage: 92/92 v1 requirements mapped, 0 unmapped*
