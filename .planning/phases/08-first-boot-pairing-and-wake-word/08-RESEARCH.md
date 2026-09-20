# Phase 8: First-boot pairing and wake word — Research

**Researched:** 2026-09-12
**Domain:** device provisioning (captive portal / BLE), consumer account identity, wake-word models, factory reset
**Confidence:** HIGH on repo facts (all cited `file:line`, several verified against upstream sources); MEDIUM on the external stack recommendations; LOW where marked.

---

## Summary

Phase 8's own subject matter — a pairing daemon, a provisioning channel, an owner account, a wake model, a factory reset — is the *smaller* half of what this phase has to deal with. The larger half is that **SC2's last clause, "starts the runtime services," is currently impossible on the built image.** Five of the six runtime units invoke interpreters at `/opt/arlowe/venvs/{voice,llm,stt}/bin/python`, which nothing in the build ever creates; the sixth invokes `/opt/arlowe/runtime/dashboard/server.js`, which no build step ever produces. Every Python dependency those units need (Pillow, numpy, openwakeword, pyaudio, scipy, scikit-learn, faster-whisper) is absent from both the apt package list and the Pi OS Lite base. A pairing daemon that runs perfectly and then calls `systemctl start` will watch all six units fail. Planning Phase 8 without treating this as in-scope produces a phase that cannot pass its own SC2.

The second-largest surprise is a licensing one, and it is not about naming. openWakeWord's pre-trained models — including the `hey_jarvis_v0.1` the device runs today — are **CC BY-NC-SA 4.0, non-commercial**, verbatim in the upstream README. WAKE-01 was written as "we need the right phrase." It is actually "we cannot ship the model we have in a product we sell." That reframes gray area C from a UX nicety into a ship-blocker, and it changes the cost calculus: the custom-training path is not optional polish, it is the only free route to a commercially-licensable wake model — and even it needs a data-provenance audit, because the stock training notebook pulls AudioSet and ACAV100M, which are the very datasets that made the pre-trained models NC.

Three findings landed the *other* way and should stop the planner from writing tasks that aren't needed. `avahi-daemon` **is** in the image (pi-gen `stage2/01-sys-tweaks/00-packages`), so DASH-01's `.local` works. `dnsmasq-base` and `wpasupplicant` **are** in the image, pulled as Recommends of `network-manager` from a pi-gen `00-packages` file (installed *with* recommends), so NetworkManager AP mode and WPA joining are both available without new packages. And `arlowe-identity provision` / `reset --force` already exist and are exactly the API a pairing daemon and a factory reset need (`runtime/cli/identity:212,262`). Phase 7 left a cleaner seam than the phase summary suggests.

**Primary recommendation:** Plan Phase 8 in two halves. Half one is a *substrate repair wave* (venvs or apt-ification, dashboard build step, PIL, the verifier crash, the pi/raspberry SSH default) that must land before any pairing task, because it is what "starts the runtime services" actually means. Half two is the pairing work, on a **NetworkManager AP-mode captive portal** (gray area A), a **device-local owner credential plus an out-of-band claim code** (gray area B), a **self-trained openWakeWord "hey arlowe" model with an audited negative-data set** (gray area C), and a **dashboard-triggered reset with a Whisplay-button fallback, explicitly not slot-B** (gray area D). Each of the four is an ADR task.

---

## Part 1 — Blockers the planner must budget for

These are not risks. They are verified current state that Phase 8's success criteria collide with.

### B1. `/opt/arlowe/venvs` is empty, and five units depend on it (HIGH)

`scripts/provision/install-arlowe-fs.sh:51-52` creates `/opt/arlowe/venvs` and says "Phase 6 populates from `runtime/*/requirements.txt`". Phase 6 does not. `grep -rn "pip\|requirements\|venv" pi-gen/stage-arlowe/` returns only the word `venv` inside `python3-venv` in the package list — no `pip install`, no `python -m venv`, anywhere in the build.

Affected units:

| Unit | Interpreter referenced | File |
|---|---|---|
| `arlowe-face` | `/opt/arlowe/venvs/voice/bin/python` | `units/arlowe-face.service` (ExecStartPre + ExecStart) |
| `arlowe-voice` | `/opt/arlowe/venvs/voice/bin/python` | `units/arlowe-voice.service` |
| `qwen-tokenizer` | `/opt/arlowe/venvs/llm/bin/python` | `units/qwen-tokenizer.service` |
| `whisper-stt` | `/opt/arlowe/venvs/stt/bin/python` | `units/whisper-stt.service` |
| `qwen-api` | — (shell script) but `Requires=qwen-tokenizer.service` | `units/qwen-api.service` |

So all five fail, and `qwen-api` fails by dependency. `.planning/STATE.md:59` already records this as "Open debt for Phase 8."

### B2. Pillow and numpy are not on the image (HIGH — verified against the Pi OS Lite manifest)

`runtime/face/face.py:26` does `from PIL import Image, ImageDraw, ImageFilter`. `runtime/recovery/arlowe-recovery.sh:96` does the same plus `ImageFont`. `runtime/face/requirements.txt` pins `Pillow==11.1.0` and `numpy==2.3.5`.

`pi-gen/stage-arlowe/00-packages/00-packages-nr` contains no `python3-pil` and no `python3-numpy`. The 2024-11-19 bookworm-arm64 Lite package manifest (`downloads.raspberrypi.com/.../lite.info`) lists 31 `python3-*` packages and **neither is among them**. This is the identical failure class to F7 #18/#21 and the Phase 7 `ModuleNotFoundError` near-miss: `build-image.sh`'s package assertion (`scripts/build-image.sh:141-167`) only checks that *declared* packages landed — it cannot see an import that was never declared.

This matters twice over for Phase 8: PAIR-05 and SC3 need text rendered on the Whisplay, and PIL is how that is done.

### B3. The dashboard has no build step and no `server.js` (HIGH)

`units/arlowe-dashboard.service` has `ExecStart=/usr/bin/node /opt/arlowe/runtime/dashboard/server.js`. That file only exists after a Next.js **standalone** build. `runtime/dashboard/next.config.ts` is the default stub — it does **not** set `output: 'standalone'`. No `npm ci` / `next build` runs anywhere in `pi-gen/stage-arlowe/` or `scripts/build-image.sh`, and `node_modules/` is gitignored (`.gitignore:2,62`) so it is not carried in by the `rsync -a "${REPO_ROOT}/runtime/"` at `pi-gen/stage-arlowe/01-runtime/00-run-chroot.sh:95`.

This is already logged as F7 #20 ("dashboard has no build step") in `.planning/STATE.md:23`. SC2 requires the owner to land on `http://<device-name>.local:3000` authenticated, and DASH-01/DASH-02 are Phase 8 requirements — so this is Phase 8's to close, not deferrable.

### B4. `arlowe-voice` crashes on a factory device because the verifier pickle is absent (HIGH)

`runtime/voice/voice_client.py:348-351`:

```python
print("\n[2/4] Loading verifier...", flush=True)
with open(VERIFIER_MODEL, 'rb') as f:
    verifier = pickle.load(f)
```

Unconditional. `VERIFIER_MODEL` defaults to `/var/lib/arlowe/wake-word/verifier.pkl` (`voice_client.py:44-47`), which does not exist on a factory device. `grep -n "exists()" runtime/voice/voice_client.py` finds exactly one hit and it is `TTS_CONFIG_PATH`, not the verifier. Result: `FileNotFoundError` at startup, `Restart=on-failure`, `RestartSec=10`, forever.

**`runtime/wake-word/README.md` claims this was fixed and it was not.** The README says "Plan 02 wired this via env override; the verifier-absent code path is the v1 generic-model behaviour" and shows an `if not VERIFIER_MODEL.exists()` snippet that is not in the code. It also says the generic path should raise the base threshold to 0.7; `voice_client.py:70` has `BASE_THRESHOLD = 0.20`. A doc asserting a fix that does not exist is precisely the class of error that cost this repo seven weeks before.

### B5. Every factory device ships with SSH open and `pi` / `raspberry` (HIGH)

`pi-gen/config:25` `ENABLE_SSH=1`; `pi-gen/config:51-52` `FIRST_USER_NAME="pi"` / `FIRST_USER_PASS="raspberry"`; `pi-gen/config:56` `DISABLE_FIRST_BOOT_USER_RENAME=0`. `openssh-server` is in the Lite base. The Phase 6 checkpoint notes in `.planning/STATE.md:35` confirm the test card was reachable as `pi` over the LAN.

Phase 8 is the phase that decides what a shipped unit looks like on the network, and it is about to add an open Wi-Fi AP to that picture. Default credentials plus an open AP is a combination that should not leave the building. This is not strictly a PAIR-* requirement, but the pairing flow is the only natural place to close it (rotate/disable `pi` at pairing completion, or drop the user at build time and use support mode from Phase 10 instead).

### B6. Wi-Fi via the dashboard will be denied by polkit, and the routes have a shell-injection bug (MEDIUM / HIGH)

The four routes under `runtime/dashboard/app/api/connectivity/*/route.ts` all shell out to `nmcli` via `child_process.exec`. Two problems:

1. **Authorization (MEDIUM).** `arlowe-dashboard.service` runs `User=arlowe` with `NoNewPrivileges=yes`. `provision/polkit/50-arlowe-systemctl.rules` grants only `org.freedesktop.systemd1.manage-units` — there is **no** NetworkManager polkit rule in `provision/polkit/`. NetworkManager gates `network-control` and `settings.modify.system` on polkit's active/inactive session model; a systemd service user has no login session and is therefore "inactive", which under the stock Debian policy falls through to `auth_admin`, and with no polkit agent present that means denial. I could not read the shipped `.policy` file to quote the exact defaults, so this is MEDIUM — **verify on hardware with `pkcheck` or a one-line `nmcli` run as `arlowe` before planning around it.** The fix, if confirmed, is a sibling rule to `50-arlowe-systemctl.rules`.

2. **Shell injection (HIGH).** `connect/route.ts:28,36,41,46,50` interpolates `${ssid}` into single quotes inside an `exec()` shell string; `saved/route.ts:64` interpolates it into double quotes (`nmcli connection delete "${ssid}"`). The password *is* escaped (`connect/route.ts:45`) — the SSID never is. An SSID is attacker-controlled twice over: any nearby AP can broadcast one, and the pairing form accepts one. `saved/route.ts:53` calls `verifyAuth` but `connect/route.ts:4,11-13` has it commented out with a TODO. Any Phase 8 task that reuses these routes must fix this; `execFile` with an argv array removes the whole class.

### B7. Slot B has never booted. Factory reset cannot depend on it. (HIGH)

`.planning/STATE.md:35,37,41`: the Pi bootloader rewrites `root=` in `cmdline.txt` during the shutdown window (F7 #25), and `tryboot` one-shot is also non-functional — a marker planted in `tryboot_cmdline.txt` never reached `/proc/cmdline`, proving `tryboot.txt` is never read (F7 #28). Both A/B mechanisms are disproven; `autoboot.txt` with two FAT boot partitions is untested and would require rewriting ADR-0004 and Phase 6 SC2. **Slot B has never booted on any image by any method.**

Consequence for SC4: "triggered from dashboard **or recovery SD card**" is satisfiable — recovery SD card means reflashing, which is a separate physical card, not slot B. But any design that reaches a reset mode *by booting the recovery slot* is dead on arrival.

### B8. The journal is volatile, so a pairing failure leaves no trace (MEDIUM)

F7 #22/#27 in `.planning/STATE.md:27,37`: the image ships journald `Storage=volatile`; persistent storage was enabled by hand on the test card only. PAIR-06 requires distinct, diagnosable failure modes; today a failed pairing followed by a reboot leaves nothing to read. `/var/lib/arlowe/logs/` (on the shared owner_state partition, survives A/B and OTA) is the natural breadcrumb location and already exists in the seeded skeleton.

### B9. `boot-check` tells a correctly-behaving unpaired device that it is broken (MEDIUM)

F7 #24, `.planning/STATE.md:31`: `boot-check --first-boot` printed `Results: 0 passed, 14 failed / Some services need attention` on a device sitting correctly in its pre-pairing state — because the six runtime units are *supposed* to be down before pairing. `runtime/cli/boot-check` already has the right signal available: `check_identity()` at line 61 keys off `[ -f "${ARLOWE_ROOT}/etc/arlowe/config.yml" ] && paired=true`. That notion needs to reach `check_service`/`check_port` too, or PAIR-06's "clear failure" surface is drowned in 14 expected failures.

---

## Part 2 — The four gray areas

### A. Provisioning channel (SC1 requires an ADR)

**Recommendation: NetworkManager AP-mode captive portal. Do not use BLE.**

#### What the stack actually needs — and what is already there

Verified against the 2024-11-19 bookworm-arm64 Lite manifest and pi-gen at the pinned ref `2026-06-18-raspios-bookworm-arm64`:

| Component | Present? | Evidence |
|---|---|---|
| `network-manager` 1.42.4 | YES | Lite manifest; also pi-gen `stage2/02-net-tweaks/00-packages` |
| `wpasupplicant` 2:2.10 | YES | Lite manifest (Recommends of network-manager) |
| `dnsmasq-base` 2.89 | **YES** | Lite manifest (Recommends of network-manager) |
| `nftables` 1.0.6 | YES | Lite manifest |
| `iptables` | NO | absent from Lite manifest |
| `hostapd` | NO | not needed — NM AP mode does not use it |
| `avahi-daemon` 0.8 | **YES** | pi-gen `stage2/01-sys-tweaks/00-packages`; Lite manifest |

The load-bearing mechanic: pi-gen's `build.sh:19-37` installs `NN-packages` **with** recommends and `NN-packages-nr` **with `--no-install-recommends`**. `network-manager` is declared in `stage2/02-net-tweaks/00-packages` (the recommends-enabled form), which is why `dnsmasq-base` and `wpasupplicant` are present despite `stage-arlowe`'s own list being `-nr`. `stage0/00-configure-apt/00-run.sh` sets no global no-recommends policy — I checked, because a global `APT::Install-Recommends "0"` would have inverted this conclusion.

**So AP mode needs zero new packages.** The one thing to verify on hardware is that NM 1.42's shared-mode firewall backend works with `nftables` only (no `iptables` binary present). If it does not, add `iptables` to `00-packages-nr` — a one-line change, but find out before writing the plan.

Shape of the flow, all `nmcli`:

```bash
nmcli con add type wifi ifname wlan0 con-name arlowe-pair ssid "Arlowe-Setup-XXXX"
nmcli con modify arlowe-pair 802-11-wireless.mode ap 802-11-wireless.band bg ipv4.method shared
nmcli con up arlowe-pair
```

`ipv4.method shared` makes NM spawn its own dnsmasq (DHCP + DNS) and install the NAT/forward rules. The captive portal then needs the pairing daemon's HTTP server plus a DNS wildcard so that `connectivitycheck.gstatic.com` (Android) and `captive.apple.com` (iOS/macOS) resolve to the device and return a redirect, which is what pops the OS's "Sign in to network" sheet. NM's shared dnsmasq accepts extra config via `/etc/NetworkManager/dnsmasq-shared.d/*.conf` — `address=/#/10.42.0.1` is the one-liner.

#### The AP→station handoff, which is where these designs die

The Pi 5's onboard radio is a **single** interface. It cannot host the AP and join the owner's network at the same time. So at the moment the daemon runs `nmcli device wifi connect`, the phone's session is torn down. Options:

1. **Optimistic handoff (recommended).** Phone POSTs SSID+password+account+name. Daemon replies `200` with "I'm switching networks, this page will stop loading — find me at `http://<name>.local:3000`" **before** touching the radio. Then it brings the AP down, joins, provisions the cert, writes the overlay, starts services. The Whisplay carries the progress from that point (PAIR-05 exists precisely because the companion device goes blind here). If the join fails, the daemon brings the AP **back up** and the owner reconnects to see the error — that fallback is mandatory or a typo'd password bricks the flow.
2. **Validate-then-commit.** Join, confirm, drop back to AP, report success, then join again for real. Two extra radio transitions, ~20-30s slower, but the phone gets a definitive answer. Worth it if SC3's "distinct, owner-readable error on the companion device" is read strictly — under option 1 a bad-password error is only reachable after the owner manually rejoins the AP.
3. **USB Wi-Fi dongle as a second radio.** Eliminates the handoff entirely. Adds a BOM item and a second driver surface. Not worth it for v1.

I would plan option 1 with the AP-restore fallback, and record option 2 in the ADR as the rejected alternative with its reason.

#### Why not BLE

- A companion mobile app does not exist and is in no phase. Building one is an App Store + Play Store presence, two codebases, and a review cycle — for a solo pre-revenue founder that is a quarter of work sitting between the device and its first customer.
- **Improv Wi-Fi** is the obvious "BLE without an app" answer and it does not close the gap: the browser SDK requires WebBluetooth, which is Chrome/Edge/Blink only. **iOS browsers cannot do it at all** — Improv's own docs point iOS users at a native SDK. That leaves roughly half of consumer phones needing the app you were trying to avoid.
- BLE also needs `bluez` + a GATT server on the device, neither of which is in the current package set, and Pi 5 BT/Wi-Fi coexistence on the same chip is its own debugging surface.

**Whisplay QR code: a real shortcut, and cheap.** The display is 240x280 (`runtime/face/face.py:29`), which comfortably holds a version-3/4 QR at ~4px/module. Encoding `WIFI:T:nopass;S:Arlowe-Setup-XXXX;;` makes both iOS and Android join the setup AP by camera scan, removing the "go to Settings, find the network" step — the single most common failure point in consumer onboarding. Cost is one dependency (`python3-qrcode` is in Debian bookworm — **verify it is in the Pi OS archive before declaring it**) plus the PIL fix from B2. Recommend including it; it does not replace the AP, it just removes friction in reaching it.

---

### B. What an "owner account" is

**Recommendation: a device-local owner credential (username + Argon2id-hashed password, stored in the overlay/state), plus an out-of-band claim code printed in the box that the pairing flow exchanges at the broker for the CSR token. Explicitly defer a hosted identity service to v2.**

The forcing constraint is in ADR-0007 and it is worth restating: the design is **token-agnostic by contract**. `scripts/pki/broker.py:62-67` compares the presented bearer token against `$ARLOWE_BROKER_TOKEN` with `hmac.compare_digest` and the file's own docstring says "Do not add a user table, an account lookup, or a token-minting endpoint." `runtime/cli/identity:192-209` resolves the token from `--owner-token`, `--owner-token-file`, or `ARLOWE_OWNER_TOKEN` and never inspects it. ADR-0007's frozen commitment is: *a hand-minted token for a single unit and a token issued by a future account system must both work against the same device code, unchanged.*

That means the device half of this is already done, and the real question is only *who mints the token and where the dashboard password lives.*

| Option | What it costs | v1 blast radius | Phase 7 contract |
|---|---|---|---|
| **Device-local credential only** (no backend; owner picks a password at pairing, dashboard checks it) | ~0. Argon2id via `python3-argon2` or Node `argon2`; session cookie in the Next.js app. | Compromise is one device on one LAN. No fleet-wide secret. No account recovery either — forgotten password = factory reset. | **Intact.** But leaves the token question unanswered: something still has to supply the broker token. |
| **+ pre-shared claim code in the box** (recommended pairing) | Low. A per-unit code generated at manufacture, printed on a card, registered in a table the broker reads. Broker changes from one shared `$ARLOWE_BROKER_TOKEN` to a small list. | One unit per code. A leaked code lets someone mint one cert for one device-id they don't physically have — bound to a Thing you can revoke. | **Intact in spirit** — the broker gains a lookup, which its docstring forbids *for Phase 7*; Phase 8 is explicitly where that changes. The *device* code needs no change, which is the contract that actually matters. |
| **Hosted identity service (founder-built)** | High and recurring. Signup, email verification, password reset, an always-on service, a privacy policy, a support surface, a bill. ADR-0007 already flags the broker alone as "a new always-on dependency and a new outage surface." | A breach is fleet-wide. A service outage is a **pairing outage** — nobody can unbox an Arlowe until you're back up. | Intact (that is the design's whole point), but you now own the thing ADR-0007 deliberately deferred. |
| **Third-party OAuth / IdP** (Auth0, Clerk, Google) | Low-to-medium build, free at small scale. But an offline-first privacy appliance that requires a Google login to finish setup is a positioning contradiction against "Privacy is the differentiator" (`REQUIREMENTS.md`, Out of Scope). Also needs internet *during* pairing. | Depends on the IdP. Account recovery becomes theirs, which is a genuine benefit. | Intact. |

The practical v1 shape: **the dashboard password is device-local and never leaves the device; the broker token comes from the claim code; the two are independent.** That keeps DASH-02 ("authenticates with the credentials captured during pairing") honest without inventing a backend, and it leaves the door open to swapping the claim code for a real account token later with zero device-side change — which is exactly what ADR-0007 bought.

Two things the plan must not skip:
- The dashboard has **no** session machinery. `runtime/dashboard/app/api/middleware/auth.ts` is a bearer-token helper with a hand-rolled `timingSafeEqual` (lines 68-83 — note it compares char codes, not bytes, and is only referenced from `saved/route.ts:53`; `connect/route.ts:4` has it commented out). DASH-02 is a from-scratch build: session cookie, login page, middleware covering every mutating route. Don't hand-roll the hash — use Argon2id from a library.
- `config/schema.yml` has `additionalProperties: false` at the top level (line 23) **and** inside `device` (line 39), where the only property is `hostname`. There is nowhere to write a display name, an owner record, a Wi-Fi reference, or the WAKE-03 toggle. Schema extension is a prerequisite task, not a footnote.

---

### C. The "Hey Arlowe" wake model (WAKE-01, SC5)

**Recommendation: train a custom openWakeWord model for "hey arlowe" with an audited negative-data set. Budget it as its own multi-day plan with a real go/no-go, and keep "change the phrase" as the documented fallback — because the phrase is not what makes this hard.**

#### The finding that reframes this

From the openWakeWord README, verbatim (`github.com/dscripka/openWakeWord`, License section):

> All of the code in this repository is licensed under the **Apache 2.0** license. All of the included pre-trained models are licensed under the [Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International](https://creativecommons.org/licenses/by-nc-sa/4.0/) license due to the inclusion of datasets with unknown or restrictive licensing as part of the training data.

`hey_jarvis_v0.1` — what `runtime/voice/voice_client.py:344`, `runtime/voice/wake_test.py:13`, and `runtime/wake-word/quick_test.py:43` all select — is one of those six pre-trained models. **Shipping it in a product for sale is a license violation.** "Switch the wake phrase to something with a usable pretrained model" is therefore not a cheap escape: there is no commercially-usable pretrained model in the set. The only options are train-your-own, pay a vendor, or get permissively-licensed models added upstream (the README invites an issue: *"If you are interested in pre-trained models with more permissive licensing, please raise an issue"* — worth filing, costs nothing, but is not a plan).

#### The version problem

`runtime/voice/requirements.txt:6` pins `openwakeword==0.4.0` (released 2023-04-22). Comparing trees: `v0.4.0` contains `openwakeword/{__init__,custom_verifier_model,data,metrics,model,utils,vad}.py` and **no `train.py`**; `main` (0.6.0, 2024-02-11) adds `train.py` and `notebooks/automatic_model_training.ipynb`. **The pinned version cannot run the modern automated training path.**

This is fine, because training is off-device. `openwakeword.Model(wakeword_model_paths=[...])` in 0.4.0 accepts arbitrary ONNX paths (`openwakeword/model.py:36-49,82-86` at `v0.4.0`), and the auto-trainer emits both `.onnx` and `.tflite`. So: **train with 0.6.0+ on a Linux GPU box, ship the `.onnx`, keep 0.4.0 on-device** — or upgrade the device pin, which also needs a compatibility check against `onnxruntime==1.23.2`. Either is defensible; the plan should pick one explicitly.

#### What training actually costs

From `notebooks/automatic_model_training.ipynb`:

- **Linux only** ("automated model training is only supported on linux systems due to the requirements of the text to speech library"). Not the Mac. arlowe-1 is a Pi — usable but slow; a rented GPU hour is the sane answer.
- Five data inputs: synthetic positives (Piper TTS via `dscripka/piper-sample-generator` with `en_US-libritts_r-medium.pt`), synthetic adversarial negatives, room impulse responses (`davidscripka/MIT_environmental_impulse_responses`), generic negatives (**AudioSet** + **FMA**, or the precomputed **ACAV100M** 2000-hour feature file), and a validation set.
- The notebook's *demo* config is 1,000 samples / 10,000 steps and is explicitly undersized. Production models want several thousand positives and the full negative sets.
- Stated target metrics from the default config: accuracy ≥ 0.7, recall ≥ 0.5, false-positive ≤ 0.2/hour. The README's project-level aim is "<5% false-reject, <0.5/hour false-accept."
- Realistic budget: **1-2 days** including data download (AudioSet tarballs are large), one or two retrain cycles, and on-device evaluation. The "under one hour" Colab claim is for a toy model.

**The licensing trap repeats itself here, and the planner must see it.** AudioSet and ACAV100M are exactly the "datasets with unknown or restrictive licensing" that made the official models NC. Training your own model using the stock notebook inherits the same provenance question. A commercially-clean model needs a deliberate data audit: MIT RIR (permissive), Piper/LibriTTS-R synthetic positives (check the LibriTTS-R checkpoint's terms), and negatives from sources you can license — CC-licensed FMA subsets, your own recordings, or purchased corpora. **Treat "is this model commercially licensable" as an explicit acceptance criterion of the training task, not an assumption.** Getting this wrong ships the same violation with extra steps.

#### Runtime feasibility on a Pi 5

Not a concern. The README states a single Raspberry Pi 3 core runs 15-20 openWakeWord models simultaneously in real time; a Pi 5 running one model is far inside budget. Model artifacts are ~200KB ONNX.

#### How SC5 is actually tested

"Wakes on at least three independent voices without per-customer training" is a manual test and should be planned as a non-autonomous hardware checkpoint, matching the Phase 1/3/4/5/6 precedent. A defensible protocol:

- Three speakers who contributed **no** training data, varied in gender and pitch. Voices heard during training don't test generalization.
- N=20 utterances each at ~2m in a normal room → 60 trials; record the wake rate. Below ~90% and the model needs another cycle.
- A false-accept counter over a ≥1h ambient session (TV/music/conversation) — SC5 says nothing about false accepts, but a model that wakes constantly passes SC5 and fails the product.
- Run it with the **verifier absent** (B4's fixed path), since that is the shipped v1 configuration.

#### One "don't hand-roll" worth acting on

openWakeWord 0.4.0 already exposes `custom_verifier_models` and `custom_verifier_threshold` (`openwakeword/model.py:42-43,65-69`) and ships `openwakeword/custom_verifier_model.py`. This repo instead built its own verifier out of a scikit-learn pickle (`runtime/wake-word/train_verifier.py`, loaded at `voice_client.py:349`). For WAKE-03/WAKE-04 personalization, moving to the library's mechanism drops `scikit-learn` and `joblib` from the device dependency set entirely — a meaningful saving given B1/B2.

---

### D. Factory reset scope and trigger (SC4, PAIR-07)

**Recommendation: dashboard-triggered as primary, Whisplay long-press as the unauthenticated fallback, recovery SD card as the documented last resort. Do not touch p5. Revoke server-side before wiping locally.**

#### The identity consequence is real, and confirmed

`runtime/lib/arlowe_identity.py:123-126`:

```python
def derive_device_id(source_tag: str, serial: str, entropy: bytes) -> str:
    material = f"{source_tag}:{serial}:{entropy.hex()}".encode()
    return hashlib.sha256(material).hexdigest()[:32]
```

`ensure_entropy()` (lines 108-120) generates 32 bytes from `os.urandom` once and persists them to `/var/lib/arlowe/identity/device-entropy`. `ensure_device_id()` (lines 179-200) is write-once and never re-derives. So: **wiping `identity/` destroys the entropy → the next `init` generates fresh entropy → a different device-id → a different CSR CN → a new Thing and a new certificate.**

The old certificate and Thing are **orphaned server-side**. Nothing in `runtime/cli/identity`'s `cmd_reset` (lines 262-277) revokes anything — it unlinks every file in the directory and re-chmods it to 0700, offline. An owner who factory-resets five times leaves five live certificates in the AWS account, each able to fetch credentials until someone revokes it by hand. ADR-0007's revocation guarantee ("one polling interval") is about *deliberate* revocation and says nothing about this path.

The reset flow therefore needs an ordering, and it has to tolerate being offline:

1. **Best effort:** call revoke for the current `certificate_id` (it is in `identity.json` — `runtime/cli/identity:161-162` reads it back via `ISSUANCE_FIELDS`) while the network is still up.
2. Then wipe. If step 1 failed (no network, broker down), **wipe anyway** — a reset that refuses to run offline is worse than an orphan — but record the orphaned `certificate_id` somewhere durable so it can be reaped later.
3. `/var/lib/arlowe/logs/` survives on owner_state and is the obvious place for that record; it needs to be excluded from the wipe.

The alternative design — **preserve the entropy across reset** so the device-id is stable and the cert can be reused — is worth putting in the ADR as the considered option. It removes the orphan problem entirely and makes a device's identity as durable as its silicon. It costs privacy (a resold unit remains correlatable to its previous life) and it means a reset does not fully clear IDENT-06 material, which reads against PAIR-07's "clears `/var/lib/arlowe/identity/`". Both readings are defensible; the ADR should pick one on purpose rather than inherit one from `cmd_reset`'s current behaviour.

#### Scope

| Path | Wipe? | Why |
|---|---|---|
| `/etc/arlowe/config.yml` | YES | Its absence *is* the pairing trigger (`pi-gen/stage-arlowe/03-firstboot/00-run-chroot.sh:11`, CONFIG-03) |
| `/var/lib/arlowe/identity/` | YES | PAIR-07 says so — subject to the entropy decision above |
| `/var/lib/arlowe/conversations/` | YES | Owner speech. A resold unit must not carry it. |
| `/var/lib/arlowe/wake-word/` | YES | Biometric voice data (`runtime/wake-word/README.md`: "Owner data; never leaves device") |
| `/var/lib/arlowe/state/` | YES | selfcheck JSON, runtime state |
| `/var/lib/arlowe/dashboard/` | YES | Next.js cache, sessions |
| `/var/lib/arlowe/logs/` | Partial | Keep the orphaned-cert record and a reset audit line; drop transcripts |
| NM connection profiles (`/etc/NetworkManager/system-connections/`) | **YES** | Not on any list in SC4, and it is the owner's Wi-Fi PSK in plaintext. A reset that leaves it behind hands the buyer the seller's home network. |
| `/opt/arlowe/models` (p5) | **NO** | Read-only, shared across slots, identical on every unit, ~24-48GB. Wiping it makes the device unrecoverable without a reflash. |

That NM-profiles row is the one SC4 does not mention and should.

#### Trigger

| Trigger | Verdict | Notes |
|---|---|---|
| Dashboard (DASH-05 lists it) | **Primary.** | Requires auth. But useless if the owner has forgotten the password — which is the single most likely reason to want a reset. |
| Whisplay button long-press | **Required fallback.** | The board has exactly **one** button (upstream `WhisplayBoard.BUTTON_PIN = 11`, with `on_button_press` / `on_button_release` callbacks and a polling monitor thread). A 10s hold with an on-screen countdown and a confirmation press is the standard consumer pattern. Physical access is the authorization, which is correct for a device whose key material is already extractable by anyone holding the SD card (ADR-0007's accepted tradeoff). |
| Recovery SD card | **Document only.** | PART-06 already makes this the v1 bricked-device fallback. It means reflashing, which resets everything by construction. |
| Boot into slot B and reset from there | **Do not plan this.** | B7: slot B has never booted. |

Note that the button is claimed by `arlowe-face` (`units/arlowe-face.service` holds `/dev/gpiochip*`), so the reset listener either lives inside the face service or needs an arbitration story. Worth a task-level decision.

---

## Part 3 — Answers to the specific "also worth checking" questions

**Whisplay resolution and how much text fits.** Physical 240x280 portrait; `face.py` draws a 280x240 landscape canvas and rotates CCW (`runtime/face/face.py:29-31`, `386-392`). There *is* a working text precedent — `runtime/recovery/arlowe-recovery.sh:89-109` renders "RECOVERY / Resetting to slot A / Rebooting..." with PIL. **But that precedent is broken in two ways.** First, it calls `board.ShowImage(img)` (line 105); the upstream driver has **no such method** — it exposes `draw_image(x, y, width, height, pixel_data)` taking a raw RGB565 pixel sequence, which is what `face.py:592` correctly uses. The call is inside a `try/except` that logs "face draw failed (non-fatal)", so the recovery display has been silently dead. Second, it uses PIL's default bitmap font (no `truetype` call anywhere in the repo), which is ~11px — legible but cramped. Realistic budget at 240px wide with a 16-20px TrueType font: **~16-20 characters per line, 4-6 lines.** That is enough for SC3's four failure modes if they are written as short strings ("Wi-Fi password / rejected", "Can't reach / Arlowe servers", "Account sign-in / failed", "Couldn't get / device certificate") plus a QR or short URL. The RGB LED (`set_rgb`, `set_rgb_fade`) is a second, coarser status channel worth using for waiting/connecting/paired/error. **Caveat:** `third_party/whisplay-driver/` contains only `INSTALL.md` and `PROVENANCE.md` — `WhisPlay.py` is not committed and INSTALL.md still says "Commit: (pin at first fetch)" with no SHA recorded. Upstream `main` has moved to `runtime/whisplay.py` with class `WhisplayBoard` (lowercase p) on gpiod, while this repo imports `WhisPlayBoard` from `WhisPlay.py` on RPi.GPIO — so the vendored copy is an older, unpinned commit. My upstream API reading is from `main`; **the old pinned file may differ and should be read directly before any Whisplay task is written.** F2 in STATE already flags a 344-vs-662-line divergence between the dev copy and upstream HEAD.

**Where the pairing daemon slots into the first-boot chain.** Current order: `arlowe-identity-init.service` (`Before=arlowe-firstboot.service multi-user.target`, `RequiresMountsFor=/var/lib/arlowe`, runs `identity init` offline) → `arlowe-firstboot.service` (`ExecStartPre=arlowe-grow-models`, `ExecStart=boot-check --first-boot`, `ExecStartPost=touch /var/lib/arlowe/.firstboot-done`, guarded by `ConditionPathExists=!/var/lib/arlowe/.firstboot-done`). A pairing daemon belongs **after both**, gated on `ConditionPathExists=!/etc/arlowe/config.yml` (PAIR-01) rather than on the firstboot sentinel — because a factory reset must return the unit to pairing on a device where `.firstboot-done` already exists. Note `arlowe-identity-init` deliberately has **no** `Condition*` guard and `RestrictAddressFamilies=AF_UNIX` (offline by contract); the pairing daemon is its opposite and needs `AF_INET`/`AF_INET6` plus `AF_NETLINK` for NM.

**The six units and how they start.** `units/install-units.sh:13-20` copies `units/*.service` into `/etc/systemd/system` and **creates no `wants` symlinks**. Only `03-firstboot/00-run-chroot.sh:76-77,140-142` symlinks `arlowe-firstboot.service` and `arlowe-identity-init.service` into `multi-user.target.wants`. So the six — `arlowe-dashboard`, `arlowe-face`, `arlowe-voice`, `qwen-api`, `qwen-tokenizer`, `whisper-stt` — ship installed-but-disabled, confirmed as deliberate in `.planning/STATE.md:27`. The intended start mechanism already exists: `provision/polkit/50-arlowe-systemctl.rules` grants the `arlowe` user `org.freedesktop.systemd1.manage-units` for units prefixed `arlowe-`, `qwen-`, or named `whisper-stt.service`, and its own comment names "pairing daemon completion (Phase 8 will use; starts runtime services)". The daemon should `systemctl enable --now` them (enable, so they persist across reboot — plain `start` would leave a paired device dead after a power cycle). **All of this is correct and none of it helps until B1/B2/B3 are fixed.**

**What pairing must write to `config/schema.yml`, and whether the keys exist.** They mostly do not. `additionalProperties: false` at line 23 (top level) and line 39 (`device`) means anything not enumerated fails validation, and every unit's `ExecStartPre=python -m arlowe_config_validate` exits 78 on a schema violation — so a pairing daemon that writes an unknown key bricks the device it just paired.

| Pairing needs to write | Exists? | Where |
|---|---|---|
| `device.hostname` (resolved from the template) | YES | `schema.yml:45-51`; resolver at `arlowe_identity.py:202-217` |
| `device.display_name` (PAIR-03) | **NO** | `device` has only `hostname` |
| Owner account record / password hash (DASH-02) | **NO** | no such block |
| Wi-Fi reference (SANIT-03 says SSID becomes owner-provisioned) | **NO** | credentials belong in NM profiles, but a reference/label for the dashboard does not exist |
| Wake personalization toggle (WAKE-03) | **NO** | no `wake` block at all |
| `identity.provisioning_url` / `credentials_endpoint` / `role_alias` | YES | `schema.yml:213-257`, all default `""` |
| `ota.channel_url` — comment says "set at pairing" | YES | `schema.yml:206-211` |

Note `resolve_hostname` (`arlowe_identity.py:202-217`) substitutes `"d" + device_id[:12]`, **not** the raw id, deliberately — because a raw hex id beginning with a digit would spell the banned literal `arlowe-1` and trip `scripts/sanitize/check.sh` in `--scan-dir` mode, which ignores the allowlist. Its docstring says "Do not 'simplify' this back to the raw id." If pairing lets an owner choose a device name, **that free-text name will be substituted into a hostname and written to disk, and the sanitize gate will see it.** An owner who types "arlowe-1" gets a device that fails its own build gate. Input validation on the display name is a required task, not a nicety.

**DASH-01 mDNS.** `avahi-daemon` 0.8-10 **is** present (pi-gen `stage2/01-sys-tweaks/00-packages`, confirmed in the Lite manifest). No new package. But **nothing applies `device.hostname` to the system** — `grep -rn "hostnamectl\|/etc/hostname"` across `scripts/provision/`, `pi-gen/`, and `units/` returns only the dev-Pi guard in `install-arlowe-on-arlowe1-staging.sh:27` and `TARGET_HOSTNAME="arlowe"` in `pi-gen/config:22`. Every unit would therefore advertise as `arlowe.local`, which collides the moment a household owns two. Pairing must call `hostnamectl set-hostname`, update `/etc/hosts`, and restart avahi — and that needs a polkit/privilege story too, since the daemon will not be root if it follows the `User=arlowe` pattern. `libnss-mdns` is absent from the image but is not needed: it is a *resolver* module for the client; advertising only needs avahi-daemon, and iOS/macOS/Windows/modern Android resolve `.local` natively.

---

## Part 4 — Common pitfalls specific to this phase

**Trusting a README over the code.** `runtime/wake-word/README.md` documents a verifier-absent code path that does not exist (B4). `scripts/provision/install-arlowe-fs.sh:51` says "Phase 6 populates" the venvs; Phase 6 does not (B1). `pi-gen/stage-arlowe/00-packages/00-packages-nr:9` says "units use system python3 + per-service venvs" while line 45 of the same file says "/opt/arlowe/venvs is not populated by the image build" — the file contradicts itself. **Read the code, then the doc, and treat disagreement as a finding.**

**Declaring an import without declaring its apt package.** B2 is live. `build-image.sh:141-167` asserts declared packages landed; it cannot see an undeclared import. Any Phase 8 task adding a device-side Python import must add the apt package in the same change — `qrcode`, `argon2`, `PIL`, whatever. Verify the package exists in the Pi OS bookworm archive, not just Debian.

**Silent no-ops.** This repo's recurring failure mode — F7 #18 (package list nothing read), #21 (dangling symlink), #25 (flip that reverts), the `try/except` swallowing `ShowImage`. Phase 8 adds more of the same surface: a `wants` symlink to a pairing unit, an `nmcli` call denied by polkit, a systemd `Condition*` that skips rather than fails. `units/arlowe-identity-init.service` documents the right posture in its own comments — fail loudly, never `Condition*` a critical unit — and Phase 8 should copy that posture, not just that file.

**Testing the pairing flow only on the happy path.** SC3 requires four *distinct* failure modes. Each needs a deliberate way to be provoked in a test: wrong PSK, broker URL pointed at a black hole, bad token, broker returning a rejection. `runtime/cli/identity` already gives distinct exit codes for three of them (`0 ok, 2 usage, 3 rejected, 4 cloud unavailable, 5 local state, 6 revoked` — `runtime/cli/identity:50-55`), which maps cleanly onto the Whisplay strings. Use it rather than inventing a parallel taxonomy.

**Assuming a live cloud endpoint.** Per the orchestrator's fact 5 and `.planning/STATE.md:59`: no `aws` call in `scripts/pki/` has ever executed, ADR-0007 is **Proposed**, and there is no staging account. `scripts/pki/broker.py` is explicitly "dev host only." Phase 8's cert-request step has to be planned against a **local** broker with a stubbed IoT backend, with the real-cloud verification called out as a separate, owner-gated checkpoint. Planning SC2 as "obtains a device cert from production" makes Phase 8 inherit Phase 7's blocker.

---

## Open questions

1. **Does NetworkManager 1.42 shared mode work with `nftables` only?** `iptables` is absent from the Lite image. NM supports both backends and auto-detects, but I did not verify 1.42's nftables path end to end. **Resolve by running `nmcli con up` on an AP profile on real hardware before the plan is written.** Fallback is one line in `00-packages-nr`.
2. **Exact NetworkManager polkit defaults for an inactive (systemd-service) subject.** I could not read the shipped `.policy` file to quote `allow_inactive`. The mechanism (polkit active/inactive sessions) is well established; the specific default is MEDIUM. `pkcheck --action-id org.freedesktop.NetworkManager.network-control --process $$` run as `arlowe` settles it in one command.
3. **What is in the *pinned* `WhisPlay.py`?** Not committed; INSTALL.md records no SHA; upstream `main` has a renamed class on a different GPIO stack. All my driver-API claims come from upstream `main` and are corroborated by `face.py`'s usage, but the vendored file is an older commit. F2 already flags a 344-vs-662-line divergence. **Read the actual vendored file on arlowe-1 before writing any Whisplay task.**
4. **Is a self-trained openWakeWord model commercially licensable?** The pre-trained models are NC because of the training data. The stock auto-training notebook uses AudioSet and ACAV100M. Whether a model trained on those is itself encumbered is a legal question, not an engineering one. **Make it an explicit acceptance criterion of the training task.**
5. **Does `python3-qrcode` exist in the Pi OS bookworm archive?** It is in Debian bookworm; the Pi OS archive is a superset in most respects but I did not confirm. Only matters if the QR shortcut is adopted.
6. **Where does the reset button listener live** given `arlowe-face` holds the GPIO chips? Design decision, not a research gap.
7. **How large does Phase 8 get once B1-B5 are inside it?** This may warrant splitting the substrate repair into its own phase (or a Phase 6.5) rather than growing Phase 8 past what a phase should carry. Worth an explicit call at planning time.

---

## Sources

### Primary (HIGH)
- This repository at `main` (commit `e7dff4f`) — all `file:line` citations above were read directly.
- `github.com/RPi-Distro/pi-gen` at tag `2026-06-18-raspios-bookworm-arm64` (the ref `scripts/build-image.sh:70` pins) — `build.sh` package-install semantics, `stage2/01-sys-tweaks/00-packages`, `stage2/02-net-tweaks/00-packages`, `stage0/00-configure-apt/00-run.sh`.
- `downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2024-11-19/2024-11-19-raspios-bookworm-arm64-lite.info` — full dpkg manifest of a bookworm-arm64 Lite image. Source of every "present / absent" claim about the base.
- `github.com/dscripka/openWakeWord` — README (License section quoted verbatim), `notebooks/automatic_model_training.ipynb`, `openwakeword/model.py` at `v0.4.0`, and the `v0.4.0`-vs-`main` tree diff.
- `github.com/PiSugar/Whisplay` `runtime/whisplay.py` at `main` — `WhisplayBoard` method list, `LCD_WIDTH=240` / `LCD_HEIGHT=280`, `BUTTON_PIN=11`. **Applies to `main`, not necessarily to the vendored commit.**
- `packages.debian.org/bookworm/network-manager` — `dnsmasq-base` and `wpasupplicant` are Recommends; `iptables` is Suggests.

### Secondary (MEDIUM)
- `improv-wifi.com` and `github.com/improv-wifi/sdk-ble-js` — WebBluetooth requirement and the iOS limitation.
- Raspberry Pi Foundation and community documentation on `nmcli` AP mode under Bookworm (raspberrypi.com hotspot tutorial; raspberrytips.com; waltsworkbench.com WPA2/WPA3 articles) — corroborating, not authoritative.
- GNOME networkmanager-list archive on polkit session tracking and the "not authorized to control networking" class of failure.

### Tertiary (LOW — flagged, not relied on)
- Picovoice Porcupine pricing (~$6,000/yr Starter; custom wake words gated to Enterprise). **Picovoice publishes no prices**; this figure comes from third-party aggregators. Treat exactly as ADR-0007 treats Smallstep: unplannable without a quote.
- Community claims that Home Assistant Voice PE's "okay nabu" is permissively licensed — unverified, and Voice PE uses microWakeWord on ESP32 rather than openWakeWord, so it is probably not a transferable precedent.

---

## Metadata

**Confidence breakdown**

| Area | Level | Why |
|---|---|---|
| Repo-state blockers (B1-B9) | HIGH | Read from source with line citations; B2 cross-checked against an official Pi OS package manifest; B1/B3/B7/B8/B9 independently corroborated by `.planning/STATE.md` |
| Provisioning stack availability (A) | HIGH | Verified against pi-gen at the pinned ref **and** the Lite dpkg manifest, including the recommends-vs-no-recommends mechanic that decides it |
| AP→station handoff design (A) | MEDIUM | Single-radio constraint is certain; the specific flow is a design recommendation, not a verified implementation |
| Owner account options (B) | HIGH on the Phase 7 contract (read from ADR-0007 and `broker.py`); MEDIUM on the cost estimates |
| openWakeWord model license (C) | HIGH | Quoted verbatim from upstream README |
| Custom-model training cost (C) | MEDIUM | From the upstream notebook's own text; the "1-2 days" figure is my estimate |
| Derived-model licensing (C) | LOW | Genuinely unresolved; flagged as an acceptance criterion rather than answered |
| Factory reset consequences (D) | HIGH | `derive_device_id` / `ensure_entropy` / `cmd_reset` read directly; slot-B unavailability from three separate STATE entries |
| NetworkManager polkit defaults | MEDIUM | Mechanism established, exact policy values unread |
| Whisplay driver API | MEDIUM | Upstream `main` verified; the vendored pinned file is not in the repo |

**Research date:** 2026-09-12
**Valid until:** ~2026-10-12 for the external stack. Repo-state findings are valid until the cited files change — re-verify B1-B4 before planning if anything merges to `main` in the interim.
