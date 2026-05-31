# Phase 3: Service user and filesystem layout — Research

**Researched:** 2026-05-26
**Domain:** Debian/Pi OS system user provisioning + systemd hardening + read-only `/opt` runtime
**Confidence:** HIGH on layout, user, units. MEDIUM on Next.js cache placement. MEDIUM on testbed choice (one option requires later real-Pi validation regardless).

---

## 1. TL;DR / Recommendations

**Phase 3 is artifact-producing, not image-producing.** Phase 6 owns pi-gen and the actual `.img`. Phase 3 produces (a) a provisioning script (`scripts/provision/install-arlowe-user.sh`), (b) a layout-creation script (`scripts/provision/install-arlowe-fs.sh`), (c) a `units/` tree under the repo with the seven system-level service units, (d) a `units/install-units.sh` install helper, and (e) a docs/layout reference. These hand off cleanly to a single pi-gen stage in Phase 6 and to a deploy-to-Pi script today.

**Strong recommendations, in priority order:**

1. **Testbed: Docker container running `debian:bookworm-slim` with systemd-as-PID-1 (privileged), plus a "Phase-3-staging-on-arlowe-1" manual sub-target.** Reject systemd-nspawn (Pi 5's host kernel works, but the workforce already runs Docker on the Mac and Arlowe-1, and the goal is unit-syntax + filesystem-layout validation, not hardware-loop validation). Reject QEMU Pi-5 emulation (no usable QEMU machine model for Pi 5; Pi 4 model exists but boot delays + Wi-Fi/audio device mismatches make it net-cost over Docker). Reject "defer all to Phase 6" (we want to ship Phase 3 with a green test on a real systemd before Phase 6 schedules months of work). The Docker testbed validates SC1, SC2, SC3 (unit-syntax and `systemd-analyze security` scoring) and a synthetic SC4. The arlowe-1 staging sub-target validates SC1–SC4 against the real Pi hardware (SPI/GPIO/ALSA) under a side-by-side `arlowe-staging` user that does **not** disrupt the existing `focal55` daily-driver setup.

2. **Create `arlowe` as a true system user via `useradd --system --user-group --create-home --home-dir /var/lib/arlowe --shell /usr/sbin/nologin arlowe`.** Supplementary groups: `audio`, `gpio`, `spi`, `dialout`, `video`. Do **not** use `DynamicUser=` — persistent state under `/var/lib/arlowe` and a stable UID for log/file ownership across reboots are non-negotiable.

3. **Python venvs live at `/opt/arlowe/venvs/{voice,stt,tts,llm}/`, baked at image-build, root-owned, read-only.** App-only OTA (Phase 9) updates them by running as root with a narrow `ReadWritePaths=/opt/arlowe`. Reject mutable `/var/lib/arlowe/venvs/` (first-boot population is a 5–10 minute boot stall on Pi 5, and a network-dependent first boot is a UX disaster for pairing).

4. **Dashboard: `next build` with `output: 'standalone'` baked into `/opt/arlowe/runtime/dashboard/.next/standalone/`.** Run via `node server.js`. Set `NEXT_PRIVATE_CACHE_DIR=/var/lib/arlowe/dashboard/cache` to relocate the runtime cache off the read-only mount. No `pnpm`/`npm` on the device.

5. **Seven shipping units: `arlowe-face.service`, `arlowe-voice.service`, `arlowe-dashboard.service`, `qwen-tokenizer.service`, `qwen-api.service`, `whisper-stt.service`, `arlowe-wake-word.service` (split-out, see §7).** Phase 3 does **not** ship `qwen-openai.service` (ADR-0001 resolved; deprecated) and does **not** ship `arlowe-scheduled-summary` (ADR-0002). The pairing-daemon and OTA-agent units belong to Phase 8 and Phase 9 respectively, but Phase 3 documents the unit-name reservations.

6. **Hardening baseline applied to every shipping unit, with per-unit `ReadWritePaths=` deltas.** Use systemd's `StateDirectory=arlowe/...` and `LogsDirectory=arlowe/...` directives **on top of** the `arlowe` user — systemd will create per-service writable subdirs under `/var/lib/arlowe/` and `/var/log/arlowe/` automatically. `ProtectSystem=strict`, `ProtectHome=yes`, `NoNewPrivileges=yes`, `PrivateTmp=yes`, plus per-unit `PrivateDevices=no` (face needs SPI; voice needs ALSA) with `DeviceAllow=` carving the device access tight. Target `systemd-analyze security` score ≤ 4.0 for the face/voice units (which need hardware) and ≤ 3.0 for everything else.

7. **CLI helpers install via root-owned symlinks at `/usr/local/sbin/arlowe-{face,speak,stt,record,boot-check,purge-logs,run-logrotate,wake-train}` pointing into `/opt/arlowe/runtime/cli/`.** Owner shells into the device via the Phase-10 support-mode mechanism (which is a *founder* SSH key, not `arlowe`), and invokes CLI via `sudo -u arlowe -- /usr/local/sbin/arlowe-boot-check` etc. The `arlowe` user stays `nologin`; this is correct and not a problem.

8. **Phase 3 reserves `/etc/arlowe/config.yml` and creates an empty `/etc/arlowe/` directory with mode 0755 owned by `root:arlowe`. The dashboard writes to it via a privileged-helper pattern (Phase 4 owns).** Do **not** put `/etc/arlowe/config.yml` in any unit's `ReadWritePaths=` — that's a Phase 4 problem and a polkit/sudoers rule is the right answer, not "loosen the sandbox."

**Primary recommendation in one line:** Ship Phase 3 as a single PR introducing `scripts/provision/`, `units/`, and a Docker-based test harness; validate side-by-side on `arlowe-staging` user on arlowe-1 before claiming Phase 3 done; Phase 6 then consumes these artifacts unchanged.

---

## 2. Provisioning testbed decision

### Decision: Docker (debian:bookworm-slim + systemd-as-PID-1) primary; arlowe-1 staging-user secondary.

**Rationale:**

| Option | Cost | Fidelity | Verdict |
|---|---|---|---|
| (a) Docker + systemd PID 1 | ~5 min container start; runs on Mac + arlowe-1 | Full systemd. Real `useradd`, real `systemctl`, real `systemd-analyze security`. **No SPI/GPIO/ALSA** — those are kernel devices the container can't fake without `--device` passthrough that would tie the test to a real Pi. | **Primary.** Validates everything except hardware-bound device-access. |
| (b) QEMU aarch64 + Pi OS | 20-40% native perf; image setup tax; no Pi-5-specific QEMU machine | Better than Docker for kernel-y things, but we don't need kernel realism for Phase 3 (no kernel-module work, no boot-loader work). Adds tooling burden for marginal gain. | Rejected. |
| (c) Clean dev Pi (not arlowe-1) | Hardware cost (need a second Pi); or repurpose arlowe-1 (disrupts dev) | Highest fidelity. But this is Phase 6's job. | Defer to Phase 6. |
| (d) arlowe-1 with a side-by-side `arlowe-staging` user | Zero hardware cost; pollutes arlowe-1 user table mildly | Tests the **real** SPI/GPIO/ALSA permissions story against the actual hardware. The `focal55` daily-driver setup is untouched because `arlowe-staging` units are loaded by name and only when explicitly enabled. | **Secondary, gated on Joe running the script.** |
| (e) Defer all to Phase 6 | Zero now, all-or-nothing later | Highest risk: Phase 6 is large and lots of things could break; you want Phase 3 already-green so Phase 6 can focus on image plumbing. | Rejected. |

**The arlowe-1 sub-target is opt-in.** The Phase 3 verification script can run "fully" in Docker (passes everything except hardware-loop SC4) and "extended" on arlowe-1 (passes SC4 against real SPI/GPIO/ALSA). Phase 12 owns the factory-fresh first-flash gate; Phase 3 doesn't need to claim that ground.

**Fallback if Docker-systemd is locally a pain:** systemd-nspawn from a Debian bookworm rootfs tarball. It runs as PID 1 cleanly without Docker's `--privileged` weirdness. But the workforce already uses Docker; pick Docker for the cognitive-load reasons unless it actually fails.

**What the testbed validates:**

| SC | Docker test | arlowe-1 staging test |
|---|---|---|
| SC1: `id arlowe` correct, no founder | YES — fresh container has no `focal55`, `id arlowe-staging` returns expected uid/home/shell | YES (against `arlowe-staging`, not `arlowe`, to avoid disturbing the live focal55-running `arlowe-*.service` units) |
| SC2: `/opt/arlowe/` + `/var/lib/arlowe/` ownership and modes | YES — install script runs end-to-end, `ls -la` assertions pass | YES |
| SC3: every unit system-level, runs as arlowe, applies sandbox directives | YES — `systemd-analyze security` per unit, unit-file lint, dry-run start (units may fail at runtime due to missing devices, but the syntax + sandbox-directives check independently of that) | YES — units actually start, services bind their ports, hardware reachable |
| SC4: cannot write outside `/var/lib/arlowe/` | YES, synthetic — `systemd-run --uid=arlowe ... touch /opt/arlowe/runtime/test.txt` returns EROFS or EACCES | YES, real-hardware-backed |

---

## 3. User / group provisioning recipe

### Idempotent install script (`scripts/provision/install-arlowe-user.sh`)

```bash
#!/bin/bash
# Provisions the `arlowe` system user on Debian/Pi OS.
# Idempotent: safe to re-run; exits 0 if user already exists with correct shape.
# Runs as root (or via sudo) — invoked by pi-gen stage in Phase 6 and by the
# Phase 3 Docker testbed.
set -euo pipefail

ARLOWE_HOME=/var/lib/arlowe
ARLOWE_SHELL=/usr/sbin/nologin

# Create the system user and matching group atomically.
if ! id -u arlowe >/dev/null 2>&1; then
    useradd \
        --system \
        --user-group \
        --create-home \
        --home-dir "$ARLOWE_HOME" \
        --shell "$ARLOWE_SHELL" \
        --comment "Arlowe runtime service account" \
        arlowe
fi

# Idempotent supplementary group assignment. Each group is required by at
# least one shipping service. (See `Group justification` below.)
for grp in audio gpio spi dialout video; do
    if getent group "$grp" >/dev/null 2>&1; then
        usermod -aG "$grp" arlowe
    fi
done

# Enforce HOME perms — useradd --create-home creates 0755 by default on Debian;
# we want 0750 (group readable, world denied) so /var/lib/arlowe contents
# default to "arlowe-only" with explicit group exposure where needed.
chmod 0750 "$ARLOWE_HOME"
chown arlowe:arlowe "$ARLOWE_HOME"
```

### Group justification

| Group | Required by | Why |
|---|---|---|
| `audio` | `arlowe-voice.service`, `arlowe-wake-word.service` | ALSA `/dev/snd/*` access for pyaudio capture + playback. The pi-gen `audio` group is the standard Debian audio group. |
| `gpio` | `arlowe-face.service` | Pi udev rules in `/etc/udev/rules.d/99-com.rules` chown `/dev/gpiomem` and `/dev/gpiochip*` to group `gpio` 0660. WhisPlay driver uses GPIO for SPI chip-select and backlight. |
| `spi` | `arlowe-face.service` | Pi udev rules chown `/dev/spidev*` to group `spi` 0660. WhisPlay LCD is an SPI device. |
| `dialout` | Possibly `arlowe-voice.service` (TTS playback via WhisPlay's onboard speaker over UART/I2C codec; verify on hardware) | Some Pi audio HAT codecs are managed via UART/I2C control planes that land in `dialout`. Cheap to grant; expensive to discover missing during pairing. |
| `video` | `arlowe-face.service` | `/dev/fb0` framebuffer access on Pi OS Lite (the WhisPlay driver may use the framebuffer in some modes — confirm during Phase 3 implementation; remove if not needed). |

**`netdev` is intentionally omitted** — NetworkManager is the canonical interface, and the dashboard mediates Wi-Fi configuration via `nmcli`. If the dashboard ever needs to invoke `nmcli` from inside `arlowe`'s context, polkit (`org.freedesktop.NetworkManager.network-control`) is the right path, not group membership.

**Do not use `DynamicUser=yes`.** USER-03 demands persistent state ownership across reboots: conversation cache, identity files, logs all need a stable UID. `DynamicUser=` would relocate paths under `/var/lib/private/` and break Phase 4 (config overlay), Phase 7 (PKI persistence), and Phase 11 (log retention).

**UID range:** Debian's `useradd --system` allocates from `SYS_UID_MIN..SYS_UID_MAX` (typically 100–999). Don't pin a specific UID; let the system choose. File ownership is by name; nothing in the repo references a UID.

### Verification assertions

```bash
# SC1 assertions
id arlowe                                        # expect uid in 100..999
getent passwd arlowe | cut -d: -f6              # expect /var/lib/arlowe
getent passwd arlowe | cut -d: -f7              # expect /usr/sbin/nologin
getent passwd focal55 || true                    # expect "no such user"
id -nG arlowe | tr ' ' '\n' | sort -u           # expect: arlowe audio dialout gpio spi video
```

---

## 4. Filesystem layout reference

### Tree

```
/opt/arlowe/                                 root:arlowe  0750  Read-only at runtime; OTA-mutable at update.
├── runtime/                                 root:arlowe  0755
│   ├── voice/                               root:arlowe  0755
│   ├── face/                                root:arlowe  0755
│   ├── stt/                                 root:arlowe  0755
│   ├── tts/
│   │   └── bin/piper                        root:arlowe  0755  TTS binary
│   ├── llm/
│   │   ├── router.py
│   │   ├── run_api.sh                       root:arlowe  0755
│   │   ├── qwen2.5_tokenizer_uid.py
│   │   └── bin/
│   │       └── main_api_axcl_aarch64        root:arlowe  0755  ax-llm binary
│   ├── dashboard/
│   │   └── .next/standalone/                root:arlowe  0755  Next.js standalone bundle
│   ├── wake-word/                           root:arlowe  0755
│   └── cli/                                 root:arlowe  0755
├── third_party/
│   ├── ax-llm/                              root:arlowe  0755  Submodule baked at build
│   ├── whisplay-driver/                     root:arlowe  0755  Vendored at Phase 6
│   └── axcl/                                root:arlowe  0755  axcl_host_aarch64 deb expanded
├── models/                                  root:arlowe  0755  Populated by Phase 6
│   ├── qwen2.5-7b-int4-ax650/
│   ├── piper-voices/
│   └── wake-word/heyarlowe-generic.onnx
├── venvs/                                   root:arlowe  0755  Read-only Python venvs
│   ├── voice/                               root:arlowe  0755  voice + wake-word + face deps
│   ├── stt/                                 root:arlowe  0755  faster-whisper
│   ├── tts/                                 root:arlowe  0755  piper helpers (if any)
│   └── llm/                                 root:arlowe  0755  tokenizer service deps
└── config/
    └── defaults.yml                         root:arlowe  0644  Phase 4 owns content

/etc/arlowe/                                 root:arlowe  0755  Reserved by Phase 3; Phase 4 owns content
└── (config.yml absent in factory image — its absence is the "not yet paired" signal per CONFIG-03)

/var/lib/arlowe/                             arlowe:arlowe  0750  Owner state; mount point of owner-state partition (Phase 6)
├── logs/                                    arlowe:arlowe  0750  Per-service appenders; LogsDirectory creates subdirs
│   ├── voice/voice_YYYY-MM-DD.log
│   ├── face/face.log
│   ├── stt/stt.log
│   ├── llm/router-usage.log
│   ├── dashboard/dashboard.log
│   ├── ota.log                              (Phase 9 populates)
│   └── support.log                          (Phase 10 populates)
├── conversations/                           arlowe:arlowe  0700  Conversation cache; sensitive
├── identity/                                arlowe:arlowe  0700  PKI cert/key (Phase 7); empty in Phase 3 image
├── state/                                   arlowe:arlowe  0750  Service state (usage-stats.json, whisplay-config.json)
├── wake-word/                               arlowe:arlowe  0750  Owner training samples + verifier.pkl (Phase 8 personalization)
├── dashboard/
│   └── cache/                               arlowe:arlowe  0750  NEXT_PRIVATE_CACHE_DIR target
└── logrotate.status                         arlowe:arlowe  0640  logrotate state
```

### Path × owner × mode × purpose table

| Path | Owner | Mode | Writable by arlowe? | Purpose | Phase that populates |
|---|---|---|---|---|---|
| `/opt/arlowe/` | root:arlowe | 0750 | NO | Code root | Phase 6 image build; Phase 9 OTA |
| `/opt/arlowe/runtime/` | root:arlowe | 0755 | NO | Component runtimes | Phase 6 / OTA |
| `/opt/arlowe/third_party/` | root:arlowe | 0755 | NO | Vendored deps | Phase 6 |
| `/opt/arlowe/models/` | root:arlowe | 0755 | NO | LLM, TTS, wake-word models | Phase 6 |
| `/opt/arlowe/venvs/` | root:arlowe | 0755 | NO | Python venvs | Phase 6 |
| `/opt/arlowe/config/defaults.yml` | root:arlowe | 0644 | NO | Default config | Phase 4 |
| `/etc/arlowe/` | root:arlowe | 0755 | NO | Config overlay dir | Phase 3 (empty) |
| `/etc/arlowe/config.yml` | root:arlowe | 0640 | NO (privileged helper writes via Phase 4) | Owner overlay | Phase 8 pairing creates; Phase 4 schema-validates |
| `/var/lib/arlowe/` | arlowe:arlowe | 0750 | YES (root) | Owner state mount point | Phase 6 ext4 partition |
| `/var/lib/arlowe/logs/` | arlowe:arlowe | 0750 | YES | Per-service logs | Phase 3 reserve; Phase 11 retention defaults |
| `/var/lib/arlowe/logs/<service>/` | arlowe:arlowe | 0750 | YES | systemd `LogsDirectory=arlowe/<service>` auto-creates | runtime |
| `/var/lib/arlowe/conversations/` | arlowe:arlowe | 0700 | YES | Conversation cache | runtime; Phase 10 support tooling reads via mediator |
| `/var/lib/arlowe/identity/` | arlowe:arlowe | 0700 | YES (writes one-shot at pairing) | Device cert + key | Phase 7 |
| `/var/lib/arlowe/state/` | arlowe:arlowe | 0750 | YES | Service state files | runtime |
| `/var/lib/arlowe/wake-word/` | arlowe:arlowe | 0750 | YES | Owner training data (NEVER committed) | Phase 8 |
| `/var/lib/arlowe/dashboard/cache/` | arlowe:arlowe | 0750 | YES | Next.js runtime cache | runtime |

**`/var/lib/arlowe/` is a separate ext4 partition** in Phase 6 (PART-04). Phase 3's install script must create the directory structure inside the partition mount-point, not assume the partition exists — when Phase 3 is tested in Docker, `/var/lib/arlowe` is just a directory; when Phase 6 provisions it, it's a mount-point. The install script's behavior is identical either way.

**Why `0750` on `/var/lib/arlowe` and not `0755`:** keeps random unprivileged users (none ship in v1, but defense-in-depth) from reading conversation cache or log paths. Support-mode (Phase 10) is the *founder* SSH key, which has its own scoping via `ForceCommand`; it doesn't traverse `/var/lib/arlowe` directly.

**Why `0750` on `/opt/arlowe`:** USER-02 says "readable by the arlowe group." 0755 would make code world-readable; 0750 makes it `arlowe`-group-readable and root-traversable, which is exactly USER-02.

---

## 5. Python venv strategy

### Decision: pattern (a) — venvs baked into `/opt/arlowe/venvs/`, root-owned, read-only at runtime.

**One venv per Python service.** Voice + face + wake-word can share `venvs/voice/` because their deps overlap heavily (numpy, scipy, requests, onnxruntime). STT gets its own (`faster-whisper` is heavy). TTS likely doesn't need one — `piper` is a native binary — but reserve `venvs/tts/` for any future Python helpers. LLM tokenizer needs one (`transformers`, `huggingface_hub` are large).

**Why baked, not first-boot-populated:**

- First-boot population would require ~5–10 minutes of `pip install` on Pi 5 (numpy + onnxruntime + scikit-learn are slow).
- First boot is the pairing experience; making it network-dependent on `pip install` from PyPI is a UX cliff and a security risk.
- Image reproducibility (IMAGE-03) requires the venv to be deterministic; baked at build time with pinned `requirements.txt` is the only way.
- Disk cost: ~500 MB combined across all venvs — well within the 16 GB SD budget (PART-05).

**OTA implications (Phase 9):**

App-only OTA updates `runtime/` and may need to update `venvs/` if deps change. The OTA agent's options:

1. **OTA agent runs as `root`** (separate from `arlowe`) with a tight sandbox: `ProtectSystem=strict`, `ReadWritePaths=/opt/arlowe`, `RestrictAddressFamilies=AF_INET AF_INET6`. This is the right answer.
2. ~~OTA runs as `arlowe` with polkit/sudoers granting write to `/opt/arlowe`~~. Polkit can do this but it's more complex and harder to audit. Reject.

Phase 9 reads "OTA agent runs as a systemd service under the `arlowe` user" (OTA-01) — **this requirement may need to be revisited**. Flag as an open question for the planner: do we run OTA as root with a narrow sandbox, or amend OTA-01? Strong recommendation: **amend OTA-01 to `OTA agent runs as a system-level systemd service with strictly sandboxed root, writes to /opt/arlowe only, with rsync-then-atomic-swap`.** The OTA agent is the *one* place where root + write-/opt is justified.

### Install pattern in pi-gen stage (Phase 6 reference)

```bash
# Phase 6 will do roughly:
install -d -o root -g arlowe -m 0755 /opt/arlowe/venvs
for svc in voice stt tts llm; do
    python3 -m venv /opt/arlowe/venvs/$svc
    /opt/arlowe/venvs/$svc/bin/pip install --no-cache-dir -r /opt/arlowe/runtime/$svc/requirements.txt
    chown -R root:arlowe /opt/arlowe/venvs/$svc
    chmod -R u=rwX,g=rX,o= /opt/arlowe/venvs/$svc
done
```

Phase 3's responsibility is to write `docs/operations/venv-build.md` documenting this; Phase 6 executes it.

---

## 6. Dashboard (Next.js) strategy

### Decision: `next build` with `output: 'standalone'`; relocate cache via `NEXT_PRIVATE_CACHE_DIR`.

**Required changes:**

1. `runtime/dashboard/next.config.ts`:

```typescript
import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  output: 'standalone',
  // Disable telemetry; we are an offline-first appliance.
  // (Setting via env: NEXT_TELEMETRY_DISABLED=1 in the unit file.)
};

export default nextConfig;
```

2. Build at image-build time (Phase 6):

```bash
cd /tmp/build/dashboard
pnpm install --frozen-lockfile
pnpm build
# .next/standalone/ contains server.js + minimal node_modules
# .next/static/ + public/ must be copied separately
mkdir -p /opt/arlowe/runtime/dashboard
cp -r .next/standalone/* /opt/arlowe/runtime/dashboard/
cp -r .next/static /opt/arlowe/runtime/dashboard/.next/static
cp -r public /opt/arlowe/runtime/dashboard/public
chown -R root:arlowe /opt/arlowe/runtime/dashboard
```

3. systemd unit launches `node /opt/arlowe/runtime/dashboard/server.js`. No `pnpm`, no `npm`, no `next start`. `node` is installed system-wide via apt during Phase 6 (apt installs `nodejs` — Pi OS Bookworm has Node 20).

4. Runtime cache redirect via env:

```
Environment=NEXT_PRIVATE_CACHE_DIR=/var/lib/arlowe/dashboard/cache
Environment=NEXT_TELEMETRY_DISABLED=1
Environment=NODE_ENV=production
Environment=PORT=3000
Environment=HOSTNAME=0.0.0.0
```

**Note on `NEXT_PRIVATE_CACHE_DIR`:** This env var is documented in Next.js community discussions and is the standard read-only-rootfs workaround. It is marked "private" (unstable) in Next.js naming convention but is the only documented mechanism. If Next.js renames it in a future version, the layout still works because the cache is just non-essential.

**Image-size impact:** standalone bundle for this dashboard (Next 16, React 19) is ~50 MB (Next.js standalone + minimal node_modules). Well within budget.

**Alternative considered and rejected:** running `pnpm start` from `/opt/arlowe`. Requires `pnpm` on the device, the full `node_modules/` tree (~200 MB+), and a writable `.next/cache`. Standalone wins on every axis.

---

## 7. systemd unit conversion matrix

### Hardening baseline (applied to every shipping unit)

```ini
[Service]
User=arlowe
Group=arlowe
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ProtectKernelLogs=yes
ProtectClock=yes
ProtectHostname=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
LockPersonality=yes
RestrictNamespaces=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
# Per-unit additions: ReadWritePaths, SupplementaryGroups, DeviceAllow, etc.
# Per-unit StateDirectory / LogsDirectory creates and chowns subdirs of
# /var/lib/arlowe and /var/log/arlowe automatically (NB: LogsDirectory creates
# under /var/log/private/<name> with strict perms when DynamicUser=yes, but
# under /var/log/<name> with normal perms when we use User=arlowe — verify
# this in the Docker testbed before committing the unit files).
```

**Note on `LogsDirectory` interaction with the partition layout:** systemd's `LogsDirectory=arlowe/voice` creates `/var/log/arlowe/voice` — NOT `/var/lib/arlowe/logs/voice`. The runtime expects logs under `/var/lib/arlowe/logs/` (per Phase 1 contracts: `ARLOWE_LOGS_DIR=/var/lib/arlowe/logs`). Two viable resolutions:

1. **Don't use `LogsDirectory=`.** Instead use `ReadWritePaths=/var/lib/arlowe/logs` and let the apps create their own subdirs. Loses some systemd automation but keeps the layout simple.
2. Use `LogsDirectory=arlowe/voice` and symlink `/var/lib/arlowe/logs/voice -> /var/log/arlowe/voice`. Adds a symlink and a layer of indirection.

**Recommendation: option 1** — explicit `ReadWritePaths=/var/lib/arlowe/logs/<service>` for each unit, with the per-service log directory created by the install script at provision time. Simpler and matches what Phase 1's runtime already expects.

### Unit 1: `arlowe-face.service`

```ini
[Unit]
Description=Arlowe face display service
Documentation=man:arlowe-face(8)
After=network.target sound.target
Wants=network-online.target

[Service]
Type=simple
User=arlowe
Group=arlowe
SupplementaryGroups=gpio spi video
WorkingDirectory=/opt/arlowe/runtime
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONPATH=/opt/arlowe/runtime
Environment=ARLOWE_WHISPLAY_DRIVER_PATH=/opt/arlowe/third_party/whisplay-driver
Environment=ARLOWE_STATE_DIR=/var/lib/arlowe/state
Environment=ARLOWE_LOGS_DIR=/var/lib/arlowe/logs
ExecStart=/opt/arlowe/venvs/voice/bin/python -m face.face_service
Restart=on-failure
RestartSec=5

# Hardening baseline
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ProtectKernelLogs=yes
ProtectClock=yes
ProtectHostname=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
LockPersonality=yes
RestrictNamespaces=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

# Per-unit: SPI + GPIO + framebuffer access; writable state + logs
PrivateDevices=no
DeviceAllow=/dev/spidev0.0 rw
DeviceAllow=/dev/spidev0.1 rw
DeviceAllow=/dev/gpiomem rw
DeviceAllow=/dev/gpiochip0 rw
DeviceAllow=/dev/gpiochip4 rw
DeviceAllow=/dev/fb0 rw
ReadWritePaths=/var/lib/arlowe/state /var/lib/arlowe/logs/face

# Network: binds tcp/8080 (FIXME(F1): hardcoded; flag for Phase 4 config-driven)
# AmbientCapabilities not needed: 8080 > 1024

[Install]
WantedBy=multi-user.target
```

**Notes on `arlowe-face.service`:**
- TCP 8080 is hardcoded in `face_service.py` (todo F1). Phase 3 does NOT fix this; Phase 4 (config overlay) or Phase 5 owns. Flag in pitfall list.
- Pi 5 has `/dev/gpiochip0` (main bank) and `/dev/gpiochip4` (RP1 chip). Both need to be allowed for the WhisPlay driver, which uses GPIO for SPI chip-select and backlight PWM.
- `DeviceAllow` requires `PrivateDevices=no`. If `PrivateDevices=yes`, all `DeviceAllow=` entries are ignored.

### Unit 2: `arlowe-voice.service`

```ini
[Unit]
Description=Arlowe voice orchestrator (wake -> STT -> LLM -> TTS -> face)
After=arlowe-face.service whisper-stt.service qwen-api.service network.target sound.target
Wants=arlowe-face.service whisper-stt.service qwen-api.service
Requires=arlowe-face.service

[Service]
Type=simple
User=arlowe
Group=arlowe
SupplementaryGroups=audio dialout
WorkingDirectory=/opt/arlowe/runtime
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONPATH=/opt/arlowe/runtime
Environment=ARLOWE_PIPER_PATH=/opt/arlowe/runtime/tts/bin/piper
Environment=ARLOWE_PIPER_MODEL=/opt/arlowe/models/piper-voices/en_US-lessac-medium.onnx
Environment=ARLOWE_VERIFIER_MODEL=/var/lib/arlowe/wake-word/verifier.pkl
Environment=ARLOWE_FACE_URL=http://localhost:8080
Environment=ARLOWE_STT_URL=http://localhost:8082/transcribe
Environment=ARLOWE_LOGS_DIR=/var/lib/arlowe/logs
Environment=ARLOWE_STATE_DIR=/var/lib/arlowe/state
ExecStart=/opt/arlowe/venvs/voice/bin/python -m voice.voice_client
Restart=on-failure
RestartSec=10

# Hardening baseline (same as face) plus:
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ProtectKernelLogs=yes
LockPersonality=yes
RestrictNamespaces=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged
# voice needs realtime for audio (~lower)
RestrictRealtime=no
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK

# Audio device access
PrivateDevices=no
DeviceAllow=/dev/snd/* rw
DeviceAllow=/dev/snd/seq rw
DeviceAllow=/dev/snd/timer r

# Writable paths
ReadWritePaths=/var/lib/arlowe/state /var/lib/arlowe/logs /var/lib/arlowe/conversations

[Install]
WantedBy=multi-user.target
```

**Notes on `arlowe-voice.service`:**
- `RestrictRealtime=no` because pyaudio uses `SCHED_FIFO`-adjacent paths for low-latency capture. If this turns out unneeded, tighten in a follow-up.
- `AF_NETLINK` included for ALSA's device-enumeration via the kernel. Test in the testbed — if the service starts and audio works without it, drop.
- `RestrictSUIDSGID` intentionally omitted because the voice code currently shells out to `sudo tee` for fan control (noted in `runtime/voice/README.md` as a phase-4 cleanup). Phase 3 should NOT yet remove the sudo path — that's a Phase 4 task. Phase 3 should flag it.
- After= ordering pulls up face + stt + qwen-api in the proven order. Wants= is soft, Requires=face is harder (voice with no face is useless).

### Unit 3: `arlowe-dashboard.service`

```ini
[Unit]
Description=Arlowe local dashboard (Next.js standalone)
After=network.target

[Service]
Type=simple
User=arlowe
Group=arlowe
WorkingDirectory=/opt/arlowe/runtime/dashboard
Environment=NODE_ENV=production
Environment=PORT=3000
Environment=HOSTNAME=0.0.0.0
Environment=NEXT_TELEMETRY_DISABLED=1
Environment=NEXT_PRIVATE_CACHE_DIR=/var/lib/arlowe/dashboard/cache
Environment=ARLOWE_CONFIG_PATH=/etc/arlowe/config.yml
Environment=ARLOWE_LOGS_DIR=/var/lib/arlowe/logs
Environment=ARLOWE_SYSTEMCTL_MODE=system
ExecStart=/usr/bin/node /opt/arlowe/runtime/dashboard/server.js
Restart=on-failure
RestartSec=5

# Hardening baseline
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ProtectKernelLogs=yes
ProtectClock=yes
ProtectHostname=yes
LockPersonality=yes
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
PrivateDevices=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

# Dashboard writes cache, logs. NOT /etc/arlowe/config.yml directly — Phase 4
# wires a privileged-helper write path via polkit or a setuid helper.
ReadWritePaths=/var/lib/arlowe/dashboard /var/lib/arlowe/logs/dashboard

[Install]
WantedBy=multi-user.target
```

**Notes on `arlowe-dashboard.service`:**
- `PrivateDevices=yes` is safe — dashboard touches no hardware.
- `/etc/arlowe/config.yml` is intentionally NOT in `ReadWritePaths`. The dashboard's `POST /api/config` will fail until Phase 4 implements the privileged-helper write path. Phase 3 leaves a clear FIXME in the unit comments.
- `ARLOWE_SYSTEMCTL_MODE=system` flips the dashboard from `--user` to system-level systemctl queries. Phase 1 dashboard already supports both via env.

### Unit 4: `qwen-tokenizer.service`

```ini
[Unit]
Description=Qwen tokenizer HTTP service
After=network.target

[Service]
Type=simple
User=arlowe
Group=arlowe
WorkingDirectory=/opt/arlowe/runtime/llm
Environment=PYTHONUNBUFFERED=1
ExecStart=/opt/arlowe/venvs/llm/bin/python /opt/arlowe/runtime/llm/qwen2.5_tokenizer_uid.py
Restart=on-failure
RestartSec=5

# Baseline hardening
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ProtectKernelLogs=yes
LockPersonality=yes
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

ReadWritePaths=/var/lib/arlowe/logs/llm

[Install]
WantedBy=multi-user.target
```

### Unit 5: `qwen-api.service`

```ini
[Unit]
Description=Qwen LLM API server (ax-llm native)
After=qwen-tokenizer.service network.target
Requires=qwen-tokenizer.service

[Service]
Type=simple
User=arlowe
Group=arlowe
WorkingDirectory=/opt/arlowe/runtime/llm
Environment=AX_LLM_BIN=/opt/arlowe/runtime/llm/bin/main_api_axcl_aarch64
Environment=QWEN_MODEL_DIR=/opt/arlowe/models/qwen2.5-7b-int4-ax650
ExecStart=/opt/arlowe/runtime/llm/run_api.sh
Restart=on-failure
RestartSec=10

# Baseline hardening. ax-llm binary needs /dev/axcl_host + /dev/ax_mmb_dev
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=no
DeviceAllow=/dev/axcl_host rw
DeviceAllow=/dev/ax_mmb_dev rw
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
LockPersonality=yes
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

ReadWritePaths=/var/lib/arlowe/logs/llm

[Install]
WantedBy=multi-user.target
```

**Notes on `qwen-api.service`:**
- `/dev/axcl_host` and `/dev/ax_mmb_dev` are the Axera AX8850 device nodes. Confirm exact device names and perms on arlowe-1 during Phase 3 implementation — these may need a separate udev rule to chown to `arlowe` group, since Axera's `axcl_host.deb` may default to `root:root` ownership.
- `ProtectKernelModules` deliberately omitted from this unit — ax-llm may need to load kernel modules at startup. Test and tighten.
- `ProtectKernelLogs` and `ProtectClock` deliberately omitted from this unit too — pending hardware-loop verification.

### Unit 6: `whisper-stt.service`

```ini
[Unit]
Description=Whisper STT server (faster-whisper)
After=network.target

[Service]
Type=simple
User=arlowe
Group=arlowe
WorkingDirectory=/opt/arlowe/runtime/stt
Environment=PYTHONUNBUFFERED=1
ExecStart=/opt/arlowe/venvs/stt/bin/python /opt/arlowe/runtime/stt/stt_server.py
Restart=on-failure
RestartSec=5

# Full baseline hardening
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ProtectKernelLogs=yes
ProtectClock=yes
ProtectHostname=yes
LockPersonality=yes
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

ReadWritePaths=/var/lib/arlowe/logs/stt

[Install]
WantedBy=multi-user.target
```

### Unit 7: `arlowe-wake-word.service` (NEW; split out from voice)

**This is an architectural decision, not a Phase 1 inheritance.** Today wake-word detection runs inside `voice_client.py`. Splitting it into its own unit is **optional for Phase 3**; the strong argument FOR splitting is that wake-word always-on listening should be the only audio-capture-holding process when voice is idle, releasing the audio device for other purposes. The strong argument AGAINST is that it adds complexity and an IPC dance with voice_client.

**Recommendation for Phase 3: do NOT split.** Keep wake-word in voice_client.py for now. The split is a Phase 5 or later optimization. So the Phase 3 unit set is **six units**, not seven. Remove from the count.

### Reserved unit names (Phase 3 documents; later phases author)

- `arlowe-pairing.service` — Phase 8
- `arlowe-ota.service` — Phase 9
- `arlowe-support.service` — Phase 10
- `arlowe-boot-check.service` (oneshot) — Phase 11

### Unit-name sanitization check

All seven proposed unit names pass `scripts/sanitize/check.sh --units-only`:

| Unit | Prefix banned? |
|---|---|
| `arlowe-face.service` | No (banlist is `openclaw-*`, `trace-*`, `workforce-metrics-snapshot.*`) |
| `arlowe-voice.service` | No |
| `arlowe-dashboard.service` | No |
| `qwen-tokenizer.service` | No |
| `qwen-api.service` | No |
| `whisper-stt.service` | No |

All clear.

---

## 8. CLI helper install pattern

### Decision: root-owned symlinks in `/usr/local/sbin/` pointing into `/opt/arlowe/runtime/cli/`, prefixed with `arlowe-`.

```bash
# Phase 3 install script does:
for cli in face speak stt record boot-check purge-logs run-logrotate wake-train; do
    ln -sf /opt/arlowe/runtime/cli/$cli /usr/local/sbin/arlowe-$cli
done
```

**Why `/usr/local/sbin` not `/usr/local/bin`:** these are administrative tools, not user tools. `nologin` users can't run them anyway; they're invoked by support-mode SSH (Phase 10) or by `sudo -u arlowe`.

**Why prefix with `arlowe-`:** the wake-train command currently is `wake-train`. If you symlink it into `/usr/local/sbin/wake-train`, you've polluted the PATH namespace for any other tool. `arlowe-wake-train` is clear about scope.

**Invocation pattern (for documentation):**

```bash
# Support-mode SSH session as the founder:
sudo -u arlowe -- /usr/local/sbin/arlowe-boot-check

# Or via systemd-run:
sudo systemd-run --uid=arlowe --gid=arlowe --working-directory=/opt/arlowe/runtime \
    /usr/local/sbin/arlowe-boot-check
```

**CLI scripts that write to `/var/lib/arlowe/`:**

| Script | Writes to | Implication |
|---|---|---|
| `purge-logs` | `/var/lib/arlowe/logs/` (deletes files) | Must run as `arlowe` (which can delete its own logs). |
| `run-logrotate` | `/var/lib/arlowe/logrotate.status` | Must run as `arlowe`; logrotate state file is owned by arlowe. |
| `wake-train` | `/var/lib/arlowe/wake-word/` (training data + verifier.pkl output) | Must run as `arlowe`; reads `/opt/arlowe/runtime/wake-word/` (RO) and writes `/var/lib/arlowe/wake-word/`. |
| `boot-check` | nothing (read-only diagnostics) | Can run as anyone with `arlowe`-group read; conventionally invoked as arlowe. |

**Boot-check `ARLOWE_SYSTEMCTL_FLAGS` flip (existing TODO in code):** Phase 3 flips the default from `--user` to `""` (empty) in `runtime/cli/boot-check` line 10, since after Phase 3 the services run system-level. This is a one-line code change that ships with the Phase 3 PR.

---

## 9. Cross-phase compatibility check

| Future phase | What it needs | Phase 3 provides? | Notes |
|---|---|---|---|
| **Phase 4 (Config overlay)** | `/etc/arlowe/config.yml` overlay path readable by all services; defaults at `/opt/arlowe/config/defaults.yml`; atomic-write path for dashboard | YES (paths reserved, dir created); NO write path yet (Phase 4 wires polkit/setuid helper) | Phase 3 leaves a clear FIXME in `arlowe-dashboard.service` about the `/etc/arlowe/config.yml` write path. |
| **Phase 5 (Audio auto-detect)** | `arlowe-voice.service` can read `/dev/snd/*` and enumerate devices; dashboard can read `/proc/asound/cards` | YES — voice has DeviceAllow=/dev/snd/* and SupplementaryGroups=audio | Phase 5 adds the auto-detect logic in voice_client.py. |
| **Phase 6 (Image build)** | A pi-gen stage script that installs the user, layout, and units in one pass | YES — `scripts/provision/install-arlowe-user.sh`, `scripts/provision/install-arlowe-fs.sh`, `units/install-units.sh` are the three scripts that pi-gen runs in stage 4 (Arlowe overlay). | Phase 6 also handles the `/var/lib/arlowe` separate-partition mount, not Phase 3. |
| **Phase 7 (PKI)** | `/var/lib/arlowe/identity/` exists, mode 0700, owned by arlowe; pairing daemon can write cert + key there | YES (dir created, perms set); Phase 7 unit adds itself to `ReadWritePaths=/var/lib/arlowe/identity` | The Phase 8 pairing daemon (which initiates the cert request) needs write access; the runtime services need read access. Both work because the dir is `arlowe:arlowe 0700` and all services run as arlowe. |
| **Phase 8 (Pairing)** | Pairing daemon unit can write `/etc/arlowe/config.yml`; can write `/var/lib/arlowe/identity/`; can trigger restart of arlowe-voice etc. | NO write to `/etc/arlowe/`; YES write to `/var/lib/arlowe/identity/` | Phase 8 pairing daemon needs the same privileged-helper pattern as dashboard for `/etc/arlowe/config.yml`. Phase 4 owns the helper; Phase 8 consumes it. Service-restart capability needs `Type=dbus` + a polkit rule, OR pairing daemon runs as root with tight sandbox. Strong recommendation: run pairing daemon as root (one-shot at first boot) with `ReadWritePaths=/etc/arlowe /var/lib/arlowe/identity` and `Restart=no`. |
| **Phase 9 (OTA)** | OTA agent can write `/opt/arlowe/runtime/`; can restart services | NO write path for arlowe to /opt; root+sandbox pattern (see §5) | OTA-01 says "arlowe user" — this needs amendment. See Open Questions §12. |
| **Phase 10 (Support mode)** | sshd can write `/var/lib/arlowe/logs/support.log`; founder SSH key path | sshd runs as `root`; can write anywhere when explicitly told. Phase 3 reserves the path; Phase 10 wires sshd's `ChrootDirectory` or `ForceCommand` to log to that path. | The `arlowe` user's `~/.ssh/authorized_keys` lives at `/var/lib/arlowe/.ssh/authorized_keys`. Phase 3 should NOT create this file — its absence is a Phase 10 baseline assertion. |
| **Phase 11 (Boot health, logs)** | Per-service log dirs writable by arlowe; boot-check works against system-level units | YES on both | boot-check's `ARLOWE_SYSTEMCTL_FLAGS=""` flip ships with Phase 3. |
| **Phase 12 (First-flash integration)** | All of the above on real hardware | YES, as artifacts; SC4 hardware-loop validates here per Phase 1's deferral pattern | Phase 12 is the gate. |

---

## 10. Pitfalls and gotchas

### Blocker-class

| Issue | What goes wrong | How to avoid |
|---|---|---|
| **`PrivateDevices=yes` blocks ALL `DeviceAllow=` entries** | Face and voice services start but can't see SPI or audio devices; failure looks like "WhisPlay driver not found" or "PaError: no such audio device" | Always pair `PrivateDevices=no` with `DeviceAllow=` for hardware-touching units. Test in Docker (can't actually open device, but unit-syntax validates), confirm on arlowe-1 staging. |
| **`ProtectSystem=strict` blocks `/etc/arlowe/config.yml` writes** | Dashboard `POST /api/config` returns EROFS; pairing daemon can't write config | Don't put `/etc/arlowe/config.yml` in `ReadWritePaths` — it's not the right pattern. Use a privileged helper (Phase 4 owns). Pairing daemon (Phase 8) runs as root one-shot. |
| **`/var/lib/arlowe/` is a mount point in Phase 6** | The install script in Phase 3 creates the dir; Phase 6's pi-gen later mounts a partition over it, and the perms get reset to the partition's defaults | The pi-gen stage must run `install-arlowe-fs.sh` AFTER the partition is mounted and BEFORE the units start. Document the order. |
| **`face_service.py` port 8080 hardcoded** | Phase 4 needs to change it; Phase 3 ships unit files assuming 8080; if Phase 4 changes the port, both code and unit need updates | Phase 3 explicitly leaves the port at 8080 and flags the F1 TODO. Phase 4 owns the fix and updates the unit file at that time. |
| **`run_api.sh` may depend on PATH for `axcl-smi`** | ax-llm binary may shell out to vendor tooling that lives in `/opt/arlowe/third_party/axcl/bin/` or similar; if PATH doesn't include it, qwen-api crashes at startup | Phase 3 unit sets `Environment=PATH=/opt/arlowe/third_party/axcl/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` explicitly. Verify against arlowe-1 install. |

### Friction-class

| Issue | What goes wrong | How to avoid |
|---|---|---|
| **`/dev/axcl_host` and `/dev/ax_mmb_dev` ownership** | Axera SDK installs may chown to root:root with 0600. `arlowe` user can't open them. | Phase 3 ships a udev rule (`/etc/udev/rules.d/90-arlowe-axcl.rules`) chowning Axera devices to `root:arlowe 0660`. Test on arlowe-1 staging. |
| **systemd `LogsDirectory=` vs `/var/lib/arlowe/logs` mismatch** | Confusing two different log layouts (systemd's `/var/log/arlowe/` vs our chosen `/var/lib/arlowe/logs/`) | Use `ReadWritePaths=/var/lib/arlowe/logs/<service>` and let the apps create their own subdirs. Don't use `LogsDirectory=`. Document this. |
| **Voice service `sudo tee` for fan control** | runtime/voice/voice_client.py shells out to `sudo tee /sys/class/hwmon/hwmon2/pwm1` for fan control. With `User=arlowe` + `NoNewPrivileges=yes`, `sudo` fails. | Phase 3 flag — leave the broken sudo path in place but document it as a Phase 4 cleanup (chgrp the hwmon PWM node at boot via udev, or remove fan control until Phase 4 owns it). The voice service still starts; only the fan-control codepath errors. |
| **`SystemCallFilter=~@privileged` may block Python's `subprocess`** | router.py runs `claude -p` as a subprocess (cloud LLM path) | `~@privileged` blocks privileged syscalls, not exec/fork. Test in Docker before shipping. If it does block, drop `~@privileged` from the voice unit and rely on the broader filter. |
| **Dashboard cache `NEXT_PRIVATE_CACHE_DIR` is unstable Next.js API** | Could break in future Next.js versions | Document; pin Next.js to 16.x in package.json (already pinned to 16.1.6); revisit on major upgrade. |

### Nit-class

| Issue | What goes wrong | How to avoid |
|---|---|---|
| **`dialout` group inclusion is speculative** | May not actually be needed by the WhisPlay driver | Test on arlowe-1; remove if not needed. |
| **`video` group inclusion is speculative** | `/dev/fb0` may not be touched by WhisPlay driver (SPI display, not framebuffer) | Test on arlowe-1; remove if not needed. |
| **Hardening directives' effect on `systemd-analyze security` score** | Score may vary between systemd 252 (Pi OS Bookworm) and 256 (Bookworm-backports) | Score is informational, not a CI gate. Set the threshold (≤ 4.0 for hardware units, ≤ 3.0 for others) and accept variance. |
| **`/usr/sbin/nologin` vs `/sbin/nologin`** | Path differs on some distros; both exist on Debian Bookworm | Use `/usr/sbin/nologin` (Debian Bookworm canonical path); falls back to existence check in the install script. |

---

## 11. Validation strategy

### Test harness layout

```
tests/phase-3/
├── docker/
│   ├── Dockerfile                         # debian:bookworm-slim with systemd
│   ├── docker-compose.yml                 # privileged mode for systemd
│   └── run-tests.sh                       # runs the assertions below
├── assertions/
│   ├── 01-user-shape.sh                   # SC1
│   ├── 02-fs-layout.sh                    # SC2
│   ├── 03-unit-syntax.sh                  # SC3 (systemd-analyze verify + security)
│   └── 04-sandbox-write-deny.sh           # SC4
└── README.md                              # how to run + interpret
```

### SC1: user shape

```bash
# Run as part of the Docker test after install-arlowe-user.sh executes.
test "$(id -u arlowe)" -lt 1000                                              || fail "arlowe is not a system user (uid >= 1000)"
test "$(getent passwd arlowe | cut -d: -f6)" = "/var/lib/arlowe"             || fail "HOME wrong"
test "$(getent passwd arlowe | cut -d: -f7)" = "/usr/sbin/nologin"           || fail "shell wrong"
getent passwd focal55 && fail "founder user present"                         || true
id -nG arlowe | grep -qw audio                                               || fail "missing audio group"
id -nG arlowe | grep -qw gpio                                                || fail "missing gpio group"
id -nG arlowe | grep -qw spi                                                 || fail "missing spi group"
```

### SC2: filesystem layout

```bash
# /opt/arlowe perms and ownership
stat -c '%U:%G %a' /opt/arlowe                       | grep -q '^root:arlowe 750$'        || fail
stat -c '%U:%G %a' /opt/arlowe/runtime               | grep -q '^root:arlowe 755$'        || fail
stat -c '%U:%G %a' /opt/arlowe/venvs                 | grep -q '^root:arlowe 755$'        || fail
stat -c '%U:%G %a' /opt/arlowe/config/defaults.yml   | grep -q '^root:arlowe 644$'        || fail  # populated by Phase 4; in Phase 3 just check the file exists with right perms even if empty

# /var/lib/arlowe perms and ownership
stat -c '%U:%G %a' /var/lib/arlowe                   | grep -q '^arlowe:arlowe 750$'      || fail
stat -c '%U:%G %a' /var/lib/arlowe/logs              | grep -q '^arlowe:arlowe 750$'      || fail
stat -c '%U:%G %a' /var/lib/arlowe/identity          | grep -q '^arlowe:arlowe 700$'      || fail
stat -c '%U:%G %a' /var/lib/arlowe/conversations     | grep -q '^arlowe:arlowe 700$'      || fail

# /etc/arlowe reserved
test -d /etc/arlowe                                                                       || fail
stat -c '%U:%G %a' /etc/arlowe                       | grep -q '^root:arlowe 755$'        || fail
test ! -f /etc/arlowe/config.yml                                                          || fail "config.yml should NOT exist in Phase 3 (its absence is the pairing trigger)"
```

### SC3: unit hardening

```bash
# Syntax + warnings check
for unit in arlowe-face arlowe-voice arlowe-dashboard qwen-tokenizer qwen-api whisper-stt; do
    systemd-analyze verify /etc/systemd/system/$unit.service  || fail "$unit verify failed"
done

# Security score check
declare -A MAX_SCORE
MAX_SCORE[arlowe-face]=4.0
MAX_SCORE[arlowe-voice]=4.0
MAX_SCORE[qwen-api]=4.5      # axcl device access loosens score
MAX_SCORE[arlowe-dashboard]=3.0
MAX_SCORE[qwen-tokenizer]=3.0
MAX_SCORE[whisper-stt]=3.0

for unit in "${!MAX_SCORE[@]}"; do
    score=$(systemd-analyze security $unit.service --no-pager | grep -oP 'Overall exposure level for .+: \K[0-9.]+')
    awk -v s="$score" -v m="${MAX_SCORE[$unit]}" 'BEGIN { exit !(s+0 <= m+0) }' || \
        fail "$unit score $score exceeds threshold ${MAX_SCORE[$unit]}"
done

# User=arlowe on every shipping unit
for unit in arlowe-face arlowe-voice arlowe-dashboard qwen-tokenizer qwen-api whisper-stt; do
    grep -q '^User=arlowe$' /etc/systemd/system/$unit.service || fail "$unit not running as arlowe"
done

# No --user units anywhere (USER-04)
test ! -d /home/arlowe/.config/systemd/user                                                          || fail
test ! -d /var/lib/arlowe/.config/systemd/user                                                       || fail
```

### SC4: sandbox write denial

```bash
# Positive test: arlowe can write to its declared writable paths
systemd-run --uid=arlowe --gid=arlowe --pty --wait -p ProtectSystem=strict -p ReadWritePaths=/var/lib/arlowe/logs/voice \
    /bin/sh -c 'touch /var/lib/arlowe/logs/voice/sandbox-positive-test && rm /var/lib/arlowe/logs/voice/sandbox-positive-test'

# Negative test: arlowe cannot write to /opt/arlowe under the same sandbox
! systemd-run --uid=arlowe --gid=arlowe --pty --wait -p ProtectSystem=strict -p ReadWritePaths=/var/lib/arlowe/logs/voice \
    /bin/sh -c 'touch /opt/arlowe/runtime/voice/sandbox-negative-test' 2>&1 \
    | grep -qE 'Read-only file system|Permission denied' \
    || fail "negative write test allowed write to /opt/arlowe"

# Negative test: arlowe cannot write outside /var/lib/arlowe/ at all
! systemd-run --uid=arlowe --gid=arlowe --pty --wait -p ProtectSystem=strict -p ReadWritePaths=/var/lib/arlowe/logs/voice \
    /bin/sh -c 'touch /etc/sandbox-test' 2>&1 \
    | grep -qE 'Read-only file system|Permission denied' \
    || fail
```

### Test runner

```bash
# tests/phase-3/docker/run-tests.sh
#!/bin/bash
set -euo pipefail

docker run --rm -it --privileged \
    --tmpfs /run --tmpfs /tmp \
    -v $(pwd)/..:/arlowe-firmware:ro \
    debian:bookworm-slim \
    /bin/bash -c '
        apt-get update && apt-get install -y systemd python3 python3-venv nodejs
        # Run install scripts
        bash /arlowe-firmware/scripts/provision/install-arlowe-user.sh
        bash /arlowe-firmware/scripts/provision/install-arlowe-fs.sh
        bash /arlowe-firmware/units/install-units.sh
        # Run assertions
        for a in /arlowe-firmware/tests/phase-3/assertions/*.sh; do
            bash "$a"
        done
    '
```

### Arlowe-1 staging-user side-by-side script

`scripts/provision/install-arlowe-on-arlowe1-staging.sh` — same as the production script but installs as user `arlowe-staging` (uid in 100..999 but distinct from `arlowe`), with units named `arlowe-staging-*.service`, layout under `/opt/arlowe-staging/` and `/var/lib/arlowe-staging/`. Lets Joe run the assertions against real hardware without touching the live `focal55`-owned `arlowe-*.service` units. Tear down with a paired `uninstall-arlowe-on-arlowe1-staging.sh`.

This is the "arlowe-1 doesn't pollute" answer to the context's question.

---

## 12. Open questions for the planner

These could not be resolved by research alone and need either a checkpoint with Joe or explicit deferral.

1. **OTA-01 amendment.** OTA-01 says "OTA agent runs as a systemd service under the `arlowe` user." This conflicts with the read-only `/opt/arlowe/` decision in Phase 3. **Recommendation: amend OTA-01 to "OTA agent runs as a system-level systemd service with strictly sandboxed root, writing only to /opt/arlowe and /var/lib/arlowe/logs/ota.log."** Flag to Joe; if rejected, fall back to polkit-grant-arlowe-write-to-/opt, which is more complex.

2. **Pairing daemon (Phase 8) user.** Same question as OTA: does the Phase 8 pairing daemon run as `arlowe` (can't write `/etc/arlowe/config.yml` under sandbox) or as root (one-shot at first boot, tears down after pairing complete)? **Recommendation: root one-shot, tighter sandbox; Phase 3 doesn't author the unit but documents the recommendation for Phase 8.**

3. **`dialout` and `video` group membership for `arlowe`.** Both are speculative based on Pi 5 audio HAT and framebuffer access patterns. **Action: Phase 3 plan should include "validate on arlowe-1 staging; remove if not needed" as an explicit task with a verification step.**

4. **Pi 5 GPIO chip enumeration on Pi OS 12.4+.** Pi 5's RP1 chip exposes GPIO via `/dev/gpiochip4` (main user-controllable bank) while `/dev/gpiochip0` is internal. The WhisPlay driver may use either or both. **Action: Phase 3 plan should include a hardware-loop verification of which gpiochip nodes the WhisPlay driver actually opens, and `DeviceAllow=` should match.**

5. **Axera device permissions.** `/dev/axcl_host` and `/dev/ax_mmb_dev` ownership is set by the `axcl_host_aarch64_V3.10.2.deb` install scripts. Phase 3 ships a udev rule to chown them to `root:arlowe 0660`, but the exact device names and the deb's behavior need verification. **Action: Phase 3 plan includes a task to inspect the axcl_host.deb postinst (third_party/axcl) and write a matching udev rule.**

6. **Service-restart capability for the dashboard.** Dashboard's `POST /api/voice` issues `systemctl restart arlowe-voice`. The dashboard runs as `arlowe`; systemctl restart of another arlowe unit requires explicit polkit grant (or the dashboard runs as root, which is bad). **Recommendation: Phase 3 ships a polkit rule allowing `arlowe` group members to restart `arlowe-*` units. File: `/etc/polkit-1/rules.d/50-arlowe-systemctl.rules`.** Sample rule:

   ```javascript
   polkit.addRule(function(action, subject) {
       if (action.id == "org.freedesktop.systemd1.manage-units" &&
           subject.user == "arlowe" &&
           action.lookup("unit").startsWith("arlowe-")) {
           return polkit.Result.YES;
       }
   });
   ```

   Flag to Joe — this is a reasonable Phase 3 scope expansion, OR push to Phase 4. Recommend Phase 3 since the dashboard fails open today (Phase 1 used `--user` systemctl which doesn't need this).

7. **Should we set `RemoveIPC=yes` on every unit?** It cleans up POSIX shmem and message queues when the service exits. Voice service uses pyaudio which may or may not allocate POSIX shmem. Default-on is the safer answer but may break audio. **Recommendation: ship without it in Phase 3; revisit if leakage is observed.**

8. **`/var/lib/arlowe/.ssh/authorized_keys` baseline.** Phase 10 specifically asserts this file is absent or has no founder key. **Action: Phase 3 explicitly does NOT create `/var/lib/arlowe/.ssh/`. Document that Phase 10 creates it.** No work item; just an explicit non-action.

---

## Sources

### Primary (HIGH confidence)

- [systemd.exec(5) — Arch manual pages](https://man.archlinux.org/man/systemd.exec.5.en) — sandboxing directive semantics, PrivateDevices/DeviceAllow/SupplementaryGroups behavior
- [Next.js output configuration](https://nextjs.org/docs/pages/api-reference/config/next-config-js/output) — `output: 'standalone'` mechanics, `server.js` runtime
- [Next.js cache directory discussion #67031](https://github.com/vercel/next.js/discussions/67031) — `NEXT_PRIVATE_CACHE_DIR` for read-only-rootfs deployments
- [arlowe-firmware repo: runtime/, .dev-stash/arlowe-1/systemd-*, scripts/sanitize/](.) — internal source-of-truth for what runs today, what the unit-name banlist allows, and what env vars and paths the runtime expects

### Secondary (MEDIUM confidence)

- [systemd ProtectSystem/ProtectHome on Ubuntu](https://oneuptime.com/blog/post/2026-03-02-use-systemd-protectsystem-protecthome-directives-ubuntu/view) — practical strict-mode patterns
- [systemd Service Hardening (Rocky Linux)](https://docs.rockylinux.org/9/guides/security/systemd_hardening/) — systemd-analyze security workflow
- [Hardening with systemd-analyze security](https://dev.to/lyraalishaikh/harden-linux-services-with-systemd-analyze-security-from-score-to-enforceable-policy-3045) — score interpretation guidance
- [pi-gen Customization Guide](https://deepwiki.com/RPi-Distro/pi-gen/5-customization-guide) — custom stage structure for the Phase 6 hand-off
- [Pi udev rules for GPIO/SPI access](https://forums.raspberrypi.com/viewtopic.php?t=9667) — Pi OS's 99-com.rules group assignments

### Tertiary (LOW confidence — verify in Docker testbed or on arlowe-1)

- [Quora: systemd-nspawn vs Docker for testing](https://www.quora.com/What-are-the-merits-of-using-systemd-nspawn-over-Docker) — informed the testbed-choice recommendation
- [Ctrl Blog: systemd hardening 101](https://www.ctrl.blog/entry/systemd-service-hardening.html) — order-of-tightening heuristics
- [No Audio with Systemd Command Service on Raspberry Pi](https://www.blog.neudeep.com/raspberry/no-audio-with-systemd-command-service-on-raspberry-pi/1138/) — Group=audio + sound.target dependency pattern

---

## Metadata

**Confidence breakdown:**

- Standard stack (systemd, useradd, ext4, polkit): HIGH — well-documented, stable APIs
- Architecture (read-only /opt + writable /var/lib + system user + system units): HIGH — Debian/FHS standard
- Per-unit hardening directives: MEDIUM — directives are HIGH confidence; their *interaction with arlowe-specific code paths* needs the Docker testbed and arlowe-1 verification to confirm
- Testbed (Docker primary, arlowe-1 secondary): MEDIUM — recommendation is sound but depends on Joe's appetite for Docker-systemd dance vs. systemd-nspawn fallback
- Next.js read-only deployment: MEDIUM — `NEXT_PRIVATE_CACHE_DIR` is a documented-but-private API
- OTA-01 amendment: LOW until Joe weighs in

**Research date:** 2026-05-26
**Valid until:** ~2026-06-26 (Next.js 16.x cache API stability is the soonest-likely-to-rot item; systemd directives are stable for years)
