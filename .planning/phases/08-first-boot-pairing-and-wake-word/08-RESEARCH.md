# Phase 8: First-boot pairing and wake word - Research

**Researched:** 2026-09-28 (supersedes the 2026-09-12 version, which predated Phases 7.1, 7.2 and 7.3)
**Domain:** NetworkManager AP captive portal, privilege separation under systemd/polkit, claim-code broker, Next.js 16 session auth, openWakeWord custom training, factory reset
**Confidence:** HIGH on repo facts (every claim cites `file:line` on `main` at `0b45c18` plus `08-CONTEXT.md`) and on the upstream sources read directly (NetworkManager 1.42.4 source, the Pi-archive `network-manager` deb, the pinned pi-gen tag, the openWakeWord git history, the Node 24 docs source, the Debian snapshot index). MEDIUM on design recommendations. LOW items are marked.

---

## Summary

Phase 7.1 made SC2's "start the runtime services" reachable, but in a way the Phase 8 context did not account for. **Since `dfb3763` (2026-09-20), `units/install-units.sh:32-48` links every unit into its `WantedBy=` target, so all six runtime units are enabled at build time and run on an unpaired device.** The SC6 evidence proves it: six of six `active` from a clean flash with `/etc/arlowe/config.yml` absent (`docs/operations/phase-7.1-substrate.md:695-731`). So `arlowe-face` already holds the Whisplay GPIO when the pairing daemon would want it, and the unauthenticated dashboard is already listening on `:3000` while the device would be broadcasting an open setup network. The locked specific "pairing must `systemctl enable --now` the six units" solved a problem that no longer exists. The real Phase 8 problem is the opposite one: keep the six units down until pairing commits. The fix is small: add `ConditionPathExists=/etc/arlowe/config.yml` to the six units and make `config.yml` the single atomic commit point. After that, pairing only has to `systemctl start` them, which the existing polkit rule already allows (`provision/polkit/50-arlowe-systemctl.rules:18-33`), and a reset only has to remove `config.yml` and reboot.

The second group of findings is about what an open AP exposes on this image. The Wi-Fi radio ships disabled. With `WPA_COUNTRY` unset, pi-gen writes `WirelessEnabled=false`, and `raspberrypi-sys-mods` sets `rfkill default_state=0`. Every NetworkManager action pairing needs is denied to a no-session system user, per the policy file actually in the Pi-archive `network-manager` deb. **B5 still stands in code**: `pi-gen/config:25,50-51` bakes `pi`/`raspberry` and `ENABLE_SSH=1`, `SKIP_IMAGES=1` skips pi-gen's user-rename stage, and `raspberrypi-sys-mods` gives `pi` passwordless sudo. That leaves root reachable over SSH by anyone who joins the open setup network. The open hotspot also carries the owner's home Wi-Fi PSK, dashboard password and claim code in cleartext over the air. That follows from the locked "open hotspot" decision, and the ADR must say so in plain words.

The wake-word half changed as well. **The embedding model bundled in `openwakeword==0.4.0` is a different model from the one the upstream training pipeline uses.** On identical mel input the measured cosine similarity was 0.97-0.99, with up to 28% relative deviation. A "hey arlowe" classifier trained with the current recipe and run under the device's 0.4.0 feature extractor would therefore see shifted inputs. The same 0.4.0 wheel also puts six CC BY-NC-SA wake models, `hey_jarvis` among them, into every image under the voice venv. Upgrading the device to `openwakeword==0.6.0` (installed `--no-deps`, run with `inference_framework="onnx"`) and shipping the three ONNX files on the models partition fixes both problems.

**Primary recommendation:** plan Phase 8 in four tracks:
- **A. Substrate corrections first:** gate the six units on `config.yml`, close B5, make `boot-check` paired-aware.
- **B. Pairing** split across two processes: an unprivileged `arlowe-pair` web/Whisplay daemon (NetworkManager access through one new polkit rule), and root oneshots for the hostname commit and the factory reset, started through the existing `arlowe-` polkit prefix.
- **C. Dashboard auth** on Node 24's built-in `crypto.argon2` plus an HMAC session cookie checked in `proxy.ts`.
- **D. Wake word.** Split it into its own phase (8.1). Its critical path runs through GPU training cycles, recorded voices and a go/no-go gate that should not hold pairing merges hostage.

---

## What changed since 2026-09-12

| Old research said | Current state (verified) | Evidence |
|---|---|---|
| B1: `/opt/arlowe/venvs` empty | **Closed.** Venvs built in the chroot | `pi-gen/stage-arlowe/01-runtime/files/build-venvs.sh`; ROADMAP 7.1 SC2 |
| B2: PIL/numpy absent | **Closed.** `python3-pil`, `python3-numpy` from apt | `pi-gen/stage-arlowe/00-packages/00-packages-nr:125,133` |
| B3: no `server.js` | **Closed.** Standalone build on vendored Node 24.21.0 | `runtime/dashboard/next.config.ts` (`output: "standalone"`); `units/arlowe-dashboard.service` ExecStart `/opt/arlowe/node/bin/node`; `third_party/node/manifest.yml` |
| B4: verifier pickle crash | **Closed.** `runtime/voice/wake_gate.py` degrades to generic at 0.7 | `wake_gate.py:36-38,47-60`; SC6 journal line in `phase-7.1-substrate.md:733-738` |
| "Six units ship installed-but-disabled; pairing enables them" | **False since `dfb3763` (2026-09-20).** All six are enabled at build and run unpaired | `units/install-units.sh:32-48`; `phase-7.1-substrate.md:695-731` (6/6 active, config absent). Stale comments that still say otherwise: `pi-gen/stage-arlowe/03-firstboot/00-run-chroot.sh:151-156`, `phase-7.1-substrate.md:480-482`, `provision/polkit/50-arlowe-systemctl.rules:6` |
| B6 SSID shell injection | **Closed for connect/saved** (`execFile` argv, `c0aa810`, #136). Auth is still commented out, and there is still no NM polkit rule | `runtime/dashboard/app/api/connectivity/connect/route.ts:2-18`; `saved/route.ts:6-15,55` |
| B8 volatile journal | **Closed.** Persistent journal bind-mounted from owner_state | `01-runtime/00-run-chroot.sh:353-384`; `scripts/lib/verify-persistent-journal.sh` |
| Packages come from rolling archives | **Debian from snapshot `20260915T000000Z`; Pi packages only from a digest-pinned flat repo** | `overlays/pi-gen/stage0/00-configure-apt/files/sources.list:27-29`; `third_party/pi-archive/manifest.yml`; `docs/operations/phase-07.3-pi-archive-pinning.md` §1, §4 |
| `onnxruntime==1.23.2` on device | `onnxruntime==1.30.0` | `pi-gen/stage-arlowe/01-runtime/files/venv-requirements/voice.txt` |
| `third_party/whisplay-driver/` has no driver; API read from upstream `main` | Still not committed. The dev copy is 344 lines (F2); upstream commit `bde2b83` (2026-01-02) is the only 344-line `Driver/WhisPlay.py` in history, and its API is below | `.planning/todos/pending/F2-vendor-whisplay-driver.md`; PiSugar/Whisplay history |
| "Recovery display uses nonexistent `ShowImage`" | Still true | `runtime/recovery/arlowe-recovery.sh:105` |

---

## Blocker re-verification (B5, B6, B7, B9) against `main`

| # | Status | Evidence |
|---|---|---|
| **B5** SSH + default login | **STANDS (HIGH on SSH enabled; MEDIUM on the password being usable, see note).** `pi-gen/config:25` `ENABLE_SSH=1`, `:50-51` `FIRST_USER_NAME="pi"`/`FIRST_USER_PASS="raspberry"`, `:55` `DISABLE_FIRST_BOOT_USER_RENAME=0`. Upstream `stage1/01-sys-tweaks/00-run.sh` runs `chpasswd` with that password, and `stage2/01-sys-tweaks/01-run.sh` runs `systemctl enable ssh`. The rename that would neutralise `pi` lives in `export-image/01-user-rename/01-run.sh`, which never runs because `scripts/build-image.sh:283` builds with `SKIP_IMAGES=1`. `raspberrypi-sys-mods` ships `/etc/sudoers.d/010_pi-nopasswd` (`pi ALL=(ALL) NOPASSWD: ALL`, read from the pinned deb). CI does the same thing: `.github/workflows/build-image.yml:120` `ENABLE_SSH=1`. | **Contradiction to resolve with one command:** `03-firstboot/00-run-chroot.sh:84` and `files/arlowe-userconf:4` claim "the factory image ships NO login account", while F8 (`.planning/todos/pending/F8-image-ships-default-creds-ssh.md`) and STATE (2026-09-08/10) record `pi`/`raspberry` logins on built images. The code supports F8. Settle it on build A's rootfs: `sudo awk -F: '$1=="pi"{print substr($2,1,3)}' <rootfs>/etc/shadow` (`$6$` means usable). Either way, the fix below closes it. |
| **B6** dashboard Wi-Fi routes | **Injection CLOSED; authorization STANDS (HIGH).** `connect/route.ts:4,16-18` has `verifyAuth` commented out. `saved/route.ts:55` calls it, but `verifyAuth` requires `DASHBOARD_API_SECRET` (`app/api/middleware/auth.ts:14-26`), which `units/arlowe-dashboard.service` never sets, so that DELETE always returns 403. Every other mutating route has no auth at all: `config/route.ts:54`, `voice/route.ts:71`, `npu/chat/route.ts:5`, `npu/benchmark/route.ts:85`. The polkit half is confirmed from source (N3): `nmcli` run as `arlowe` from a service is denied. The remaining `exec()` shell strings (`connectivity/status/route.ts:12-52`, `networks/route.ts:13-17`, `health/route.ts:19-25`, `npu/status/route.ts:10-28`, `logs/route.ts:106`) interpolate no request data (LOW risk). | — |
| **B7** slot B never booted | **STANDS (HIGH).** No change since STATE 2026-09-10 (`.planning/STATE.md:37-43`). The only later slot-B-adjacent commit is `2949627` (Whisplay device tree). Factory reset must not route through slot B. | `git log --since=2026-09-11 -- runtime/cli/ab scripts/lib/boot-config.sh runtime/recovery` |
| **B9** boot-check vs unpaired device | **STANDS and is worse than recorded (HIGH).** `runtime/cli/boot-check:147-163` checks every service and port unconditionally, including a nonexistent `qwen-openai`. The `--first-boot` flag passed by `arlowe-firstboot.service` is never parsed (no `$1`/getopts anywhere in the 200-line file). It never prints "ready to pair" and always exits 0 (`phase-7.1-substrate.md:545-548`). `paired` is computed only inside `check_identity` (`:64,70`). Once N1's gating lands, an unpaired device will report 13 FAILs by design. | — |

---

## New findings the planner must absorb

**N1. The six runtime units run on an unpaired device (HIGH).** See Summary. Consequences:
- `arlowe-face` owns the GPIO chips while pairing needs the display and button.
- `arlowe-dashboard` (no auth) listens on `0.0.0.0:3000` and would be reachable from the open setup network.
- `arlowe-voice` listens on the microphone before anyone has paired.

Recommended mechanism: add `ConditionPathExists=/etc/arlowe/config.yml` to the six units and keep them enabled at build. Pairing writes `config.yml` last, then `systemctl start`s them (the existing `manage-units` rule covers all six names). Reset removes `config.yml` first. This is crash-safe in both directions. A power cut at any point leaves either "unpaired, units skip, pairing runs" or "paired, units run", never "units enabled but no config".

Here a `Condition*` means "not paired, don't run", which is the intended state and not a failure. That is not the silent-no-op trap `units/arlowe-identity-init.service:5-16` warns about, which concerns a unit that must always run. `boot-check` must report the skip explicitly (B9).

**N2. Wi-Fi is disabled on the image (HIGH).**
- Pinned pi-gen `stage2/02-net-tweaks/01-run.sh`: with `WPA_COUNTRY` unset it writes `/var/lib/NetworkManager/NetworkManager.state` with `WirelessEnabled=false`.
- `raspberrypi-sys-mods` ships `/etc/modprobe.d/rfkill_default.conf` = `options rfkill default_state=0` (read from the pinned deb).
- STATE recorded "wifi rfkill-blocked" on test cards.

Before the AP can come up, something privileged must run `rfkill unblock wlan` and `nmcli radio wifi on`, and must set a regulatory domain. Setting the domain through `raspi-config do_wifi_country` edits `cmdline.txt`, which the A/B `boot-config.sh:156-160` owns, so do not use it. Use `iw reg set <CC>` at runtime plus a persistent `/etc/modprobe.d/` `cfg80211 ieee80211_regdom=<CC>` (MEDIUM: assumes `cfg80211` is a module on the Pi kernel, which `brcmfmac`'s dependency implies; verify with `lsmod` on hardware). The country is an open question.

**N3. NetworkManager polkit, read from the shipped policy (HIGH).** From the Pi-archive deb `network-manager_1.42.4-1+rpt1+deb12u1_arm64.deb`, `usr/share/polkit-1/actions/org.freedesktop.NetworkManager.policy`:

| Action | allow_any | allow_inactive | allow_active |
|---|---|---|---|
| `network-control` | auth_admin | yes | yes |
| `wifi.scan` | auth_admin | yes | yes |
| `wifi.share.open` | (unset = no) | no | yes |
| `enable-disable-wifi` | (unset = no) | no | yes |
| `settings.modify.system` | auth_admin_keep | auth_admin_keep | auth_admin_keep |

The same deb's `usr/share/polkit-1/rules.d/org.freedesktop.NetworkManager.rules` grants `settings.modify.system` only to `subject.local && subject.active && (sudo|netdev)`. A systemd service has no session, so polkit evaluates `allow_any`. `arlowe` is therefore denied every action pairing and the dashboard Wi-Fi routes need. The fix is one sibling rule, `provision/polkit/51-arlowe-networkmanager.rules` (code below). It is picked up automatically by `scripts/provision/install-arlowe-udev-polkit.sh`, which installs `provision/polkit/*.rules`. The image has polkitd 122-3 (JS rules; `polkitd-pkla` is not installed), per `docs/operations/phase-07.2-inputs.reference`.

**N4. The device's openWakeWord feature extractor differs from the training pipeline's (HIGH measured, MEDIUM on impact).**
- `openwakeword==0.4.0` bundles `embedding_model.onnx` sha256 `ba754db3…`, 1,328,103 B.
- The upstream training notebook installs the v0.5.1 release asset, sha256 `70d16429…`, 1,326,578 B.
- `melspectrogram.onnx` is byte-identical in both (`ba2b0e0f…`).
- Run under onnxruntime 1.23.2 on the same mel windows, the two embeddings agree at cosine 0.97-0.99 with up to 28% relative max deviation. The preprocessing constants are unchanged (`x/10+2`, 76-frame windows, step 8), and 0.6.0's `utils.py:180,225` matches 0.4.0's `utils.py:74,119`.

Ship the v0.5.1 feature models with the classifier, and pass their paths explicitly.

**N5. Every current image already ships six non-commercial wake models (HIGH).** The `openwakeword-0.4.0-py3-none-any.whl` contains `alexa_v0.1`, `hey_jarvis_v0.1`, `hey_marvin_v0.1`, `hey_mycroft_v0.1`, `timer_v0.1`, `weather_v0.1` (`.onnx`) under `openwakeword/resources/models/`, and `build-venvs.sh` installs it into `/opt/arlowe/venvs/voice`. "`hey_jarvis` gone from every shipped code path" is not satisfied by editing Python. The bytes are in the image. `openwakeword-0.6.0-py3-none-any.whl` contains **no** model files (verified with `unzip -l`), which is the clean way out.

**N6. The four SC3 failure modes do not map onto four distinct `arlowe-identity` exit codes (HIGH).**
- Bad claim code: broker 401 → `ProvisioningRejected` → exit 3.
- Broker rejection (for example `csr_subject_mismatch`): 400 → also exit 3.
- AWS issuance failure: 502 → `status_code >= 500` → `CloudUnavailable` → exit 4 (`runtime/lib/arlowe_cloud.py:229-230`).
- Transport failure: also exit 4.

Keep the frozen exit codes (`runtime/cli/identity:20-23,50-55`) and add detail rather than a taxonomy. On failure with `--json`, emit `{"ok": false, "exit": N, "error": "<reason>", "http_status": N|null}`. That needs `ProvisioningRejected.status` (already present, `arlowe_cloud.py:71`) plus a `status` attribute on `CloudUnavailable` for the 5xx path. Mapping: exit 4 with no status → "can't reach Arlowe servers". Exit 3 with 401 → "setup code not accepted". Exit 3 with another status, or exit 4 with 502 → "couldn't get device certificate". Wrong PSK never reaches identity; it is NetworkManager's.

**N7. "Single-use claim code" collides with "new identity on reset" (HIGH, design gap).**
- Reset regenerates entropy, which gives a new `device_id` (`runtime/lib/arlowe_identity.py` `derive_device_id`/`ensure_entropy`).
- A strictly single-use code is spent on first pairing, so the owner cannot re-pair after a reset with the card in the box.
- If the broker marks the code used and the 200 response is then lost in transit, the owner is stuck too.

Recommended semantics:
- A code binds to the first `device_id` that redeems it, and re-redemption by that same `device_id` is idempotent.
- The device's revoke-on-reset call releases the binding.
- A reset that could not revoke (offline) leaves the code bound to the orphaned id; releasing it is an operator action (`claim-codes release`).

This is a decision the plan must record (open question 2).

**N8. The open setup AP carries secrets in cleartext (HIGH).** HTTP over an open 802.11 network is sniffable by anyone in radio range. That covers the home Wi-Fi PSK, the dashboard password and the claim code. WebCrypto is unavailable on `http://` origins, so client-side encryption is not an option. RFC 8908's captive-portal API must be served over HTTPS (RFC 8908 §4), so DHCP option 114 is not usable either without a trusted certificate. The locked decision stands. The ADR must state this exposure explicitly. The cheapest mitigation that keeps the camera-scan UX is a per-boot random WPA2 passphrase embedded in the Whisplay QR (`WIFI:T:WPA;S:…;P:…;;`), shown as text for manual joins. That would amend the locked decision, so the owner's call.

**N9. Dashboard CI runs Node 20; `crypto.argon2` needs Node ≥ 24.7.0 (HIGH).** `.github/workflows/ci.yml:246-325` and `sanitize.yml:69-71` pin `node-version: '20'`. The device runs 24.21.0 (`third_party/node/manifest.yml`). The auth plan must bump CI to 24 in the same PR, or tests pass against a runtime the device doesn't have (and the inverse).

**N10. Sequencing against 07.3-09 (MEDIUM).** Build B must pass the inputs diff gate "without accept … from the commit containing 08's reference" (`.planning/phases/07.3-pi-archive-snapshot/07.3-09-PLAN.md:18,92`). Any Phase 8 PR that changes `00-packages-nr` or `third_party/models/manifest.yml` moves `pkg`/`pin` rows. If it merges before build B runs, build B from `main` fails the gate or needs an accept, which destroys 07.3 SC4's evidence. Either land Phase 8's image-affecting changes after 07.3-09 closes, or run build B pinned to the 07.3-08 commit.

**N11. The factory image has no broker URL (HIGH, open question).** `identity.provisioning_url` defaults to `""` and is "never a tracked literal" (`config/schema.yml:229-235`; `config/defaults.yml`). The pairing daemon cannot ask the owner for it. For the local-broker checkpoint, inject it (and `ARLOWE_BROKER_CA_BUNDLE` for the self-signed broker) through a dev-only file on the FAT partition, the same pattern as `userconf.txt`. Production supply waits on the AWS decision (07-09).

---

## Standard Stack

### Device-side packages (all verified against snapshot `20260915T000000Z` bookworm/main/arm64 and the live Pi index on 2026-09-28)

| Package | Version | In image today? | Source | Purpose |
|---|---|---|---|---|
| `network-manager` | 1.42.4-1+rpt1+deb12u1 | yes | Pi flat repo (pinned) | AP (`mode ap`, `ipv4.method shared`), join |
| `dnsmasq-base` | 2.90-4~deb12u2 | yes | Debian | DHCP+DNS for shared mode |
| `nftables` | 1.0.6-2+deb12u2 | yes | Debian | NM shared-mode NAT backend |
| `iptables` | — | **no, not needed** | — | NM 1.42.4 `_firewall_backend_detect()` returns nftables when `/usr/sbin/nft` is executable (`src/core/nm-firewall-utils.c` at tag 1.42.4) |
| `avahi-daemon` | 0.8-10+deb12u1 | yes | Debian | `.local` advertisement (DASH-01) |
| `polkitd` | 122-3 | yes | Debian | JS rules in `/etc/polkit-1/rules.d` |
| `python3-pil` | 9.4.0-1.1+deb12u1 | yes | Debian | Whisplay rendering |
| `fonts-dejavu-core` | 2.37-6 | **installed, undeclared** | Debian | TrueType text on Whisplay. Declare it in `00-packages-nr` when referenced (no `pkg` row change). This contradicts the comment at `00-packages-nr:128-132`, which assumed it was absent |
| **`python3-qrcode`** | 7.4.2-2 | **no — add** | Debian only (absent from Pi index) | Whisplay QR. Pulls `python3-png` 0.20220715.0-1 and `python3-typing-extensions` 4.4.0-1 (both Debian-only, both new) |
| **`python3-argon2`** | 21.1.0-2 | **no — add** | Debian only | Argon2id hashing in the Python pairing daemon. Its deps `libargon2-1` (0~20171227-0.3+deb12u1) and `python3-cffi-backend` (1.15.1-5+b1) are **already installed** |
| `python3-rpi-lgpio` / `python3-lgpio` / `python3-spidev` | Pi-only | yes | Pi flat repo | WhisPlay driver GPIO/SPI |

### Dashboard

| Library | Version | Purpose | Why |
|---|---|---|---|
| `node:crypto` `argon2()` | Node ≥ 24.7.0 (device: 24.21.0) | Argon2id verify | Built in, no stability marker in `doc/api/crypto.md` at v24.x (`added: v24.7.0`). No native addon to survive pnpm 10's build-script blocking or Next's standalone tracing |
| `node:crypto` `createHmac`/`timingSafeEqual` | built-in | Session cookie signature | Replaces the char-code compare in `app/api/middleware/auth.ts:68-83` |
| `next` | 16.1.6 (pinned) | `proxy.ts` (renamed from middleware in v16.0.0; Node.js runtime by default) | nextjs.org/docs/app/api-reference/file-conventions/proxy |

### Broker (dev host only; nothing under `scripts/pki/` ships)

Stdlib (`json`, `hashlib`, `threading`, `os.replace`) for the claim-code list. `cryptography>=38.0.4,<46` (already pinned, `scripts/pki/requirements.txt`) for the stub IoT's test CA and for revoke signature checks.

### Wake-word training (off-device, Linux + NVIDIA GPU)

| Component | Pin | Notes |
|---|---|---|
| openWakeWord | commit `368c037` (2025-12-30, HEAD; `setup.py` version 0.6.0, `python_requires>=3.10`) | That commit puts ONNX→TFLite behind `--convert_to_tflite`, so the TensorFlow 2.8 stack is not needed at all |
| Feature models | release `v0.5.1` `melspectrogram.onnx` (`ba2b0e0f…`), `embedding_model.onnx` (`70d16429…`) | Same files the device must ship (N4) |
| piper-sample-generator | `rhasspy/piper-sample-generator`, model `v2.0.0/en_US-libritts_r-medium.pt` | Synthetic positives, 904 LibriTTS-R speakers |
| Negatives | HF `davidscripka/openwakeword_features`: `openwakeword_features_ACAV100M_2000_hrs_16bit.npy` (17.28 GB, LFS sha256 `721a66d0…`), `validation_set_features.npy` (0.18 GB, `a56a8a0f…`). **Dataset card license: `cc-by-nc-sa-4.0`** | Plus an AudioSet shard, FMA and MIT RIRs, per the notebook |

### Device openWakeWord

**Upgrade to `openwakeword==0.6.0`, in `voice-nodeps.txt`, installed `--no-deps`.** Its `setup.py` declares `tflite-runtime` on Linux, which we don't want. Its real import-time needs are `numpy`, `onnxruntime`, `scipy`, `sklearn` (via `custom_verifier_model`), `tqdm` and `requests`. All are present: apt layer or `voice.txt`, with `requests` from apt `python3-requests`. Construct it as:

`Model(wakeword_models=[…], inference_framework="onnx", melspec_model_path=…, embedding_model_path=…)`

The alternative is keeping 0.4.0: `Model(wakeword_model_paths=[…], melspec_onnx_model_path=…, embedding_onnx_model_path=…)` plus a post-install prune of the six bundled NC models. That is defensible but inferior, because the prune is a silent-no-op-shaped step that a later venv rebuild undoes. The locked context leaves this choice to a plan; this research recommends 0.6.0.

### Alternatives Considered

| Instead of | Could use | Tradeoff |
|---|---|---|
| Node built-in `crypto.argon2` | `argon2` (node-argon2) / `@node-rs/argon2` | Both parse PHC strings natively, but add a native addon to a pnpm 10 build that blocks install scripts, and to Next standalone tracing |
| `python3-argon2` in the pairing daemon | Shelling out to `/opt/arlowe/node/bin/node` to hash | Avoids one apt package, costs a subprocess and a JS file in the Python path. Not worth it: `python3-argon2` adds 130 KB and its deps are already installed |
| Root oneshot helpers for hostname/reset | More polkit rules (`hostname1`, `manage-unit-files`) | `/etc/hosts` needs root regardless. systemd's `manage-unit-files` check carries no unit details, so a rule cannot be scoped to our units (MEDIUM, from systemd's `bus_verify_manage_unit_files_async`) |
| `ConditionPathExists` on six units | Literal `systemctl enable --now` at pairing | Units are already enabled (N1). Enable/disable at runtime adds a crash window and needs an unscopable polkit action |

**Installation (image):** add to `pi-gen/stage-arlowe/00-packages/00-packages-nr`:
```
# Pairing daemon (Phase 8): Whisplay setup QR; Argon2id for the dashboard password.
python3-qrcode
python3-argon2
# Already installed via stage2; declared because the pairing renderer references DejaVuSans.ttf.
fonts-dejavu-core
```

**What adding them costs** (`docs/operations/phase-07.3-pi-archive-pinning.md` §1, §4):
- All three are Debian-only, so there is **no Pi-archive record-mode bump and no manifest change**. The completeness check attributes them to the Debian snapshot lists.
- The cost is new `pkg` rows (`python3-qrcode`, `python3-png`, `python3-typing-extensions`, `python3-argon2`), so the next build stops at the inputs diff gate. Re-record `docs/operations/phase-07.2-inputs.reference` with `ARLOWE_INPUTS_ACCEPT=1`, either on the checkpoint build itself (runbook §4 step 5 "alternative") or in a separate build. One build can carry every Phase 8 package and model change: batch them.
- CI `build-inputs-resolve` (`.github/workflows/ci.yml:153-193`) resolves `00-packages-nr` through snapshot + flat repo and passes without any reference change.
- `unit-import-bookworm` will fail any unit entry point that imports a module not in `00-packages-nr`. That is the guard; add the packages in the same PR as the import.

---

## Architecture Patterns

### Recommended layout

```
runtime/pair/                     # new Python package, system python3 (all deps apt)
  __main__.py                     # entry: python3 -m pair
  netman.py                       # nmcli argv wrapper: radio, scan cache, AP up/down, join, classify, restore
  portal.py                       # ThreadingHTTPServer on :80, probe redirects, form, status page
  display.py                      # Whisplay screens (text + QR) via shared renderer
  flow.py                         # state machine: WAITING -> CONNECTING -> PROVISIONING -> PAIRED | ERROR(kind)
  validate.py                     # display name -> hostname slug + hashed-banlist check
runtime/lib/arlowe_display.py     # PIL image -> rotated RGB565 list (extracted from face.py so both share it)
runtime/cli/pair-commit           # root oneshot: hostname, /etc/hosts, avahi restart
runtime/cli/factory-reset         # root oneshot: revoke-then-wipe (below)
units/arlowe-pair.service         # User=arlowe, Condition !config.yml, Conflicts=arlowe-face
units/arlowe-pair-commit.service  # root, Type=oneshot, no [Install]
units/arlowe-factory-reset.service# root, Type=oneshot; WantedBy=multi-user.target for resume (see reset)
provision/polkit/51-arlowe-networkmanager.rules
pi-gen/stage-arlowe/.../NetworkManager/dnsmasq-shared.d/arlowe-captive.conf
runtime/dashboard/proxy.ts        # Next 16 proxy (root of the app, beside app/)
runtime/dashboard/lib/auth/       # session.ts, argon2.ts (PHC verify), require-session.ts
tools/wake-training/              # off-image: pinned container, config yaml, eval script
```

### Pattern 1: Unit graph and privilege split

- **`arlowe-pair.service`:**
  - Ordering: `After=arlowe-identity-init.service arlowe-firstboot.service NetworkManager.service`, `Wants=NetworkManager.service`, `ConditionPathExists=!/etc/arlowe/config.yml` (PAIR-01; gated on config, not on the firstboot sentinel, so a reset returns to pairing).
  - `Conflicts=arlowe-face.service`: both drive the same GPIO lines, and starting face after pairing then stops pair automatically.
  - No `Requires=` on identity-init. A failed identity must show on the Whisplay, not silently prevent pairing from starting.
  - Credentials: `User=arlowe`, `SupplementaryGroups=gpio spi video`, `AmbientCapabilities=CAP_NET_BIND_SERVICE` and `CapabilityBoundingSet=CAP_NET_BIND_SERVICE` (port 80 for captive probes), `NoNewPrivileges=yes`, `RuntimeDirectory=arlowe-pair` and `WorkingDirectory=/run/arlowe-pair` (lgpio writes `.lgd-nfy*` relative to CWD, `units/arlowe-face.service:12-22`).
  - Devices: copy face's `DeviceAllow` block verbatim (`units/arlowe-face.service:59-71`; `char-gpiochip`, not node names).
  - Sandbox: `SystemCallFilter=@system-service`, `~@privileged @resources`, `mbind` (Pi 5 fake NUMA), `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`.
  - `ReadWritePaths=/etc/arlowe /var/lib/arlowe/identity /var/lib/arlowe/dashboard /var/lib/arlowe/state /var/lib/arlowe/logs`. It runs `arlowe-identity provision` as a child, which writes the identity store.
  - `WantedBy=multi-user.target`: `install-units.sh` links it automatically.
- **`arlowe-pair-commit.service`** (root, `Type=oneshot`, no `[Install]`): the daemon runs `systemctl start arlowe-pair-commit.service`, which is synchronous for a oneshot and allowed by the existing `arlowe-` prefix rule. It reads a request file the daemon wrote under `/run/arlowe-pair/` and **re-validates the hostname**, because this is a privilege boundary. It then runs `hostnamectl set-hostname`, rewrites the `127.0.1.1` line in `/etc/hosts`, and runs `systemctl restart avahi-daemon`. avahi 0.8 does not follow hostname changes by itself (MEDIUM).
- **Commit order in the daemon:**
  1. Request file.
  2. `start arlowe-pair-commit`.
  3. Write `/etc/arlowe/config.yml` atomically: tmp in `/etc/arlowe`, validate with `arlowe_config.load()` using `ARLOWE_CONFIG_PATH=<tmp>`, `fsync`, `os.replace`. **This is the commit point.**
  4. Draw the final "paired" screen and `board.cleanup()`.
  5. `systemctl start` the six. Starting face stops pair via `Conflicts`.
- **Gate bookkeeping.** New `Exec*` tokens must appear in `ARLOWE_EXPECTED_UNDECLARED` (`scripts/lib/verify-unit-execstart.sh:146-154`) if they are first-party scripts, or use `/usr/bin/python3` (floor declared at `:108-112`). New `DeviceAllow` lines are checked by `verify_unit_device_allow`.

### Pattern 2: AP bring-up and captive portal

- Radio: root helper or polkit (N2/N3): `rfkill unblock wlan`, `nmcli radio wifi on`, set regdomain.
- **Scan before the AP comes up** and cache the result. A single-radio brcmfmac in AP mode cannot usefully rescan. Offer manual SSID entry as well.
- Create the AP profile **in memory**: `nmcli connection add save no …` (documented in `man/nmcli.xml` at 1.42.4: "save … whether the connection should be persistent (default: yes)"). The setup profile then never lands in `/etc/NetworkManager/system-connections`.
- Pin `ipv4.addresses 10.42.0.1/24` so the DNS wildcard below matches.
- NM passes `--conf-dir=/etc/NetworkManager/dnsmasq-shared.d` to the shared dnsmasq **only if that directory exists** (`src/core/dnsmasq/nm-dnsmasq-manager.c:205-207` at 1.42.4). Ship the directory and one file: `address=/#/10.42.0.1`.
- dnsmasq advertises itself as router and DNS by default. NM adds `option:router` only when it has a default route, which is fine.
- Captive probes: answer any request whose `Host` is not the portal with **`302 Location: http://10.42.0.1/`**. That covers iOS `captive.apple.com/hotspot-detect.html`, Android `connectivitycheck.gstatic.com/generate_204` / `clients3.google.com/generate_204`, Windows `www.msftconnecttest.com/connecttest.txt`, and Firefox `detectportal.firefox.com`. Refused `:443` connections are fine: Android treats a failed HTTPS probe plus a redirected HTTP probe as a portal (MEDIUM, community-verified; see Sources).
- Do **not** use DHCP option 114 (N8).
- Portal responses: `Connection: close`, `Cache-Control: no-store`. Use an IP-literal portal URL.
- SSID `Arlowe-Setup-` + `device_id[:4]`. Checked against `scripts/sanitize/banlist.txt`: no 4-hex suffix can produce a banned substring (exhaustive over 65,536 suffixes).

### Pattern 3: Optimistic handoff state machine (locked; mechanics)

1. The form shows the "find me at `http://<name>.local:3000`" instruction **before** submit. The iOS captive sheet closes the moment the AP disappears, so the post-submit page may never be read.
2. POST → validate every field locally (SSID ≤ 32 bytes, PSK 8-63 printable or 64 hex, display name → slug, password ≥ 8, claim code format). Respond `200`, flush, wait about 2 s.
3. AP down → `nmcli --wait 45 device wifi connect <ssid> password <psk> ifname wlan0`, as argv, never through a shell. Classify failures by NM's state reason, not only stderr: `NO_SECRETS` (7), `SUPPLICANT_DISCONNECT` (8), `SUPPLICANT_TIMEOUT` (11) mean "Wi-Fi password rejected"; `SSID_NOT_FOUND` (53) means "network not found" (MEDIUM; brcmfmac typically surfaces a bad PSK as 7).
4. On join failure: `nmcli connection delete` the half-made profile, or it autoconnect-loops with the bad PSK. Bring the AP back up. Record the error in `/run/arlowe-pair/status.json`. Keep the submitted fields **in memory only**, so the owner corrects just the failing one.
5. After join: wait up to about 30 s for `timedatectl show -p NTPSynchronized --value` = `yes` before any TLS call. A factory clock can predate a certificate's notBefore.
6. `arlowe-identity provision --json` with the claim code in the environment (`ARLOWE_OWNER_TOKEN`), never argv (`runtime/cli/identity:192-209`). Map failures per N6.
7. On provisioning failure: delete the saved NM profile, restore the AP, show the error. Invariant: an unpaired device has no saved networks.
8. On success: the commit sequence (Pattern 1).

### Pattern 4: Claim codes (broker change)

Replace the single `ARLOWE_BROKER_TOKEN` compare (`scripts/pki/broker.py:38-43,62-67,81-83`) with `ARLOWE_BROKER_CLAIM_CODES=<path>`, a JSON map `sha256(normalized_code) -> {state: unused|bound|revoked, device_id, minted_at, bound_at, note}`. Details:
- `load_config` refuses to start if the file is missing, the same posture as `:46-59`.
- Normalize codes: uppercase, strip `-` and spaces. Use Crockford base32 with 20 characters (100 bits), printed in groups of five.
- Look up by hash. With a high-entropy secret, hash-keyed lookup leaks nothing useful.
- Mark `bound` **after** IoT succeeds (`:110-130`), under one `threading.Lock`, with an atomic `os.replace` write. `ThreadingHTTPServer` is concurrent (`:209`).
- A second redemption by the same `device_id` is idempotent (N7). Any other `device_id` gets `401 {"error":"unauthorized"}`. Do not distinguish unknown, used and revoked codes to the caller.
- Update the module docstring (`:8-13`): its "do not add a lookup" line is Phase 7's constraint, and Phase 8 is where it lifts.
- Tools: `scripts/pki/claim-codes.py mint [--note]` appends and prints the code; `revoke <code>` and `release <code>` complete the set.
- The device side does not change.

### Pattern 5: Device-initiated revoke (reset step 1)

There is no device revoke today. `scripts/pki/revoke.sh` is an operator AWS CLI call (`:54`), and `cmd_reset` is offline (`runtime/cli/identity:262-277`). Add:
- `arlowe-identity revoke --json`, which POSTs `{device_id, certificate_id, issued_at, signature}` to `/v1/certificates/revoke`. The signature is ECDSA-SHA256 by `device.key` over the canonical JSON of the other fields.
- The broker verifies the signature against `iot.describe_certificate(certificateId)`'s PEM, checks that the certificate's Thing is `device_id`, rejects `issued_at` more than 5 minutes stale, calls `update_certificate(newStatus="REVOKED")`, and releases the claim-code binding (N7).
- Everything is testable through the stub IoT client, which `handle_certificate_request` already takes by injection (`broker.py:75-80`).
- Confidence MEDIUM: no AWS call in `scripts/pki/` has ever executed (07-09 parked).

### Pattern 6: Dashboard auth (DASH-02)

- **Hash at pairing (Python):** `argon2.PasswordHasher(time_cost=3, memory_cost=65536, parallelism=4, hash_len=32, salt_len=16).hash(pw)` gives a PHC `$argon2id$v=19$m=65536,t=3,p=4$<salt>$<hash>`. Set the parameters explicitly; don't inherit 21.1.0's defaults. Write `{hash, created_at}` to `/var/lib/arlowe/dashboard/owner-credential.json` at 0600 `arlowe`. **Not in `config.yml`**: `POST /api/config` rewrites the overlay (`config/route.ts:54-100`) and every service reads it.
- **Verify (Node):** parse the PHC string, accept only `argon2id` with `v=19`, call `crypto.argon2('argon2id', {message, nonce: salt, parallelism: p, tagLength: hash.length, memory: m, passes: t})`, then `timingSafeEqual`. CI needs a cross-implementation vector: a PHC string produced by `python3-argon2` verified by the Node code.
- **Session:** a stateless cookie `arlowe_session = base64url(payload).base64url(HMAC-SHA256(key, payload))`, payload `{iat, exp}`, 30-day absolute expiry.
  - Key: 32 random bytes at `/var/lib/arlowe/dashboard/session.key`, created at pairing. Rotating it logs out every session; reset wipes it.
  - Cookie attributes: `HttpOnly; SameSite=Strict; Path=/`. **No `Secure` attribute**: the dashboard is plain HTTP on the LAN, and browsers drop Secure cookies on http origins.
- **`proxy.ts`** matcher covers everything except `/_next/static`, `/_next/image`, `/favicon.ico`, `/login` and `/api/auth/login`. It redirects pages to `/login` and returns 401 JSON for `/api/*`.
- **Plus** a `requireSession()` call inside every mutating handler. Next's own docs say not to rely on Proxy alone (proxy.js reference, "Execution order" note).
- On mutating requests, also check that `Origin` matches `Host`.
- Delete `verifyAuth`/`DASHBOARD_API_SECRET` (`app/api/middleware/auth.ts`).
- Login throttle: in-memory, 5 failures, then 30 s.

### Pattern 7: Schema extensions (prerequisite, `config/schema.yml`)

Top-level `additionalProperties: false` (`:23`). `device` allows only `hostname` (`:37-51`). Add these, **none of them to the top-level `required` list**; keep the pattern `identity` uses (`:213-222`) so the dashboard's raw-body validation stays valid:
```yaml
device.display_name:  {type: string, minLength: 1, maxLength: 32, default: "Arlowe"}
owner:                {type: object, additionalProperties: false, properties: {paired_at: {type: string}}}
network:              {type: object, additionalProperties: false, properties: {wifi_label: {type: string, maxLength: 32}}}
wake:                 {type: object, additionalProperties: false, properties: {personalization_enabled: {type: boolean, default: false}}}
```
Update `config/defaults.yml` and `runtime/dashboard/app/audio/save-body.ts:4-22` (`CONFIG_DEFAULTS`/`REQUIRED_KEYS`, synced by hand) in the same PR. The overlay is shallow-merged at top level (`schema.yml:3-7`), so the pairing overlay must write `device` with **both** `hostname` (concrete, no placeholder) and `display_name`.

### Pattern 8: Display name → hostname

- Slug: lowercase NFKD → `[a-z0-9-]` → collapse hyphens → trim to 63 → no leading or trailing `-` → non-empty (RFC 1123 label).
- Check against a **hashed** banlist. `banlist.txt` has 6 entries; 3 are pure `[a-z0-9-]` (lengths from the file; the entries were not printed here). Ship only `(length, sha256)` of those 3. For each, hash every slug substring of that length and compare.
- The literal banlist must not ship. `--scan-dir` over the rootfs would flag it (`scripts/sanitize/check.sh:8-13`).
- Tests must derive banned strings by reading `banlist.txt` at test time, never from a literal in a tracked file.
- Residual to record: sha256 of a short literal lets someone *confirm* a guess. Acceptable, but say so.
- Collisions: avahi renames a conflicting host to `name-2.local`. Show the device IP on the Whisplay "paired" screen as the fallback; DASH-01 allows it. Android resolves `.local` only on 12+ and inconsistently in Chrome (MEDIUM).

### Pattern 9: Whisplay ownership and the button

Driver API from the 344-line upstream `Driver/WhisPlay.py` at `bde2b83`. That is the probable staged copy, not confirmed (open question 5):
- `WhisPlayBoard()` claims **all** pins at construction: LCD DC/RST/LED, RGB PWM, and the button on BOARD pin 11 with `add_event_detect(BOTH, bouncetime=50)` (lines 23-66).
- `draw_image(x, y, w, h, pixel_data)` (275-279).
- `set_rgb(r,g,b)`, `set_rgb_fade(...)` (282-307).
- `button_pressed()`, which is **HIGH when pressed** (309-310, comment line 327).
- `on_button_press(cb)`, `on_button_release(cb)` (312-316).
- `cleanup()` calls `GPIO.cleanup()` (336-344).

There is **no `ShowImage`**; `arlowe-recovery.sh:105` is still broken.

Only one process can own the board, so:
- **Pre-pairing:** `arlowe-pair` owns it. It renders the status screens and QR. A short press re-raises the AP after the idle timeout.
- **Paired:** `arlowe-face` owns it. The long-press reset lives in face: hold ≥ 10 s with a countdown drawn from 3 s onward and the LED red, release, then a confirming press within 5 s, then `systemctl start --no-block arlowe-factory-reset.service` (allowed by the existing polkit rule).
- Both render text through `runtime/lib/arlowe_display.py` (PIL → rotate CCW → RGB565), extracted from `face.py:26-31,590-607`. DejaVuSans 18-20 px fits about 16-20 characters by 5 lines on 240 px.
- A version-3 QR of `WIFI:S:Arlowe-Setup-xxxx;T:nopass;;` is 29 modules plus the border, about 222 px at 6 px per module. It fits.

### Pattern 10: Factory reset (root oneshot `arlowe-factory-reset.service`)

1. Write `/var/lib/arlowe/reset-ledger/in-progress` (fsync). If a boot finds this marker, it resumes the reset, so a power cut mid-reset cannot leave a half-wiped unit. `ConditionPathExists=` on the marker together with `WantedBy=multi-user.target`.
2. Stop the six units and pair.
3. **Best effort:** `arlowe-identity revoke --json` with about 20 s timeout. On failure, append `{certificate_id, thing_name, device_id, at, reason}` to `/var/lib/arlowe/reset-ledger/orphaned-certs.jsonl` and fsync. That directory is on owner_state (p4), outside every wipe path, root 0700.
4. `rm /etc/arlowe/config.yml`. **Commit point: the device is now unpaired.**
5. Delete every `802-11-wireless` NM profile (`nmcli -t -f UUID,TYPE connection show`, then `delete`). Remove `/var/lib/NetworkManager/{seen-bssids,timestamps,*.lease}`. Keyfiles hold the PSK in plaintext.
6. `arlowe-identity reset --force` (identity store).
7. Empty the contents (not the directories) of `conversations/`, `wake-word/`, `state/`, `dashboard/` (credential, session key, cache), `logs/*`, `cache/`. Recreate the skeleton owners and modes exactly as `scripts/provision/install-arlowe-fs.sh:66-86` does.
8. Journal: `journalctl --rotate` then `journalctl --vacuum-time=1s`. The journal lives in `/var/lib/arlowe/journal` (`01-runtime/00-run-chroot.sh:369-373`) and holds transcripts.
9. `hostnamectl set-hostname arlowe`, fix `/etc/hosts`.
10. Append the audit line to `reset-ledger/resets.log` (`{at, trigger: dashboard|button, revoke: ok|failed|skipped}`), remove the marker, sync, reboot.

Never touched: `/opt/arlowe/models` (ro p5), `.firstboot-done`, `.models-grow-done`, the reset ledger. The next boot runs `identity init` (new entropy, so a new `device_id`), then pairing.

Triggers:
- **Dashboard:** `POST /api/device/reset`, authenticated plus password re-entry, returns 202.
- **Button:** Pattern 9.
- **Recovery SD:** documentation only.
- **Slot B:** not a trigger (B7).

### Pattern 11: Wake model

- **Train:** `tools/wake-training/` with a pinned Linux container (Python 3.10, torch/CUDA per the notebook's pinned deps, minus TensorFlow) and openWakeWord at `368c037`. `train.py --generate_clips`, then `--augment_clips`, then `--train_model`; no `--convert_to_tflite`.
  - Config from `examples/custom_model.yml`: `target_phrase: ["hey arlowe"]`, `n_samples` 20000-50000, `steps` 50000, `layer_size` 32 (the defaults), `target_false_positives_per_hour: 0.2`.
  - `custom_negative_phrases`: phonetic neighbors ("hey arlo", "harlow", "hey carlos", "marlowe", "hello", "hey all", "barlow", …).
  - Compute: one NVIDIA GPU. Disk ≥ 40 GB (17.3 GB features plus clips). Wall clock per cycle is a few hours (MEDIUM, from the notebook's "~10 min per 1,000 clips on a T4" scaling).
- **Offline gate before hardware:** recall on held-out synthetic, plus FP/hour on `validation_set_features.npy`.
- **Ship:** a new `wake_word` entry in `third_party/models/manifest.yml`:
  - Files `wake-word/hey_arlowe.onnx` (url null, Strategy C), `wake-word/melspectrogram.onnx`, `wake-word/embedding_model.onnx` (v0.5.1 release URLs, sha256 above).
  - `install_to: /opt/arlowe/models/wake-word`: the read-only models partition, untouched by reset, shared by both slots.
  - Re-record the `pin` rows in the inputs reference in the same change (manifest header lines 22-23).
  - Keep a durable copy of the trained ONNX, the config and the seeds outside the build host.
- **Every path that must change** (`hey_jarvis`/`'jarvis'`):

  | File | Line(s) |
  |---|---|
  | `runtime/voice/voice_client.py` | `:33-34,348-350` (loader) |
  | `runtime/voice/wake_test.py` | `:8-14` |
  | `runtime/wake-word/quick_test.py` | `:25-26,43-44` |
  | `runtime/wake-word/test_verifier.py` | `:21-27,46-47` |
  | `runtime/wake-word/train_verifier.py` | `:6,22-32` |
  | `runtime/wake-word/README.md` | `:7` |
  | `runtime/voice/requirements.txt` | `:19` (version pin) |
  | `runtime/wake-word/requirements.txt` | `:19` (version pin) |
  | `pi-gen/stage-arlowe/01-runtime/files/venv-requirements/voice.txt` | `:25-28` (pin moves to `voice-nodeps.txt`) |
  | `docs/operations/phase-7.1-substrate.md` | `:256-276` (the "bundles its models" section becomes false) |
  | shipped bytes | the six bundled `.onnx` in the 0.4.0 wheel (N5) |

  `runtime/wake-word/` and `runtime/cli/wake-train` ship in the image, because `01-runtime/00-run-chroot.sh:114` rsyncs all of `runtime/`.
- **Threshold:** `GENERIC_BASE_THRESHOLD = 0.7` (`wake_gate.py:36`) was tuned for `hey_jarvis`. Re-tune it during SC5 and record the value next to the model.
- **WAKE-03:** `voice_client` constructs `WakeGate(VERIFIER_MODEL, verifier=None)` when `wake.personalization_enabled` is false. The dashboard switch writes that key through the existing `POST /api/config`.
- **WAKE-02:** detection and consumption are in-process in `voice_client`, with no separate wake service. Record that this satisfies "emits an event consumed by the orchestrator"; don't build a service.

### Anti-Patterns to Avoid

- **Running the network-facing pairing server as root.** It parses input from anyone in radio range. Keep root in oneshots that read a validated request file and re-validate it.
- **Persisting the setup AP profile.** Use `save no`. A persisted `mode ap` profile with autoconnect resurrects the open AP after pairing.
- **Leaving the join profile on failure.** NM retries a wrong PSK forever and never falls back to AP.
- **Putting the password hash in `config.yml`.** Dashboard config writes and every service can read it.
- **`Secure` cookies on the http LAN dashboard.** Browsers silently drop them, and login appears to "not stick".
- **Copying `arlowe-recovery.sh:96-105`'s `ShowImage`.** No such method exists.

---

## Don't Hand-Roll

| Problem | Don't build | Use instead | Why |
|---|---|---|---|
| Password hashing | Any KDF, salt handling or custom compare | `python3-argon2` to hash, `node:crypto.argon2` plus `timingSafeEqual` to verify | Parameter and encoding mistakes are silent |
| DHCP/DNS on the AP | A Python DNS server | NM shared mode's dnsmasq plus `dnsmasq-shared.d/` `address=/#/` | Already in the image and started by NM |
| NAT/firewall for shared mode | nft rules | NM (auto-selects nftables, N/A iptables) | `nm-firewall-utils.c` handles setup and teardown |
| QR encoding | Reed-Solomon / QR matrix | `python3-qrcode` | One Debian package |
| Session tokens | JWT library, custom crypto | HMAC-SHA256 over a small JSON payload with a random key | Minimal, auditable, revocable by key rotation |
| Wake-word training | A custom classifier pipeline | `openwakeword/train.py` at `368c037` | The feature extractor must match the device (N4) |
| Personalization verifier (deferred) | The sklearn pickle | openWakeWord `custom_verifier_models` (0.6.0 `model.py:44-45`) | Deferred per context; noted so nobody extends the pickle path |
| Hostname conflict resolution | Custom mDNS probing | avahi's built-in `-2` renaming, plus the IP on the Whisplay | — |

**Key insight:** every "small" piece of this phase that looks custom (DNS, NAT, hashing, QR) already has a component on the image or in Debian, and the pins make each addition cheap: one Debian package, one reference re-record. The real custom work is the state machine, the privilege boundary and the reset ordering, and that is where the tests belong.

---

## Common Pitfalls

### P1: Reading the stale "units ship disabled" comments as truth
**What goes wrong:** a plan adds `systemctl enable` machinery for units that are already enabled, and misses that they run unpaired. **How to avoid:** N1. Correct `03-firstboot/00-run-chroot.sh:151-156`, `phase-7.1-substrate.md:480-482` and `50-arlowe-systemctl.rules:6` in the gating PR. **Warning sign:** `systemctl is-enabled arlowe-face` on an image says `enabled`.

### P2: AP never comes up because the radio is off
**What goes wrong:** `nmcli con up` fails with the device unavailable. **Why:** `WirelessEnabled=false`, and `rfkill default_state=0` (N2). **How to avoid:** unblock rfkill, enable the radio and set the regdomain first. Assert the device state is `disconnected`, not `unavailable`.

### P3: Every nmcli call "works" as root in the dev loop and fails under the unit
**Why:** polkit's `allow_any` (N3). **How to avoid:** test as the service user: `sudo -u arlowe nmcli …` is **not** equivalent (sudo creates no session either, but it inherits the terminal), so use `systemd-run --uid=arlowe --pipe nmcli general permissions`. On hardware, that command prints every action's `yes/no/auth`.

### P4: Secrets in logs or argv
The journal is persistent and holds transcripts. The PSK passed to `nmcli ... password <psk>` is in argv for the call's duration. That is visible only to local processes on a single-tenant appliance, so it is acceptable, but **never log argv, the form body, the claim code or the password**. The claim code goes in the environment. Tests assert that the journal capture contains none of the fixture secrets (the same pattern as `scripts/pki/tests/test_broker.py` `test_token_never_reaches_the_log`).

### P5: Package added in one PR, reference re-recorded in none
**Why:** CI doesn't compare `00-packages-nr` to the inputs reference. Only a real build does. **How to avoid:** batch all Phase 8 package and model changes, and re-record once on the checkpoint build (`ARLOWE_INPUTS_ACCEPT=1`, read the diff). Mind N10.

### P6: New unit fails the unit-substrate gate on the build host only
A new first-party `Exec*` token not in `ARLOWE_EXPECTED_UNDECLARED` fails the interpreter-floor gate (`verify-unit-execstart.sh:146-154,857-864`). A `DeviceAllow` with a glob or a node name grants nothing. Copy face's `char-gpiochip` block. Each such miss costs a roughly 45-minute build plus a 26-minute flash, so run the fixture self-tests (`tests/phase-07.1/test-verify-unit-execstart.sh`) locally first.

### P7: Classifier trained on one embedding, run on another
N4. **Warning sign:** great offline recall, poor on-device recall. **Prevention:** ship and pass the v0.5.1 feature-model paths explicitly, and assert their sha256 at `voice_client` start.

### P8: Silent substitution of wake threshold semantics
`0.7` was for `hey_jarvis`. A new model with a different score distribution either never wakes or wakes constantly. SC5 includes a threshold sweep over the recorded trials, and the chosen value is committed with the model.

### P9: Interrupted reset
A power pull between "config removed" and "identity wiped" leaves an unpaired device with the old cert. Resume from the ledger marker (Pattern 10 step 1). Test it by killing the helper at each step in a fixture root.

### P10: Dashboard auth tested on Node 20
N9. `crypto.argon2` is undefined on Node 20, so tests either crash or get skipped by a feature check. Bump CI to 24.

### P11: Captive sheet closes before the owner reads the handoff instructions
Show the `.local` URL, and the "reconnect to Arlowe-Setup if something goes wrong" instruction, **before** submit and on the Whisplay.

### P12: Treating avahi/mDNS as the only path to the dashboard
Pre-12 Android can't resolve `.local`, and Chrome on Android is inconsistent. Show the IP too.

---

## Code Examples

### polkit: NetworkManager for the service user (new `provision/polkit/51-arlowe-networkmanager.rules`)
```javascript
// Source: action IDs and defaults read from the Pi-archive network-manager
// 1.42.4-1+rpt1+deb12u1 deb (org.freedesktop.NetworkManager.policy). A systemd
// service has no session, so allow_any applies and every action below defaults
// to deny or auth_admin with no agent present.
polkit.addRule(function(action, subject) {
    if (subject.user !== "arlowe") return;
    var allowed = [
        "org.freedesktop.NetworkManager.network-control",
        "org.freedesktop.NetworkManager.settings.modify.system",
        "org.freedesktop.NetworkManager.wifi.share.open",
        "org.freedesktop.NetworkManager.wifi.scan",
        "org.freedesktop.NetworkManager.enable-disable-wifi"
    ];
    if (allowed.indexOf(action.id) >= 0) return polkit.Result.YES;
});
```

### Setup AP profile (in-memory) and captive DNS
```bash
# Source: nmcli(1) 1.42.4 "connection add [save {yes|no}]"; NM dnsmasq CONFDIR
# (nm-dnsmasq-manager.c:23,205-207 at 1.42.4)
nmcli connection add save no type wifi ifname wlan0 con-name arlowe-setup \
    autoconnect no ssid "Arlowe-Setup-${SUFFIX}" \
    802-11-wireless.mode ap 802-11-wireless.band bg 802-11-wireless.channel 6 \
    ipv4.method shared ipv4.addresses 10.42.0.1/24 ipv6.method disabled
nmcli connection up arlowe-setup
# /etc/NetworkManager/dnsmasq-shared.d/arlowe-captive.conf (ship the directory too):
#   address=/#/10.42.0.1
```

### Unit gating (each of the six units)
```ini
[Unit]
# Unpaired devices skip this unit: pairing (arlowe-pair.service) owns the device
# until /etc/arlowe/config.yml exists, and writing that file is pairing's commit
# point. Enabled at build by install-units.sh; pairing only has to start it.
ConditionPathExists=/etc/arlowe/config.yml
```

### PHC Argon2id verify on Node 24 (dashboard)
```typescript
// Source: node/doc/api/crypto.md (v24.x) crypto.argon2, added v24.7.0
import { argon2, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';
const argon2Async = promisify(argon2);

export async function verifyPassword(phc: string, password: string): Promise<boolean> {
  const m = /^\$argon2id\$v=19\$m=(\d+),t=(\d+),p=(\d+)\$([A-Za-z0-9+/]+)\$([A-Za-z0-9+/]+)$/.exec(phc);
  if (!m) return false;
  const [, mem, passes, par, saltB64, hashB64] = m;
  const expected = Buffer.from(hashB64, 'base64');
  const derived = await argon2Async('argon2id', {
    message: password, nonce: Buffer.from(saltB64, 'base64'),
    parallelism: Number(par), tagLength: expected.length,
    memory: Number(mem), passes: Number(passes),
  });
  return derived.length === expected.length && timingSafeEqual(derived, expected);
}
```

### proxy.ts shape (Next 16)
```typescript
// Source: nextjs.org/docs/app/api-reference/file-conventions/proxy (v16: Node.js runtime by default)
import { NextResponse, type NextRequest } from 'next/server';
import { readSession } from './lib/auth/session';   // HMAC check, key from /var/lib/arlowe/dashboard/session.key

export function proxy(request: NextRequest) {
  if (readSession(request.cookies.get('arlowe_session')?.value)) return NextResponse.next();
  if (request.nextUrl.pathname.startsWith('/api/'))
    return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  return NextResponse.redirect(new URL('/login', request.url));
}
export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico|login|api/auth/login).*)'],
};
```

### openWakeWord on device (0.6.0)
```python
# Source: openwakeword v0.6.0 model.py:38-47,213; utils.py AudioFeatures(melspec_model_path, embedding_model_path)
from openwakeword.model import Model
WAKE_DIR = "/opt/arlowe/models/wake-word"
oww_model = Model(
    wakeword_models=[f"{WAKE_DIR}/hey_arlowe.onnx"],
    inference_framework="onnx",                       # 0.6.0 defaults to tflite
    melspec_model_path=f"{WAKE_DIR}/melspectrogram.onnx",
    embedding_model_path=f"{WAKE_DIR}/embedding_model.onnx",
)
```

### Concrete ADR wording for the wake-model licensing risk (owner decision, recorded as a known liability)
> **Decision.** The first shipping "Hey Arlowe" model is a custom openWakeWord classifier trained with the stock openWakeWord recipe: synthetic positives from piper-sample-generator (`en_US-libritts_r-medium`), negatives from the precomputed ACAV100M feature set, an AudioSet shard and FMA, and MIT room impulse responses.
>
> **Known liability, accepted by the owner on 2026-09-28.** The precomputed negative-feature set this model is trained on is published under **CC BY-NC-SA 4.0** (Hugging Face `davidscripka/openwakeword_features`, dataset card). AudioSet and ACAV100M are the "datasets with unknown or restrictive licensing" that the openWakeWord README gives as the reason its own pre-trained models are CC BY-NC-SA 4.0. It is unresolved whether a model trained on that data inherits the NonCommercial or ShareAlike terms. This decision assumes the risk rather than resolving it. **Every unit sold with this model carries that risk.** The model sits on the read-only models partition. Phase 9 OTA updates the app only, so **there is no field remedy for sold units until a model-OTA path exists (v1.1 or later)**. Replacing the model needs either that path or a reflash.
>
> **Mitigation plan (deferred, not a gate).** Retrain on audited, commercially licensable data only, and ship it through model OTA once that exists.
>
> **Scope note.** The shared feature models (`melspectrogram.onnx`, `embedding_model.onnx`, openWakeWord release v0.5.1) are required at inference. The README describes the embedding backbone as Google's `speech_embedding`, Apache-2.0, re-implemented by openWakeWord. Its blanket clause ("All of the included pre-trained models are licensed under CC BY-NC-SA 4.0") arguably covers them too. This ADR records that ambiguity as part of the same accepted risk.
>
> **Removed.** The openWakeWord 0.4.0 wheel's six bundled CC BY-NC-SA models (including `hey_jarvis_v0.1`) no longer ship. The device runs openWakeWord 0.6.0, whose wheel contains no models.

---

## Test Strategy per Success Criterion

| SC | Container / fixture-testable | Needs the hardware checkpoint |
|---|---|---|
| SC1 | Unit ordering and conditions (`systemd-analyze verify` in the Phase 3 docker testbed); portal answers 302 for each probe host and 200 for the portal; Whisplay screens rendered to a PIL image and asserted against expected text and QR decode (decode needs an extra test-only dep or a golden image); `boot-check` skip output unpaired | iOS and Android show the captive sheet; QR camera-join; AP visible; Whisplay shows "waiting for pairing" |
| SC2 | The orchestrator against a **fake `nmcli`** on PATH (scripted exit codes and stdout) plus a **local TLS broker with a stub IoT** that really signs CSRs with a throwaway CA (`pki.store_certificate` rejects a key mismatch, `arlowe_pki.py` IdentityMismatch) plus the **real** `arlowe-identity` CLI (off-device via `ARLOWE_IDENTITY_DIR`, `ARLOWE_SERIAL_ROOT`, `ARLOWE_CONFIG_PATH`, `ARLOWE_BROKER_CA_BUNDLE`, `runtime/cli/identity:29-34`); the written `config.yml` validates; commit helper in a fixture root with `hostnamectl`/`systemctl` shims; dashboard login via the existing Playwright setup | Real join, `.local` resolution from a phone, six units `active`, logged-in dashboard. Cert from the **local** broker on the LAN. The real-cloud run is a separate owner-gated checkpoint (07-09 blocker) |
| SC3 | Four failure modes, each provoked deliberately: **wrong PSK** (fake nmcli: exit with reason 7), **unreachable** (broker URL to a closed port or blackhole with a short timeout), **bad claim code** (broker list without it, giving 401), **issuance or broker rejection** (stub IoT raises `ClientError`, giving 502, or a CSR CN mismatch, giving 400). Assert a distinct Whisplay string and portal string for each | Wrong PSK against a real AP; broker stopped mid-flow; AP restored and the error visible on rejoin |
| SC4 | Reset helper in a fixture root: exact wipe list, ledger survives, orphan recorded when the revoke fails, idempotent resume from every step; broker revoke plus claim-code release through the stub IoT; dashboard reset route needs a session and password | Full reset from the dashboard, then from the button (hold, countdown, confirm); reboot lands in pairing; `nmcli connection show` has no Wi-Fi profiles; new `device_id` |
| SC5 | Offline metrics from training: recall on held-out synthetic, FP/hour on `validation_set_features.npy`; device-side load of the three ONNX with sha256 asserted | **Non-autonomous:** 3 speakers not in training data × 20 utterances = 60 trials at about 1 m and 3 m, varied volume, verifier absent and toggle off. Pass is ≥ 54 wakes. Then a ≥ 1 h ambient session (TV/music/conversation) with ≤ 1 wake. Count journal "Wake word" lines with timestamps. Sweep the threshold over the recorded trials. Note: 54/60 has a 95% Wilson lower bound of about 80%, so 60 trials cannot separate 90% from 85%. The bar is the owner's; record the interval |

---

## Plan Split and Waves (400-net-line cap)

**The phase is too big for one phase.** An honest count is about 24 plans, 22 PRs plus 2 hardware checkpoints. **Recommendation: move WAKE-01..03 into an inserted Phase 8.1.** Its critical path is GPU training cycles, speaker recording and a go/no-go with a phrase fallback. It shares no code with pairing except `config/schema.yml`'s `wake` block, and its checkpoint doesn't need pairing. If the owner keeps one phase, run the wake track as an independent lane and don't gate pairing plans on it.

**Phase 8 (pairing, auth, reset): about 18 plans**

| Wave | Plan | Est. net lines | Depends on |
|---|---|---|---|
| 1 | 08-01 ADRs: setup channel and handoff (incl. N8 exposure), owner credential and claim code (incl. N7), factory reset | ~300 (docs) | — |
| 1 | 08-02 Schema + defaults + `save-body.ts` + hostname slug and hashed-banlist validator + tests | ~350 | — |
| 1 | 08-03 Six-unit `ConditionPathExists` gating + paired-aware `boot-check` (B9; parse `--first-boot`, exit non-zero on real failures) + stale-comment corrections (P1) | ~250 | — |
| 1 | 08-04 B5: `FIRST_USER_PASS` unset, `ENABLE_SSH=0` in `pi-gen/config` and `build-image.yml:120`, rootfs gate (no usable shadow hash, ssh not enabled), dev runbook uses `userconf.txt` + `ssh` file (sshswitch) | ~250 | — |
| 1 | 08-05 Broker claim codes + `claim-codes.py` + tests | ~350 | — |
| 1 | 08-06 Identity CLI structured failure detail (N6) | ~150 | — |
| 2 | 08-07 Stub-IoT local broker harness (TLS, CSR signing) | ~250 | 08-05 |
| 2 | 08-08 Broker revoke endpoint + `arlowe-identity revoke` | ~350 | 08-06, 08-07 |
| 2 | 08-09 `pair/netman.py` + fake-nmcli fixture | ~350 | — |
| 2 | 08-10 `pair/portal.py` + setup/status pages | ~350 | 08-02 |
| 2 | 08-11 `arlowe_display.py` extraction + `pair/display.py` (+ `python3-qrcode`, `fonts-dejavu-core` declared) | ~300 | — |
| 2 | 08-12 Dashboard auth core: PHC verify, session, login/logout, CI Node 24, cross-impl vector | ~350 | 08-02 |
| 3 | 08-13 `pair/flow.py` state machine + `python3-argon2` + credential write | ~350 | 08-06, 08-09, 08-10, 08-11 |
| 3 | 08-14 Units (`arlowe-pair`, `arlowe-pair-commit`), `pair-commit` helper, NM polkit rule, `dnsmasq-shared.d`, gate allowlist | ~300 | 08-03, 08-13 |
| 3 | 08-15 `proxy.ts` + `requireSession` on all mutating routes + remove `verifyAuth` | ~250 | 08-12 |
| 3 | 08-16 Factory reset helper + unit + ledger + resume | ~350 | 08-08 |
| 4 | 08-17 Reset triggers: dashboard route/UI + face long-press | ~300 | 08-15, 08-16 |
| 4 | 08-18 E2E container test: SC2 happy path + four SC3 failures | ~300 | 08-07, 08-13, 08-14 |
| 5 | 08-19 **Checkpoint build** (inputs re-record with accept) + hardware SC1-SC4 (non-autonomous) | ~100 (evidence) | all; after 07.3-09 (N10) |

**Phase 8.1 (wake word): about 5 plans.**
- 8.1-01: ADR (licensing wording above, backup phrase, go/no-go numbers).
- 8.1-02: `tools/wake-training` (~300).
- 8.1-03: training cycles (non-autonomous, owner GPU).
- 8.1-04: device integration: `openwakeword==0.6.0`, models manifest entry, `voice_client` paths, every `hey_jarvis` path, WAKE-03 toggle and schema-read (~350; depends on 08-02 for the `wake` key).
- 8.1-05: SC5 hardware checkpoint plus threshold commit.

Image builds: at most two (the 08-19 checkpoint, and 8.1's checkpoint, or one combined if the model is ready first).

---

## State of the Art

| Old approach | Current approach | When changed | Impact |
|---|---|---|---|
| `middleware.ts` (Edge runtime) | `proxy.ts`, Node.js runtime by default | Next.js v16.0.0 | `node:crypto` is available in the auth gate |
| npm `argon2` native addon | `node:crypto.argon2` | Node v24.7.0 | No native build in the chroot |
| openWakeWord 0.4.0 wheel with bundled models | 0.6.0 wheel without models; explicit model paths | v0.5.0/0.6.0 (2023-2024) | Feature models must be shipped deliberately |
| openWakeWord training needs TensorFlow for TFLite | TFLite conversion behind `--convert_to_tflite` | commit `368c037`, 2025-12-30 | Training env without TF 2.8 |
| Captive-portal detection by HTTP probe only | RFC 8910/8908 (DHCP 114 + HTTPS API) | RFC 2020; iOS 14+/Android 11+ | Unusable here: the API must be HTTPS |

**Deprecated/outdated in this repo:** `app/api/middleware/auth.ts` (bearer secret, never configured); `runtime/wake-word/train_verifier.py`'s `hey_jarvis` base; `arlowe-recovery.sh`'s `ShowImage`; the comments listed in P1.

---

## Open Questions

1. **Wi-Fi regulatory country.** One build constant (for example US) recorded in an ADR, or a country picker on the setup page? It affects 5 GHz joins and compliance for any unit sold outside that country. Pairing needs an answer before the AP can come up (N2).
2. **Claim-code semantics across reset (N7).** Bind-to-first-device_id with release on revoke is recommended. The owner must confirm, including that an offline reset needs an operator `release`.
3. **Broker URL on a factory image (N11).** Production source is undecided (build-time injection vs vendor config). The checkpoint uses a dev-only FAT-partition file.
4. **Cleartext exposure on the open AP (N8).** Accept and record, or amend the decision to a per-boot WPA2 passphrase carried in the QR?
5. **Is the staged `WhisPlay.py` upstream `bde2b83`?** On the build host: `git -C <Whisplay clone> show bde2b83:Driver/WhisPlay.py | diff - ~/whisplay-staging/WhisPlay.py`. If it differs, re-read the API before 08-11.
6. **B5 contradiction.** Does build A's rootfs have a usable `pi` password (`$6$` in `/etc/shadow`)? This doesn't change the fix. It changes how urgently to warn anyone holding an already-flashed card.
7. **Backup wake phrase.** The owner must name the pre-approved fallback phrase and the training-cycle budget before training starts, or the go/no-go has no "no" branch.
8. **Split Phase 8.1 or keep one phase?** A ROADMAP decision, recommended above.
9. **Who reaps orphaned certificates?** The ledger records them. The consumer (upload on next successful pairing, or a support procedure) is unassigned.

---

## Sources

### Primary (HIGH)
- This repository at `0b45c18` plus `01e7434` (08-CONTEXT). All `file:line` citations were read directly.
- `github.com/RPi-Distro/pi-gen` at `2026-06-18-raspios-bookworm-arm64` (cloned): `build.sh:156-158,206-207,287-296`; `stage1/01-sys-tweaks/00-run.sh`; `stage2/01-sys-tweaks/01-run.sh`; `stage2/02-net-tweaks/01-run.sh`; `export-image/01-user-rename/01-run.sh`; `README.md:170-186`.
- `archive.raspberrypi.com` bookworm arm64 `Packages.gz` (2026-09-28) and the extracted debs `network-manager_1.42.4-1+rpt1+deb12u1`, `raspberrypi-sys-mods_20250930~bookworm`, `raspberrypi-net-mods_1.4.3`: polkit policy and rules, `rfkill_default.conf`, `010_pi-nopasswd`, `sshswitch`.
- `snapshot.debian.org/archive/debian/20260915T000000Z/dists/bookworm/main/binary-arm64/Packages.xz`: every version in the stack table.
- NetworkManager 1.42.4 source (gitlab.freedesktop.org): `src/core/nm-firewall-utils.c` (`_firewall_backend_detect`), `src/core/dnsmasq/nm-dnsmasq-manager.c:23,120-208`, `data/org.freedesktop.NetworkManager.policy.in.in`, `man/nmcli.xml` (`connection add save`).
- `networkmanager.dev/docs/api/1.42.4/NetworkManager.conf.html`: `firewall-backend`.
- `github.com/dscripka/openWakeWord` (cloned): README License section and line 156; tags v0.4.0/v0.6.0 `model.py`, `utils.py`, `setup.py`; HEAD `368c037` `train.py`; `notebooks/automatic_model_training.ipynb`; `examples/custom_model.yml`. The PyPI wheels 0.4.0 and 0.6.0 were inspected. The embedding-model comparison was measured locally with onnxruntime 1.23.2.
- Hugging Face API `datasets/davidscripka/openwakeword_features`: file sizes, LFS oids, `license: cc-by-nc-sa-4.0`.
- `raw.githubusercontent.com/nodejs/node/v24.x/doc/api/crypto.md`: `crypto.argon2` (added v24.7.0).
- `nextjs.org/docs/app/api-reference/file-conventions/proxy` (doc version 16.3.6): rename in v16.0.0, Node runtime, matcher, "don't rely on Proxy alone".
- `github.com/PiSugar/Whisplay` (cloned): `Driver/WhisPlay.py` history; the 344-line version at `bde2b83`.
- RFC 8908 §4 (the API must use an https URI).

### Secondary (MEDIUM)
- [RFC 8910](https://www.rfc-editor.org/rfc/rfc8910.html); [Captive portal (Wikipedia)](https://en.wikipedia.org/wiki/Captive_portal); [Cloud4Wi: captive portal detection](https://cloud4wi.ai/blog/captive-portal-detection/): probe URLs and expected responses.
- [Esper: Android mDNS .local resolution](https://www.esper.io/blog/android-dessert-bites-26-mdns-local-47912385); [Android Police](https://www.androidpolice.com/android-mdns-local-hostname/): Android 12+/13 `.local` support.
- NM device state-reason codes for join failures (7, 8, 11, 53): from NM's public enum; the brcmfmac mapping is to be confirmed on hardware.

### Tertiary (LOW, flagged)
- Training wall-clock and GPU sizing extrapolated from the notebook's own timing note.
- avahi 0.8 not following hostname changes without a restart (recalled behaviour; the restart is harmless either way).

---

## Metadata

**Confidence breakdown**

| Area | Level | Reason |
|---|---|---|
| Repo state (N1, B5-B9, schema, identity, broker, dashboard) | HIGH | Read at `file:line`; N1 corroborated by the SC6 evidence |
| Package availability and cost | HIGH | Snapshot index, Pi index and the inputs reference cross-checked |
| NM AP, firewall backend, dnsmasq conf-dir, polkit defaults | HIGH | NM 1.42.4 source plus the shipped deb |
| Captive-portal client behaviour | MEDIUM | Multiple sources; not tested on phones |
| Privilege split and reset ordering | MEDIUM | Design, grounded in verified mechanisms |
| openWakeWord version and feature-model findings | HIGH | Wheels inspected, models hashed, outputs measured |
| Training cost | LOW-MEDIUM | Extrapolated |
| Whisplay API | MEDIUM | Upstream 344-line commit read; staged copy unconfirmed |
| Device revoke via broker | MEDIUM | No AWS call has ever executed (07-09) |

**Research date:** 2026-09-28
**Valid until:** ~2026-10-28 for external facts. Repo facts are valid until the cited files change. Re-check N10 against 07.3-09's status before scheduling any image-affecting plan.
