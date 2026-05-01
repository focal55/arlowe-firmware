# arlowe-firmware

## What This Is

`arlowe-firmware` is the OS image and on-device runtime for **Arlowe** — a physical, local-first AI assistant on Raspberry Pi 5 + Axera AX8850 + Whisplay display. Every customer device flashes the same image, then pairs to its owner at first boot. Voice in → on-device STT → on-device LLM → on-device TTS → Whisplay face, with no cloud round-trip in the default path.

This repo ships **only** the customer-facing product. The founder's personal Claude Code / agentic workforce tooling lives in the separate `focal55/agentic-workforce` repo and must never touch a customer unit.

## Core Value

A factory-fresh Pi 5 + AX accelerator + Whisplay can flash this image, boot, pair to an owner, and run wake → STT → LLM → TTS → face entirely on-device, with no founder identity present anywhere in the image.

## Requirements

### Validated

(None yet — pre-extraction. The runtime currently lives on the founder's dev unit, Arlowe-1, in a private monorepo. Nothing has been validated *as a customer product*.)

### Active

<!-- v1 hypotheses. Each gets exploded into REQ-IDs in REQUIREMENTS.md. -->

- [ ] **Runtime extraction** — voice/face/STT/TTS/LLM/wake-word/dashboard/CLI moved out of `iol-monorepo/packages/whisplay/` into this repo's `runtime/`, sanitized of all founder literals
- [ ] **Sanitization gate** — CI grep-fails on any reappearance of `focal55`, `arlowe-1`, `casa_ybarra_chelsea`, founder email, or `/home/focal55/...`
- [ ] **Dedicated service user** — runtime runs as `arlowe` system user, code at `/opt/arlowe/`, state at `/var/lib/arlowe/`; no `--user` systemd units
- [ ] **Audio device auto-detection** — USB audio enumerated at boot; no hardcoded `plughw:2,0`; owner override via dashboard
- [ ] **Config overlay** — schema-validated `/opt/arlowe/config/defaults.yml` + writable `/etc/arlowe/config.yml`; every literal in current scripts flows through this
- [ ] **Provisioning + first-boot pairing** — managed-PKI device cert issued during pairing; pairing binds device to owner account, captures Wi-Fi credentials, optional voice profile; absent `/etc/arlowe/config.yml` forces pairing
- [ ] **Generic wake word** — "Hey Arlowe" model trained against many voices ships in v1; opt-in owner personalization exposed in dashboard
- [ ] **Image build pipeline (pi-gen)** — reproducible flashable SD image: base Pi OS, `axcl_host.deb`, ALSA, NetworkManager, `/opt/arlowe/runtime/`, models
- [ ] **A/B system partition layout** — system A (active) + system B (standby) + `/boot` + `/var/lib/arlowe` (owner state) **designed and provisioned in v1**, even though OS OTA delivery defers to v2+
- [ ] **App-only OTA agent** — signed manifest pulled from CDN, rsync into `/opt/arlowe/runtime/`, atomic per-service restart
- [ ] **Owner-consented support access** — dashboard "support mode" toggle provisions a time-bound (24h default) founder SSH key, auto-revokes, all commands logged to a file the owner can review; default-deny

### Out of Scope

- **OS OTA delivery in v1** — partitions designed and provisioned in v1, but image-swap delivery defers to v2+. Recovery SD card image is the v1 fallback.
- **Model OTA** — defers to v1.1+. v1 ships fixed model artifacts in the image.
- **Multi-device coordination** — one Arlowe per home; no fleet awareness across homes.
- **Cloud-required features** — every cloud path is opt-in; defaults are local. Privacy is the differentiator.
- **Custom hardware / PCB redesigns** — Pi 5 + AX accelerator + Whisplay is the v1 platform.
- **Founder remote dev access on customer units** — only the owner-consented, time-bound, audit-logged support mode above.
- **Founder-only services** — `openclaw-*`, `trace-*`, `workforce-metrics-snapshot.*`, the entire `agentic-workforce` repo. None ship.
- **`iol_router.py`** — extract a clean version or stub during the extraction phase; do not ship founder IOL integration.
- **`arlowe-scheduled-summary.service`** — extract decision deferred until extraction phase; if founder-only, strip.
- **Messaging adapters** (Discord/Telegram/etc.) — deferred until pairing/identity exist.
- **Buildroot / Yocto image systems** — premature; reconsider only if image size or boot time become real customer-facing constraints.
- **Custom CA / rolling our own crypto** — use a managed PKI service.

## Context

**Pre-extraction.** The runtime lives today on **Arlowe-1**, the founder's Raspberry Pi 5 dev unit at `arlowe-1.local`, inside the private `iol-monorepo` at `packages/whisplay/` and `packages/arlowe-dashboard/`. The strategic audit captured in `docs/01-context.md` through `docs/06-open-decisions.md` (2026-04-30) is the authoritative source for what to extract, what to leave behind, and why.

**Two Arlowes, never confused:**

- **Arlowe-1** (n=1, founder's dev unit) — mirrors the Mac's `~/.claude/`, runs the agentic-workforce loop. **This repo does not ship to dev units.**
- **Arlowe** (n=many, customer product) — clean image, no founder identity. **This repo ships to product units.**

Conflating the two is the #1 mass-production trap the audit calls out.

**On-device runtime stack today (proven on Arlowe-1):**

- LLM: Qwen 2.5 7B int4 on the AX8850 (`ax-llm` runtime, OpenAI-compat shim on top)
- Smaller alt: Qwen 2.5 1.5B int4 (low-power / fallback dispatch)
- STT: `faster-whisper` (Python venv)
- TTS: Piper (`en_US-lessac-medium.onnx`)
- Wake word: custom training pipeline at `~/wake_word/` (currently founder-voice biased)
- Face: `face_service.py` on tcp/8080 (Whisplay)
- Orchestrator: `voice_client.py` ties wake → STT → LLM → TTS → face
- Dashboard: Next.js on tcp/3000

**Service start order proven on Arlowe-1:** `qwen-tokenizer` → `qwen-api` → `qwen-openai`; `whisper-stt` independent; `arlowe-face` → `arlowe-voice`. `~/bin/boot-check` is the seed for automated post-boot validation. `~/bin/purge-logs` (7-day retention + truncate-on-size) is the seed for log management defaults.

**Personal literals to parameterize** (full list in `docs/04-scope.md`):

| Literal | Replacement |
|---|---|
| `casa_ybarra_chelsea` (Wi-Fi SSID) | Owner-provisioned at pairing |
| `plughw:2,0` (audio) | USB enumeration at boot, dashboard override |
| `arlowe-1` (hostname) | `arlowe-${device_serial}` from device-unique ID |
| `/home/focal55/...` paths | `/opt/arlowe/` (code) + `/var/lib/arlowe/` (state) |
| `focal55` (system user) | Dedicated `arlowe` system user |
| `~/iol-monorepo/...` (founder repo paths) | `/opt/arlowe/runtime/` |

## Constraints

- **Hardware**: Pi 5 Model B Rev 1.1 + Axera AX8850 (M.2 PCIe, exposed as `/dev/axcl_host` and `/dev/ax_mmb_dev`) + Whisplay + USB audio + Wi-Fi (no ethernet assumed) — Fixed v1 platform; no PCB redesigns.
- **Privacy**: Voice transcripts and conversation history stay on-device unless the owner explicitly opts in to cloud sync — Differentiator vs Echo/Nest; also a regulatory commitment.
- **Identity**: Pi 5 has no TPM — Use provisioning-server-issued device certs (managed PKI), not device-derived hashes.
- **Image size**: ~8 GB driven by Qwen 2.5 7B int4 model artifacts — Forces 16 GB+ SD card minimum; affects flashing time per device.
- **Kernel modules**: `axcl_host_aarch64_V3.10.2.deb` ships in image; AX userspace runtime is a hard dependency for LLM inference — Pin Axera SDK version explicitly; vendor `ax-llm` as a submodule.
- **Identity hygiene**: No code in this repo may reference `focal55`, `arlowe-1`, `casa_ybarra_chelsea`, the founder email, or any `/home/focal55/...` path — CI must fail if these reappear. This is non-negotiable.
- **Owner state**: Pairing data, conversation cache, logs, config overlay live on the `/var/lib/arlowe` partition only — Survives image OTAs (when they ship); separate from system A/B partitions.
- **Workforce protocol**: This project uses the agentic workforce protocol from global `~/.claude/CLAUDE.md`. After phase planning, run `/issue-from-plan` to populate the GitHub Project board.

## Key Decisions

| Decision | Rationale | Outcome |
|---|---|---|
| Extract `whisplay/` + `arlowe-dashboard/` from `iol-monorepo` into this repo | Customer code must not share git history with private workforce tooling | — Pending |
| Dedicated `arlowe` system user; code at `/opt/arlowe/`; state at `/var/lib/arlowe/` | Image reproducibility; isolates support-mode SSH from founder account | — Pending |
| Two-file config overlay: `defaults.yml` (image) + `/etc/arlowe/config.yml` (owner overlay), schema-validated | Parameterizes every personal literal; mutable through dashboard; no env-var sprawl | — Pending |
| pi-gen for image build | Debian-friendly, well-known; Buildroot/Yocto cost weeks of build-system tax for marginal v1 gain | — Pending |
| **A/B system partition layout designed and provisioned in v1, even though OS OTA delivery defers to v2+** | Partition layout is unfixable post-ship; retrofit means fleet-wide reflash. Complexity concentrates at image-build + first-boot; runtime is unchanged. | — Pending |
| App-only OTA in v1; model OTA in v1.1+; OS OTA delivery in v2+ | Match scope to risk: app rsync is low-risk; model swap is medium; OS swap on consumer hardware needs a real failure mode to design against | — Pending |
| Managed-PKI provisioning server for device identity | No TPM on Pi 5; rolling own CA is a security liability; managed PKI ties identity cleanly to customer account from day 1 | — Pending |
| Owner-consented gated support access (dashboard toggle, time-bound key, audit-logged, default-deny) | Retrofitting consent UX after units are in homes is hostile; design it now | — Pending |
| Generic "Hey Arlowe" wake-word model in v1; opt-in owner personalization via dashboard (post-pairing) | Avoids per-customer training infrastructure at scale; personalization is a feature, not a v1 blocker | — Pending |

---
*Last updated: 2026-04-30 after initialization*
