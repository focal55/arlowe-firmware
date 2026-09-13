# Roadmap: arlowe-firmware

## Overview

Twelve phases take the runtime from "lives on the founder's dev unit inside a private monorepo" to "factory-fresh Pi 5 + AX + Whisplay flashes the image, boots into pairing, an owner pairs over Wi-Fi, and wake -> STT -> LLM -> TTS -> face works end-to-end on-device with no founder identity present anywhere." Phase 1 carves the runtime out of `iol-monorepo`. Phase 2 stands up the sanitization CI gate so personal literals can't sneak back in. Phases 3-5 land the `arlowe` system user, config overlay, and audio auto-detection so the runtime is parameterized rather than hardcoded. Phase 6 builds the pi-gen image with A/B partitions provisioned from day one. Phases 7-8 add managed-PKI device identity and first-boot pairing (plus the generic wake-word model). Phase 9 ships app-only OTA. Phase 10 builds the owner-consented support-access path. Phase 11 wires up boot health, dashboard surfaces, and log management. Phase 12 is the on-real-hardware integration gate that proves first-flash -> first-interaction works.

## Phases

**Phase Numbering:**
- Integer phases (1-12): Planned v1 work
- Decimal phases (e.g., 2.1): Reserved for urgent insertions during execution

- [x] **Phase 1: Runtime extraction** - Carve `whisplay/` and `arlowe-dashboard/` out of `iol-monorepo` into `runtime/`; vendor `ax-llm`; pin Axera kernel module (complete 2026-05-17, qualified — SC4 hardware loop deferred per plan 13)
- [x] **Phase 2: Sanitization gate** - CI grep gate fails the build on any banned literal; founder-only services blocked at image-build time; UI snapshot test enforces no-founder copy (complete 2026-05-27)
- [x] **Phase 3: Service user and filesystem layout** - Dedicated `arlowe` system user; code at `/opt/arlowe/`; state at `/var/lib/arlowe/`; system-level systemd units with sandboxing (complete 2026-06-07, passed-with-notes — SC4 verified on real hardware via plan 03-05 staging harness; Phase-4 cleanups #73–#75 already merged: groups tightened to {audio,gpio,spi}, NPU nodes 0660 root:arlowe)
- [x] **Phase 4: Config overlay** - Schema-validated `defaults.yml` + `/etc/arlowe/config.yml` overlay; every personal literal flows through config (complete 2026-06-07, passed-with-notes — 4 plans merged via PRs #84/#85/#86/#87; SC4 on-device persona-knob check deferred to Phase 6/12, arlowe-1 has no arlowe layout to run it)
- [x] **Phase 5: Audio device auto-detection** - USB audio enumerated at boot; owner override via dashboard; loopback verification in boot-check (complete 2026-06-13, passed-with-notes — 7 plans merged via PRs #95-#101/#104; SC2 reframed Pi-5-has-no-3.5mm → wm8960 codec; on-Pi SC1-SC4 run deferred to a hardware checkpoint per Phase 1/3/4 precedent, procedure in docs/operations/phase-5-audio.md)
- [x] **Phase 6: Image build with A/B partitions** - pi-gen pipeline produces a flashable `.img` with A/B system partitions and shared owner-state partition (complete in code 2026-06-14, 6 plans merged via PRs #112/#113/#114/#115/#116. HARDWARE CHECKPOINT IN PROGRESS — started 2026-06-19 on arlowe-1 (first-ever build), paused mid-setup pending SD-card-size decision + WhisPlay-driver staging; see STATE.md Session Continuity for the resume checklist. Runbook docs/operations/phase-6-build-flash-deploy.md)
- [ ] **Phase 7: Device identity and PKI** - Managed-PKI provisioning server selected; X.509 device cert issued at first boot; cert-based auth for cloud calls — 10/11 plans merged to main (PR #122, `e7dff4f`); SC4 unverified, 07-09 parked on an AWS staging account
- [x] **Phase 7.1: Runtime substrate repair (INSERTED)** - Populate `/opt/arlowe/venvs`, build the dashboard to `server.js`, declare the missing apt packages, guard the wake-word verifier; a build gate asserts every unit's ExecStart interpreter exists in the rootfs **(complete in code; SC6 hardware checkpoint UNPROVEN)**
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
  4. The voice orchestrator on the Pi 5 dev unit (arlowe-1) runs the wake -> STT -> LLM -> TTS -> face flow end-to-end at least once via parallel `-test` units that share the live `qwen-*` and `whisper-stt` services (manual smoke test, hybrid live/test stack, not yet CI-gated). The fully-sanitized first-flash variant — factory-fresh Pi 5, no founder identity on disk, all services from the new `runtime/` tree — is the gate Phase 12 owns. See `docs/operations/phase-1-smoke-test.md` (created in plan 13) for the scope-and-limits write-up that records this distinction.

**Plans**: 15 plans

Plans:
- [ ] 01-PLAN.md — Scaffold runtime/ + third_party/ tree; dev-pull-from-pi.sh; .gitignore for biometric data (Wave 1)
- [ ] 02-PLAN.md — EXTRACT-01: voice orchestrator → runtime/voice/ (Wave 2, Stream A)
- [ ] 03-PLAN.md — EXTRACT-02 (part 1): face.py + face_service.py → runtime/face/; resolve WhisPlay driver provenance (Wave 2, Stream A)
- [ ] 03b-PLAN.md — EXTRACT-02 (part 2): sentiment_classifier.py + audio_sync.py + requirements + README → runtime/face/ (Wave 2, Stream A) [split out of 03 for atomic-PR cap]
- [ ] 04-PLAN.md — EXTRACT-03 + EXTRACT-04: STT + TTS → runtime/{stt,tts}/; Piper manifest; remove dashboard .env.local cross-coupling (Wave 3, Stream A) [moved to Wave 3 per checker B1: tts_sync.py imports `from face.audio_sync` which 03b creates]
- [ ] 05-PLAN.md — EXTRACT-05 + EXTRACT-11: LLM → runtime/llm/ (router rename); ADR-0001; requirements + README (Wave 2, Stream A) [task count reduced to 4 per checker M3]
- [ ] 06-PLAN.md — EXTRACT-06 (audit phase): dashboard route+page categorization (Wave 2, Stream B)
- [ ] 07-PLAN.md — EXTRACT-06 (delete phase): copy dashboard, run delete pass (Wave 3, Stream B)
- [ ] 08-PLAN.md — EXTRACT-06 (rewrite phase, part 1): /api/config + /api/logs (Wave 4, Stream B) [split for atomic-PR cap]
- [ ] 08b-PLAN.md — EXTRACT-06 (rewrite phase, part 2): /api/voice + .env.example + README + final dashboard verify (Wave 5, Stream B) [split out of 08]
- [ ] 09-PLAN.md — EXTRACT-09 + EXTRACT-10: ax-llm submodule + axcl deb pin + verify-third-party.sh (Wave 2, Stream C)
- [ ] 10-PLAN.md — EXTRACT-08: CLI helpers → runtime/cli/; delete wifi-watchdog (Wave 2, Stream D)
- [ ] 11-PLAN.md — EXTRACT-07: wake-word pipeline → runtime/wake-word/ (no biometric data, plus git-history defense check) (Wave 2, Stream D)
- [ ] 12-PLAN.md — EXTRACT-12: ADR-0002 stripping arlowe-scheduled-summary (Wave 2, Stream D)
- [ ] 13-PLAN.md — Smoke test convergence: openai_wrapper resolution + wake→STT→LLM→TTS→face on arlowe-1 (Wave 6) [non-autonomous; requires owner present; depends on 02, 03, 03b, 04, 05, 08b, 09, 10, 11, 12]

### Phase 2: Sanitization gate

**Goal**: Make it mechanically impossible for founder identity literals to reappear in the codebase, and block founder-only services from ever shipping in an image. The gate must land alongside extraction so later phases can't introduce regressions.

**Depends on**: Phase 1

**Requirements**: SANIT-01, SANIT-02, SANIT-03, SANIT-04, SANIT-05, SANIT-06, SANIT-07, SANIT-08, DASH-06, DASH-07

**Success Criteria** (what must be TRUE):
  1. CI runs a grep gate on every PR and fails the build if any of `focal55`, `arlowe-1`, `casa_ybarra_chelsea`, `/home/focal55`, `joe@focal55`, or `iol-monorepo` appears anywhere in tracked files (with documented allow-list for this gate file itself).
  2. The image build refuses to package any unit named `openclaw-*`, `trace-*`, or `workforce-metrics-snapshot.*`; a deliberate test case attempting to add one fails the build.
  3. A snapshot test against rendered dashboard UI text (and screenshots from a headless run) fails on any banned literal, including links to founder repos or workforce-internal endpoints.
  4. The current `runtime/` tree passes all sanitization checks: zero references to founder hostname, account, SSID, email, home path, or monorepo path.

**Plans**: 4 plans

Plans:
- [ ] 02-01-PLAN.md — Banlist + grep gate runner + allow-list + CI workflow + self-test (Wave 1, foundational)
- [ ] 02-02-PLAN.md — Unit-name block extension + `--scan-dir DIR` flag for Phase 6 reuse (Wave 2, depends on 02-01)
- [ ] 02-03-PLAN.md — Dashboard Playwright sanitize.spec.ts + CI wiring (Wave 2, depends on 02-01; parallel with 02-02)
- [ ] 02-04-PLAN.md — Runtime/ tree SC4 cleanup sweep + F5 ADR-0001 fix; drives all gates green on main (Wave 3, depends on 02-01, 02-02, 02-03)

### Phase 3: Service user and filesystem layout

**Goal**: Establish the `arlowe` system user, the `/opt/arlowe/` (code) and `/var/lib/arlowe/` (state) layout, and the systemd unit conventions that every later phase depends on.

**Depends on**: Phase 1, Phase 2

**Requirements**: USER-01, USER-02, USER-03, USER-04, USER-05

**Success Criteria** (what must be TRUE):
  1. On a freshly provisioned dev image, `id arlowe` returns a system user with HOME=`/var/lib/arlowe` and no login shell; the founder account is not present.
  2. `/opt/arlowe/` is root-owned and readable by the `arlowe` group; `/var/lib/arlowe/` is owned by `arlowe` and contains the runtime's logs, conversation cache, paired-owner secrets, and config overlay.
  3. Every shipping systemd unit is system-level (no `--user` units), runs as the `arlowe` user, and applies `PrivateTmp`, `ProtectSystem`, and unit-appropriate `ReadWritePaths`.
  4. A test on the dev image verifies that the runtime cannot write outside `/var/lib/arlowe/` (and explicit allow-listed paths) when running under the configured sandbox.

**Plans**: 5 plans

Plans:
- [x] 03-01-PLAN.md — Provisioning scripts (install-arlowe-user + install-arlowe-fs) + Docker testbed + SC1/SC2 assertions + layout-reference doc (Wave 1, foundational; OTA-01 amendment noted)
- [x] 03-02-PLAN.md — Six systemd unit files + install-units.sh + SC3 assertions (systemd-analyze verify + security) (Wave 2, depends on 03-01)
- [x] 03-03-PLAN.md — Udev rules (Axera + GPIO/SPI defense-in-depth) + polkit rule (arlowe→systemctl arlowe-*) + axcl-deb diagnostic (Wave 2, depends on 03-01; parallel with 03-02)
- [x] 03-04-PLAN.md — CLI symlinks installer + boot-check ARLOWE_SYSTEMCTL_FLAGS default flip to system-level (Wave 2, depends on 03-01; parallel with 03-02, 03-03)
- [x] 03-05-PLAN.md — arlowe-1 staging-user harness: install/uninstall, SC4 sandbox write-deny on real hardware, speculative-group + gpiochip resolution (Wave 3; non-autonomous, depends on 03-01..04)

### Phase 4: Config overlay

**Goal**: Replace every personal literal in the runtime with config-driven values via a schema-validated two-file overlay (`defaults.yml` shipped in the image + `/etc/arlowe/config.yml` written by pairing/dashboard).

**Depends on**: Phase 3 (needs `/opt/arlowe/` and `/var/lib/arlowe/` layout); Phase 2 (sanitization gate must already block raw literals)

**Requirements**: CONFIG-01, CONFIG-02, CONFIG-03, CONFIG-04, CONFIG-05, CONFIG-06

**Success Criteria** (what must be TRUE):
  1. `config/schema.yml` defines every knob (hostname, audio devices, model choice, persona/face assets, log retention, support-mode policy, OTA channel URL) with type, default, allowed values, and docstring.
  2. Runtime services load `/opt/arlowe/config/defaults.yml` and the optional `/etc/arlowe/config.yml` overlay, validate against the schema, and refuse to start on schema violation with a clear error in the journal.
  3. Absent `/etc/arlowe/config.yml` is a recognized state that signals "not yet paired" (consumed in Phase 8); no service crashes or loops in this state.
  4. The dashboard writes the overlay atomically (temp file + rename), and at least one knob change end-to-end (e.g., persona) restarts the affected service and takes effect on the next interaction.

**Plans**: 4 plans

Plans:
- [ ] 04-01-PLAN.md — schema.yml + defaults.yml + shared Python loader/validator + tests + docs/04-scope.md (Wave 1, foundational)
- [ ] 04-02-PLAN.md — ADR 0003 loosen-perms + /etc/arlowe 0770 + dashboard ReadWritePaths + install-arlowe-config.sh + install-shape assertion (Wave 2, package:security, depends on 04-01)
- [ ] 04-03-PLAN.md — dashboard ajv validate-before-write + atomic write + knob->unit restart map/trigger + test (Wave 2, depends on 04-01; parallel with 04-02)
- [ ] 04-04-PLAN.md — persona live slice: face consumes YAML overlay + ExecStartPre fail-fast validators + SC4 human-verify checkpoint (Wave 3; non-autonomous, depends on 04-01..03)

### Phase 5: Audio device auto-detection

**Goal**: Eliminate `plughw:2,0`. USB audio enumerates at boot, sensible defaults are picked, owner can override from the dashboard, and a loopback verification surfaces audio failures clearly.

**Depends on**: Phase 4 (overrides persist via config overlay); Phase 3 (services run as `arlowe` user)

**Requirements**: AUDIO-01, AUDIO-02, AUDIO-03, AUDIO-04

**Success Criteria** (what must be TRUE):
  1. With a USB capture device plugged in, the runtime selects the first compatible 16 kHz S16_LE source automatically; with one unplugged and re-plugged, the next boot picks it up without manual config.
  2. With no USB output present, audio output falls back to the 3.5mm jack; with USB output present, USB is preferred by default. *Hardware reframe (Phase 5 research §6): the Pi 5 has no onboard 3.5mm analog jack; the implemented fallback chain is USB out → Whisplay/WM8960 codec → HDMI. Selection matches the `wm8960` substring, not a fixed index. SC text preserved; see `docs/operations/phase-5-audio.md` (plan 05-07).*
  3. An owner override saved through the dashboard persists in `/etc/arlowe/config.yml`, survives reboot, and is honored over auto-detection.
  4. The boot-check verifies a capture and playback sentinel and surfaces failures on the dashboard health view (consumed in Phase 11) plus the systemd journal.

**Plans**: 7 plans

Plans:
- [x] 05-01-PLAN.md — arlowe_audio.py: /proc/asound enumeration + card-id→plughw resolution + auto-pick (capture USB→wm8960; playback USB→wm8960→HDMI) + fixtures/tests (Wave 1, foundational)
- [x] 05-02-PLAN.md — Python consumer wiring: voice_client.py (arecord AND pyaudio wake-word surfaces) + tts_sync.py + auto_collect.py; split capture/playback (Wave 2, depends on 05-01)
- [x] 05-03-PLAN.md — bash CLI wiring: record/stt/speak resolve device via arlowe_audio CLI (Wave 2, depends on 05-01)
- [x] 05-04-PLAN.md — dashboard /api/audio/devices endpoint (fs read of /proc/asound) + /audio picker page + nav (Wave 2, depends on 05-01, package:security)
- [x] 05-05-PLAN.md — udev hotplug rule (SUBSYSTEM==sound → debounced arlowe-voice restart) + Docker shape test (Wave 2, depends on 05-01, package:security)
- [x] 05-06-PLAN.md — boot-check capture+playback sentinel via arlowe_audio --selfcheck + structured JSON status for Phase 11 (Wave 3, depends on 05-01)
- [x] 05-07-PLAN.md — hardware-verify runbook (SC1–SC4) + SC2 wm8960 reframe + ROADMAP footnote (Wave 4; non-autonomous, deferred per Phase 1/3/4 precedent, depends on 05-02..06)

### Phase 6: Image build with A/B partitions

**Goal**: Produce a flashable `.img` from this repo via pi-gen, with the A/B partition layout provisioned from day one (even though OS OTA delivery defers to v2+). Make the build reproducible enough for CI; a single shared model partition keeps a 16 GB SD card viable (32 GB recommended for larger-model headroom — see ADR-0004).

**Depends on**: Phase 1 (runtime to package), Phase 3 (filesystem layout to provision), Phase 4 (defaults.yml to ship)

**Requirements**: IMAGE-01, IMAGE-02, IMAGE-03, IMAGE-04, IMAGE-05, IMAGE-06, PART-01, PART-02, PART-03, PART-04, PART-05, PART-06

**Success Criteria** (what must be TRUE):
  1. `scripts/build-image.sh` produces a `.img` file from a clean checkout that, when flashed via `scripts/flash-sd.sh` to a 16 GB+ SD card (32 GB recommended), boots a Pi 5 to a "ready to pair" state (config overlay absent, first-boot hook armed — ready-to-pair state; the pairing daemon itself is Phase 8).
  2. The flashed card has FIVE partitions: `/boot`, system A (active, model-free), system B (recovery rootfs, model-free), a shared read-only `models` partition (mounted at `/opt/arlowe/models` in both slots), and `/var/lib/arlowe` (owner state, ext4, noatime, FIXED size); the `models` partition grows-to-fill on first boot; partition sizes are documented (16 GB viable, 32 GB recommended — see ADR-0004).
  3. The boot-time A/B selector is the Pi tryboot root= selector (arlowe-ab flips the persistent default by rewriting root=) and lands on system A by default; flipping manually and rebooting selects system B, which boots a minimal recovery rootfs that surfaces recovery on Whisplay + serial and resets the default to A.
  4. `scripts/dev-deploy.sh` rsyncs `runtime/` to a connected Pi over SSH for fast iteration without re-flashing, and the recovery SD-card image procedure is documented in `docs/`.
  5. Two clean builds from the same commit produce images with the same hash for inputs pi-gen permits to be reproducible (documented exceptions allowed; input reproducibility only; no image-hash gate — ext4 nondeterminism documented as an exception).

**Plans**: 6 plans

Plans:
- [x] 06-01-PLAN.md — Reconcile shared-model 5-partition sizing (16 GB viable / 32 GB recommended) + PART-02 tryboot-wording (ADRs 0004/0005/0006 + REQUIREMENTS/ROADMAP amendments)
- [x] 06-02-PLAN.md — SHA-pinned model + WhisPlay manifest/fetch gate (one shared copy); Whisper model choice ADR (#112)
- [x] 06-03-PLAN.md — pi-gen stage-arlowe: chroot provisioning reuse + axcl + WhisPlay vendor + models + armed first-boot (#113)
- [x] 06-04-PLAN.md — build-image.sh + measure-then-set 5-partition A/B + shared-models layout + models grow-to-fill + sanitize scan-dir gate (#114)
- [x] 06-05-PLAN.md — tryboot root= selector + arlowe-ab flip CLI + slot-B recovery stub + shared-models mount in both slots (#115)
- [x] 06-06-PLAN.md — arm64 image-build CI + PR shellcheck + flash-sd.sh + dev-deploy.sh + docs + hardware checkpoint (#116; complete-pending-hardware-checkpoint)

### Phase 7: Device identity and PKI

**Goal**: Each Arlowe gets a managed-PKI-issued X.509 device cert at first-boot pairing, bound to a device-unique ID + customer account. Cert is the auth credential for every cloud-facing call from the device.

**Depends on**: Phase 6 (cert/key live on the `/var/lib/arlowe` partition); Phase 4 (config knobs for provisioning server URL)

**Requirements**: IDENT-01, IDENT-02, IDENT-03, IDENT-04, IDENT-05, IDENT-06

**Success Criteria** (what must be TRUE):
  1. An ADR records the specific managed-PKI service selected (no self-rolled CA) and the cert lifecycle (issuance, renewal, revocation).
  2. A device boots, derives a device-unique ID from CPU serial + per-device entropy, persists it to `/var/lib/arlowe/identity/device-id`, and uses it as the CSR subject when the pairing flow runs.
  3. The issued cert and private key land in `/var/lib/arlowe/identity/` with `0600` perms and never appear in `/opt/arlowe/`; an automated check enforces this on the dev image.
  4. A revoked unit refuses cloud calls (OTA fetch, support-mode key issuance) within one polling interval after revocation; this is verified end-to-end against a staging PKI.

**Plans**: 11 plans in 7 waves

Note on IDENT-02: Phase 7 delivers the device-unique-ID half of the binding (via the IoT Thing
name). The **customer-account** half is deferred to Phase 8 — the bootstrap broker is
token-agnostic by design and does not know who issued the token. Plan 07-09 records this in the
REQUIREMENTS.md traceability row; IDENT-02 does not close with Phase 7.

Plans:
- [x] 07-01-PLAN.md — ADR-0007 (managed-PKI selection) + optional `identity` config block
- [x] 07-02-PLAN.md — CI teeth: python-test job, bookworm cryptography floor job, dashboard jobs repointed; Phase 7 python deps
- [x] 07-03-PLAN.md — `arlowe_identity.py`: device-id derivation, per-device entropy, 0600 secret writer, identity.json read/update contract
- [x] 07-04-PLAN.md — SC3 identity-store hygiene gate in `build-image.sh` + `boot-check check_identity`
- [x] 07-05a-PLAN.md — staging PKI lifecycle as code: `scripts/pki/` setup, teardown, revoke lever
- [x] 07-05b-PLAN.md — token-agnostic CSR broker + frozen `POST /v1/certificates` contract
- [x] 07-06-PLAN.md — `arlowe_pki.py`: P-256 keypair + CSR (CN = device-id) + certificate storage
- [x] 07-07-PLAN.md — `arlowe_cloud.py`: broker POST + IoT credentials exchange, `CertificateRevoked`
- [x] 07-08a-PLAN.md — `arlowe-identity` CLI (init/status/provision/check-cloud/reset) + tests
- [x] 07-08b-PLAN.md — first-boot unit (`UMask=0077`, `RequiresMountsFor`) + image wiring
- [ ] 07-09-PLAN.md — SC4 end-to-end revocation verification against staging; ADR-0007 -> Accepted **(PARKED — needs a staging AWS account with `iot:*` + `iam:CreateRole/AttachRolePolicy/PassRole`; SC4 is the only unverified criterion and ADR-0007 stays Proposed until it runs)**

### Phase 7.1: Runtime substrate repair (INSERTED)

**Goal**: Make the six shipping runtime units actually startable on a factory image. **Four** of them — `arlowe-voice`, `arlowe-face`, `whisper-stt`, `qwen-tokenizer` — invoke one of three venv interpreters under `/opt/arlowe/venvs/{voice,llm,stt}/bin/python` across **seven** `Exec*` stanzas, and the image build never creates any of them. A fifth, `arlowe-dashboard`, invokes `dashboard/server.js`, which no build step produces and which bookworm's Node 18 could not run even if it existed. Only `qwen-api` is unaffected: it execs the ax-llm binary through `run_api.sh` and touches no Python. Close those gaps and put a build-time gate behind them so the class cannot recur.

**Correction (plan 07.1-06, after execution): "six" is the count of shipping runtime *service* units, not the count of units in the image.** The distinction matters because `verify_unit_execstart` globs the built rootfs's own `/etc/systemd/system` rather than the repo's unit source directory, so the number it reports is larger and is supposed to be. A real rootfs carries **nine**: the six above, plus `arlowe-identity-init` (the seventh file in `units/`), plus `arlowe-firstboot` (from `pi-gen/stage-arlowe/03-firstboot/files/`), plus whatever apt installs there — today exactly one, `dbus-org.freedesktop.nm-dispatcher.service` from `network-manager`. The gate FAILed on that ninth unit on its first real rootfs run and it is now in `EXPECTED_UNDECLARED` with a reason. Enumeration and coverage boundary: `docs/operations/phase-7.1-substrate.md` §Part A.

**Depends on**: Phase 6 (image build), Phase 3 (unit definitions), Phase 1 (the runtime requirements.txt files)

**Requirements**: No new REQ-IDs. Closes latent gaps in USER-04, USER-05 (units must actually run as specified) and IMAGE-02 (the runtime stage must produce a runnable runtime).

**Why inserted**: Found during Phase 8 research (`.planning/phases/08-first-boot-pairing-and-wake-word/08-RESEARCH.md`). Phase 8 SC2 requires the pairing daemon to "start the runtime services"; that criterion is unreachable while the services cannot start at all. `scripts/provision/install-arlowe-fs.sh:51` records the original deferral in its own comment — *"venvs/ is empty in Phase 3; Phase 6 populates from runtime/*/requirements.txt"* — and Phase 6 never did. Kept out of Phase 8 so that a Phase 8 SC2 failure means "pairing is broken", not "the substrate was never there".

**Success Criteria** (what must be TRUE):
  1. A build-time gate parses every shipping unit's `ExecStart=` and `ExecStartPre=` and fails the build if the named interpreter or script is absent from the built rootfs. This is the durable fix; the venvs are one instance of it. Same shape as the `00-packages-nr` guard that caught F7 #18.
  2. All three venv interpreters — `/opt/arlowe/venvs/{voice,llm,stt}/bin/python` — exist in the built image and can import the module each of the seven `Exec*` stanzas invokes.
  3. `runtime/dashboard` produces `server.js`, `arlowe-dashboard.service`'s `ExecStart` target resolves in the built rootfs, **and the interpreter that unit actually names reports a version `next` will run** (>= 20.9.0; bookworm ships 18.20.4). Path existence alone does not satisfy this criterion — see SC1's stated limitation.
  4. Every Python import reachable from a unit entry point resolves under the image's own package set — verified in a `debian:bookworm` container built from `pi-gen/stage-arlowe/00-packages/00-packages-nr`, not from the host and not from `pip install -r`. **Delivered coverage is five units, not the four this line anticipated** (plan 07.1-05): `arlowe-identity-init` runs `/opt/arlowe/runtime/cli/identity`, which is `#!/usr/bin/env python3` and deliberately carries no `.py` extension so the CLI symlink installer produces `arlowe-identity`. An entry-point rule keyed on `-m` or `.py` skips it — and it is the single consumer whose missing `yaml`/`jsonschema` were this phase's original motivating defect (F7 #18), so that rule would have skipped the gate's own motivating case. The checker keys on the shebang as well, and checks it under system `python3` rather than a venv.
  5. `arlowe-voice` starts with no wake-word verifier pickle present (the factory state). `runtime/voice/voice_client.py:349` currently opens it unguarded while `runtime/wake-word/README.md` documents a verifier-absent path that the code does not implement. A test exercises the absent-verifier path.
  6. On a freshly flashed image, all six units reach `active` — hardware checkpoint, deferrable per Phase 1/3/4/5 precedent, but recorded as unproven until it runs.
     **STATUS: UNPROVEN.** Not run. No unit in this repo has been observed reaching `active` on a device. Procedure: `docs/operations/phase-7.1-substrate.md` §Part B. Everything SC1–SC5 rests on was verified in arm64 `debian:bookworm` containers, which on the build host were *emulated* — the version gate's `chroot` probe has never executed a real arm64 binary on real silicon. Tracked alongside the Phase 6 hardware checkpoint; both want the same card and the same bench session.

**Plans**: 6 plans in 4 waves — Wave 1: 07.1-01, 07.1-02, 07.1-03 · Wave 2: 07.1-04 · Wave 3: 07.1-05 · Wave 4: 07.1-06

Plans:
- [x] 07.1-01-PLAN.md — Dependency ledger: apt layer for the Debian-packaged compiled deps, **five** pinned venv requirement files + shared constraints (the voice set splits because `--no-deps` is not a valid requirements-file directive), **Node 24 decision**, ADR-0008 (Wave 1, foundational)
- [x] 07.1-02-PLAN.md — SC5: stdlib-only `voice/wake_gate.py`, unguarded pickle load removed, absent/corrupt-verifier tests, wake-word README reconciled with the code (Wave 1)
- [x] 07.1-03-PLAN.md — SC1: `verify_unit_execstart` (path) + `verify_unit_runtime_versions` (interpreter version floor) gates deriving expectations from the rootfs's own units, fixture self-test whose negative cases reproduce the pre-fix image AND the bookworm-Node-18 trap, wired into build-image.sh beside the packages guard (Wave 1)
- [x] 07.1-04-PLAN.md — SC2+SC3: `build-venvs.sh` + `build-dashboard.sh` in the chroot, `output: "standalone"`, **vendored Node 24** named explicitly by the dashboard unit's ExecStart, pnpm pinned via `packageManager`, stale install-arlowe-fs.sh comment corrected (Wave 2, depends on 07.1-01, 07.1-03)
- [x] 07.1-05-PLAN.md — SC4: unit-derived import-graph checker using `find_spec` with version-drift WARNs, debian:bookworm container that invokes the real `build-venvs.sh`, `unit-import-bookworm` CI job on arm64 (Wave 3, depends on 07.1-01, 07.1-02, 07.1-04 — 04 owns the venv builder the container reuses)
- [x] 07.1-06-PLAN.md — SC6: substrate runbook (`docs/operations/phase-7.1-substrate.md`) + ROADMAP/REQUIREMENTS traceability delivered; **the SC6 hardware checkpoint itself is NOT run — SC6 is UNPROVEN** (Wave 4; non-autonomous, deferrable per Phase 1/3/4/5 precedent, depends on 07.1-01..05)

**Node correction (plan 07.1-06):** the two lines above read "Node-20 floor decision" and "vendored Node 20" as written at plan time. Both predate ADR-0008 and are corrected above. The image ships **Node 24.21.0 "Krypton"**, SHA-256 pinned in `third_party/node/manifest.yml`. Node 20 "Iron" reached end of life on **2026-04-30**, so shipping it would bake a permanently unpatched JS runtime into v1. **The floor is unchanged at `>= 20.9.0`** — that number comes from `next@16.1.6`'s own `engines` metadata, not from the chosen runtime, and 24 clears it.

**Findings added during planning** (not in the original insertion brief, both verified in an arm64 `debian:bookworm` container):
  - Debian bookworm's `nodejs` is **18.20.4**; `next@16.1.6` declares `engines.node >= 20.9.0`. Even once `server.js` exists, `/usr/bin/node` cannot execute it. The SC1 gate cannot catch this — it proves a path resolves, never that the binary there can run what it is handed. Resolved in ADR-0008 (plan 07.1-01) and asserted in plan 07.1-04.
  - `runtime/dashboard` uses **pnpm** (`pnpm-lock.yaml`, `pnpm-workspace.yaml`, no `package-lock.json`), so the image build cannot use `npm ci`. CI already pins pnpm 10 for this reason.
  - The dev pins in `runtime/*/requirements.txt` (`numpy==2.3.5`, `Pillow==11.1.0`) are not installable against bookworm's system layer (numpy 1.24.2, Pillow 9.4.0). A naive resolve shadows the apt numpy and floats onnxruntime/matplotlib to latest, breaking Phase 6 SC5 input reproducibility. Hence the separate pinned image-only requirement files.

### Phase 8: First-boot pairing and wake word

**Goal**: A factory-fresh image boots into a pairing daemon, captures Wi-Fi + owner account + device name, requests a device cert, writes the config overlay, and starts the runtime services. The generic "Hey Arlowe" model ships in the image. Factory reset returns the unit to the pairing state.

**Depends on**: Phase 4 (config overlay), Phase 6 (image), Phase 7 (PKI for cert request), Phase 7.1 (runtime substrate)

**Phase 7.1 closed the substrate, which is what this phase's SC2 was blocked on.** SC2 requires the pairing daemon to "start the runtime services". Before 7.1 that criterion was unreachable: `/opt/arlowe/venvs` was empty, `dashboard/server.js` did not exist, and no build step produced either — so a failing SC2 would have been ambiguous between "pairing is broken" and "the services were never startable". That ambiguity is the stated reason 7.1 was inserted rather than folded into this phase. **A Phase 8 SC2 failure now means pairing is broken.** One caveat before relying on it: 7.1's SC6 is UNPROVEN — the six units have been shown startable in containers, not on a device. If Phase 8 runs on hardware before that checkpoint does, Phase 8 inherits it, and `docs/operations/phase-7.1-substrate.md` §Part B should be run first so a failure can still be attributed.

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

**Goal**: Prove end-to-end that the v1 ship target works. Flash a factory-fresh Pi 5 + AX accelerator + Whisplay from a freshly built image, pair it as a fake owner, and run the full wake -> STT -> LLM -> TTS -> face loop. This is the v1 acceptance gate AND the canonical first-flash sanitized smoke test that Phase 1 plan 13 deferred to here.

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
Phases execute in numeric order: 1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7 -> 7.1 -> 8 -> 9 -> 10 -> 11 -> 12

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Runtime extraction | 15/15 | Complete (qualified — SC4 hardware loop deferred to Phase 12; see plan 13 SUMMARY F1-F4) | 2026-05-17 |
| 2. Sanitization gate | 4/4 | Complete | 2026-05-27 |
| 3. Service user and filesystem layout | 5/5 | Complete (passed-with-notes; #73–#75 cleanups merged) | 2026-06-07 |
| 4. Config overlay | 4/4 | Complete (passed-with-notes; SC4 on-device check deferred to Phase 6/12) | 2026-06-07 |
| 5. Audio device auto-detection | 7/7 | Complete (passed-with-notes; on-Pi SC1-4 deferred to hardware checkpoint) | 2026-06-13 |
| 6. Image build with A/B partitions | 6/6 | Complete in code; HARDWARE CHECKPOINT IN PROGRESS (started 2026-06-19, paused — see STATE.md) | 2026-06-14 |
| 7. Device identity and PKI | 10/11 | Waves 1-6 executed; 07-09 PARKED (needs AWS staging account). SC1-SC3 satisfied, SC4 unverified | - |
| 7.1 Runtime substrate repair (INSERTED) | 6/6 | Complete in code (passed-with-notes; SC1–SC5 verified in arm64 bookworm containers). **SC6 deferred to a hardware checkpoint, procedure in `docs/operations/phase-7.1-substrate.md`** — UNPROVEN until run | 2026-09-12 |
| 8. First-boot pairing and wake word | 0/TBD | Not started | - |
| 9. App-only OTA | 0/TBD | Not started | - |
| 10. Owner-consented support access | 0/TBD | Not started | - |
| 11. Boot health, dashboard surfaces, and log management | 0/TBD | Not started | - |
| 12. First-flash integration on real hardware | 0/TBD | Not started | - |

---
*Roadmap created: 2026-04-30*
*Coverage: 92/92 v1 requirements mapped, 0 unmapped*
