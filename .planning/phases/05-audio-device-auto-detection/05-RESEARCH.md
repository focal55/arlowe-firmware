# Phase 5: Audio device auto-detection — Research

**Researched:** 2026-06-08
**Domain:** ALSA device enumeration/selection, udev hotplug, systemd sandboxing, Next.js dashboard config plumbing (all on Raspberry Pi 5 + Whisplay HAT)
**Confidence:** HIGH for in-repo facts (file paths, current call sites, config surface, sandbox state); HIGH for Pi-5-has-no-3.5mm-jack and ALSA card-id stability; MEDIUM for exact on-Pi `/dev/snd/by-id` contents and live hotplug behavior (cannot run on the dev Pi from here — flagged with how to confirm).

---

## Summary

Phase 4 already shipped the entire config *backend* this phase needs: the `audio.capture_device` / `audio.playback_device` knobs exist in `config/schema.yml` (both `string`, default `"auto"`), the Python loader (`runtime/lib/arlowe_config.py`) merges+validates them, the dashboard `POST /api/config` route (`runtime/dashboard/app/api/config/route.ts`) does ajv-validate + atomic temp-file-rename write + knob→unit restart, and the restart map (`restart-map.ts`) already maps `audio → ['arlowe-voice.service']`. The polkit rule already lets the `arlowe` user restart `arlowe-*` units without sudo. So Phase 5 is **not** building config infrastructure — it is (1) writing an ALSA enumeration+selection library, (2) wiring it into the existing call sites in place of the hardcoded `plughw:2,0`, (3) adding a hotplug trigger, (4) adding a server-side "detected devices" enumeration endpoint + a dashboard picker UI (no config UI exists yet — this is greenfield UI on an existing backend), and (5) extending the bash `boot-check` with a capture+playback sentinel that emits structured status.

**Two hardware unknowns resolved:**
- **Target A (device identity):** Store the **ALSA card ID string** (the bracketed name in `/proc/asound/cards`, also at `/proc/asound/card<N>/id`), NOT a bare `hw:N` index. The card ID is derived from the driver/USB descriptor and is stable across reboots and re-plugs; the numeric index is not. `/dev/snd/by-id` is **not** auto-populated for sound devices the way `/dev/serial/by-id` is, so do not depend on it existing. Resolve stored card-id → live `hw:N` at boot/hotplug by reading `/proc/asound/cards`.
- **Target B (output topology):** **The Raspberry Pi 5 has NO onboard 3.5mm analog jack** — it was removed from the board. The roadmap/requirements text "3.5mm fallback" is therefore inaccurate for this hardware. The real default-output chain on the Arlowe hardware is: **USB audio out (if present) → Whisplay/WM8960 codec speaker path → HDMI**. The dev Pi's `/dev/snd` exposes `wm8960-soundcard` + 2× `vc4-hdmi` (confirmed in `docs/operations/phase-3-staging.md:69`). AUDIO-02 should be implemented as "prefer USB output, else fall back to the onboard codec (WM8960), else HDMI" — and the SC2 wording should be reframed away from "3.5mm jack."

**Primary recommendation:** Build one shared Python module `runtime/lib/arlowe_audio.py` that (a) enumerates capture/playback cards by parsing `/proc/asound/cards` + `/proc/asound/card*/stream*` (or shelling `arecord -l`/`aplay -l`), (b) resolves a stored card-id override or an auto-pick to a concrete `plughw:N,0` string, and (c) is imported by `voice_client.py`, `tts_sync.py`, and the CLI helpers. Detected picks stay ephemeral (never written to config); only owner overrides live in `/etc/arlowe/config.yml`, stored as a card-id token (or `"auto"`). Mirror the existing `nmcli`-backed connectivity feature for the dashboard picker.

---

## 1. Current audio I/O — full blast radius of `plughw:2,0`

Every place a device string is injected today. There are **two independent capture mechanisms** in `voice_client.py` (this is a trap — see Pitfall P1).

### Capture (mic)

| File | Lines | Mechanism | Device string | Format |
|------|-------|-----------|---------------|--------|
| `runtime/voice/voice_client.py` | 49 (`RECORD_DEVICE`), used at 256–259 in `record_audio()` | `arecord` subprocess | `os.environ.get("ARLOWE_ALSA_DEVICE", "plughw:2,0")` | `-f S16_LE -r 16000 -c 1` |
| `runtime/voice/voice_client.py` | **337–353** in `main_loop()` | **pyaudio** `PyAudio().open(...)` — separate from arecord | does its OWN device pick: loops `get_device_count()`, takes **first device with `maxInputChannels>0`** (line 339–344), ignores `RECORD_DEVICE` entirely | `paInt16, channels=1, rate=16000, frames_per_buffer=1280` |
| `runtime/wake-word/auto_collect.py` | 21 (`_ALSA_DEVICE`), used at 34–38 (`arecord`) and 44 (`aplay` beep) | `arecord`/`aplay` subprocess | `os.environ.get("ARLOWE_ALSA_DEVICE", "plughw:2,0")` | `-f S16_LE -r 16000 -c 1` |
| `runtime/cli/record` | 9 | `arecord` subprocess | literal `plughw:2,0` | `-f S16_LE -r 16000 -c 2` (note: **2 channels** here, mono elsewhere) |
| `runtime/cli/stt` | 10 | `arecord` subprocess | literal `plughw:2,0` | `-f S16_LE -r 16000 -c 1` |
| `runtime/cli/boot-check` | 79 | `arecord -D plughw:2,0 -d 1 /dev/null` mic probe | literal `plughw:2,0` | TODO(phase-5) already on line 78 |

### Playback (speaker)

| File | Lines | Mechanism | Device string |
|------|-------|-----------|---------------|
| `runtime/voice/voice_client.py` | 50 (`PLAY_DEVICE`), passed into `TTSWithSync(...)` at 189–195 | indirect via tts_sync | `os.environ.get("ARLOWE_ALSA_DEVICE", "plughw:2,0")` |
| `runtime/tts/tts_sync.py` | 91 (default param `play_device="plughw:2,0"`), used at 291 (`aplay -D {self.play_device}`) | `aplay` subprocess (shell) | constructor arg; voice passes `PLAY_DEVICE` |
| `runtime/cli/speak` | 41 | `sox ... | aplay -D plughw:2,0` | literal `plughw:2,0` |
| `runtime/wake-word/auto_collect.py` | 44 | `aplay -D {_ALSA_DEVICE}` beep | env, default `plughw:2,0` |

**Blast radius summary:** 3 Python files (`voice_client.py`, `tts_sync.py`, `auto_collect.py`) and 4 bash CLI scripts (`record`, `stt`, `speak`, `boot-check`). The `ARLOWE_ALSA_DEVICE` env var is the existing seam for the Python `arecord`/`aplay` paths — but it conflates capture and playback into one string (voice_client sets both RECORD_DEVICE and PLAY_DEVICE from the same var), which Phase 5 must split into capture vs playback.

**The pyaudio path (voice_client.py:337–353) is the real wake-word mic and is NOT controlled by `ARLOWE_ALSA_DEVICE` at all** — it picks the first input-capable PortAudio device by index. This is a separate selection surface that also needs to honor the auto-detect/override result (PortAudio device index ≠ ALSA card index; the module must map the chosen ALSA card to the matching PortAudio `input_device_index` by name match, or the runtime must set the ALSA default so PortAudio's default device follows). See Pitfall P1.

---

## 2. Phase 4 config surface for audio (already exists)

`config/schema.yml:53–68` and `config/defaults.yml:13–15`:

```yaml
audio:
  type: object
  additionalProperties: false   # <-- cannot add sibling keys without a schema change
  required: [capture_device, playback_device]
  properties:
    capture_device:  { type: string, default: "auto" }   # "auto" or an ALSA device name
    playback_device: { type: string, default: "auto" }
```

- Both knobs already exist, typed `string`, default `"auto"`. **No schema change is strictly required** to store an override — but note `additionalProperties: false` means you cannot add e.g. `audio.capture_card_id` as a new key without editing the schema. **Recommendation:** keep the two existing keys and store the **card-id token** as their string value (e.g. `capture_device: "Device"` where `Device` is the `/proc/asound/cards` id), with `"auto"` reserved as the sentinel for "no override." This avoids a schema migration and keeps the locked decision "absence/`auto` = auto-detect."
- If you decide a card-id needs disambiguation from a literal ALSA string, the cleanest schema-compatible encoding is a prefixed token like `"cardid:Device"` vs `"auto"`. Decide this in planning; either fits the existing `string` type.

**Loader accessor pattern** (`runtime/lib/arlowe_config.py:46`):

```python
from arlowe_config import load
cfg = load()                       # merged defaults+overlay, validated; raises SystemExit(78) on schema violation
capture_override = cfg["audio"]["capture_device"]   # "auto" or a token
playback_override = cfg["audio"]["playback_device"]
```

The module is installed flat at `/opt/arlowe/runtime/lib/` and is on `PYTHONPATH` via the unit (`arlowe-voice.service:14` sets `PYTHONPATH=/opt/arlowe/runtime:/opt/arlowe/runtime/lib`). `voice_client.py` does NOT currently import it — Phase 5 wires it in. The ExecStartPre `arlowe_config_validate` (unit line 23) already fail-fasts on a bad overlay.

---

## 3. ALSA enumeration & selection — recommended mechanics

**Recommendation: parse `/proc/asound/` directly (primary) with `arecord -l`/`aplay -l` as a cross-check.** Rationale for the headless `arlowe` user under the Phase 3 sandbox:

- `/proc/asound/cards`, `/proc/asound/card*/id`, `/proc/asound/card*/stream0`, `/proc/asound/pcm` are plain procfs reads — **not** blocked by `ProtectSystem=strict` (that protects `/usr`,`/etc`,`/boot`, not `/proc`) and **not** a `/dev/snd` device node, so they're readable even where `DeviceAllow` is restrictive. This is the most robust path.
- `arecord -l`/`aplay -l` and `cat /proc/asound/cards` give card index + bracketed **card ID** + longname. `/proc/asound/card<N>/stream0` (USB) or `card<N>/pcm0c/sub0/hw_params` give supported rate/format when a stream is open; for "can this do 16k S16_LE" the forgiving locked decision is to **not** probe strictly — open via `plughw` and let ALSA resample (mirrors old `plughw:2,0`). So enumeration only needs: index, card ID, longname, and whether the card has a capture (`[Cc]`) or playback device.
- `arecord --dump-hw-params -D hw:N,0` exists for strict native-format probing but the locked decision says forgiving `plughw` matching — **do not** gate selection on native 16k. Use it at most for diagnostics.

**Library choice for the selection logic:** plain Python stdlib parsing `/proc/asound` + `subprocess` to `arecord -l`/`aplay -l`. **Avoid pyalsa/python-sounddevice as the enumeration source of truth** — pyalsa is rarely packaged and version-fragile; sounddevice/PortAudio enumerates by PortAudio index (a different namespace) and is exactly the mismatch that bites in voice_client.py:337. Use sounddevice/pyaudio only where you must open a PortAudio stream (the wake-word loop), and resolve the chosen ALSA card to a PortAudio device by **name substring match**.

**"First compatible" capture pick order (auto):**
1. If override token resolves to a present card → use it.
2. Else first card whose `/proc/asound/card*/id` looks like a USB capture device (has a capture stream; USB cards appear as `usb-...` in longname / `card*/usbid`).
3. Else the onboard/HAT codec capture (WM8960) — the locked-decision fallback ("no USB capture → onboard/HAT mic"). "No capture card at all" is the genuine failure → emit failure signal.

**Playback pick order (auto), per resolved Target B:**
1. Override token if present.
2. First USB **playback** card.
3. Onboard codec (`wm8960-soundcard`).
4. HDMI (`vc4-hdmi*`) as last resort.

`/dev/snd` group access is already granted: `arlowe-voice.service:11` has `SupplementaryGroups=audio dialout`; `:52` `DeviceAllow=/dev/snd/* rw`; `:48` `RestrictAddressFamilies=... AF_NETLINK` (comment on :47 explicitly says "AF_NETLINK required for ALSA device enumeration via kernel"); `:51` `PrivateDevices=no`. **The voice unit is already provisioned for this work.** (Sandbox gotchas in §9.)

---

## 4. Hotplug mechanism — recommended approach

**Recommendation: a udev rule `provision/udev/9X-arlowe-audio.rules` matching `SUBSYSTEM=="sound", ACTION=="add"|"remove"` that runs `systemctl restart arlowe-voice.service` (or a lighter reconfigure), installed via the existing `scripts/provision/install-arlowe-udev-polkit.sh` chain.**

Mechanics and conventions to follow:
- The install script already globs `provision/udev/*.rules` and `provision/polkit/*.rules` (`install-arlowe-udev-polkit.sh:42,45`), so a new `9X-arlowe-audio.rules` is picked up automatically with zero script edits. Name it `9X-` to match the existing `90-`/`91-` numbering. Mirror the header-comment style of `91-arlowe-gpio-spi.rules`.
- udev can't call `systemctl` directly in a robust way under newer udev (RUN+= is discouraged for long-running/daemon interaction). **Two clean options:**
  - (a) `ENV{SYSTEMD_WANTS}+=` / a `TAG+="systemd"` device unit — heavier.
  - (b) **Recommended: a systemd `.path` unit or a tiny oneshot triggered by udev `RUN+="/bin/systemctl --no-block restart arlowe-voice.service"`** scoped to `SUBSYSTEM=="sound"`. The `--no-block` avoids udev-systemd deadlock. The polkit rule (`50-arlowe-systemctl.rules`) authorizes `arlowe-*` restarts, but **udev runs as root**, so the restart is allowed regardless of polkit (polkit only gates the unprivileged dashboard path).
- Debounce: USB audio plug/unplug fires multiple `sound` events (controlC, pcmC0D0c, pcmC0D0p, timer). Use a short settle/coalesce (e.g. restart only on the `controlC*` add/remove, or a 1–2s debounce via a path-unit) to avoid restart storms. See Pitfall P4.
- Keep it consistent: a full `systemctl restart arlowe-voice` is the simplest robust action and reuses the Phase-4 restart pattern. A live in-process reconfigure (signal handler re-reading `/proc/asound`) is lower-latency but more code; given the atomic-PR cap, **restart-on-hotplug is the recommended v1**.

**Confirm on hardware:** which exact `sound` subsystem events fire on your USB adapter plug/unplug, and that `controlC*` is the right debounce anchor — `udevadm monitor --subsystem-match=sound` while plugging.

---

## 5. Device identity (Target A) — resolved

- **Store the ALSA card ID string** (bracketed name in `/proc/asound/cards`; canonical source `/proc/asound/card<N>/id`). It is derived from the driver/USB descriptor, stable across reboot and re-plug, and independent of the enumeration index. This directly fixes the "indices shuffle" bug that motivates the phase.
- **`/dev/snd/by-id` and `/dev/snd/by-path` are NOT reliably auto-populated** for sound devices on Pi OS the way `/dev/serial/by-id` is. Default udev sound rules don't create per-card by-id symlinks unless you add a `SYMLINK+="snd/..."` rule yourself. **Do not store a `/dev/snd/by-id/...` path as the identity token** — it likely won't exist. (Confirm with `ls -l /dev/snd/by-id 2>/dev/null` on the Pi; expect "No such file or directory" or a near-empty dir.)
- If two identical USB adapters could be present (unlikely for this product), the card ID alone may collide; the tie-breaker would be `/proc/asound/card<N>/usbid` (idVendor:idProduct) + USB path. For v1, card ID is sufficient — note the limitation.
- **Resolve token → live device at boot/hotplug:** read `/proc/asound/cards`, find the line whose ID matches the stored token, take its index N, emit `plughw:N,0` (forgiving, per locked decision). If no match → silently fall back to auto-detect (locked decision: "override device absent at boot → fall back to auto").

**Confidence:** HIGH that card ID is the right stable token (corroborated by ALSA docs: `/proc/asound/card*/id` is the documented stable card identifier). MEDIUM on the exact `/dev/snd/by-id` contents on *your* Pi 5 image — confirm with one `ls`.

---

## 6. Output topology (Target B) — resolved

**The Pi 5 has no onboard 3.5mm analog audio jack** (removed from the board; confirmed by Raspberry Pi forums/The Register and general Pi 5 docs). So "3.5mm fallback" as literally written in AUDIO-02/SC2 **does not describe this hardware.**

What `/dev/snd` actually contains on the Arlowe dev Pi (from the repo's own staging notes, `docs/operations/phase-3-staging.md:69`):
> "`/dev/snd` present (`wm8960-soundcard` + 2× vc4-hdmi); voice uses ALSA"

So the real output cards are: the **WM8960 codec** (Whisplay HAT — I2C/in-kernel codec, NOT USB despite `runtime/voice/README.md:11` mislabeling `plughw:2,0` as a "USB audio HAT" — that README line is wrong; the WM8960 is an I2C soundcard) and **two HDMI** outputs. Any "3.5mm" the product has would be a jack wired off the **WM8960 codec on the Whisplay HAT**, not the Pi board.

**Recommended concrete AUDIO-02 behavior:** prefer a USB playback card if present; else fall back to the **onboard/HAT codec (wm8960-soundcard)**; else HDMI. Reframe SC2 in the plan as: *"No USB output → fall back to the onboard Whisplay/WM8960 codec; USB output present → USB preferred."* This is consistent with the locked CONTEXT decision for capture ("no USB → onboard/HAT codec mic") and avoids asserting a jack that isn't on the board.

**There is no `asound.conf`, no `dtoverlay` audio config, and no committed audio hardware config in the repo** (grep found none). The WM8960 is brought up by an in-kernel/I2C driver + a dtoverlay applied at the OS-image layer (Phase 6 pi-gen territory), not in this repo today. Flag: confirm the exact WM8960 dtoverlay/soundcard name on the target image during Phase 6; Phase 5 should match on the `wm8960` substring rather than a hardcoded index.

**Confidence:** HIGH that Pi 5 has no analog jack and that the repo's `/dev/snd` is wm8960 + HDMI. MEDIUM on whether the production Whisplay exposes a *physical* 3.5mm off the codec — confirm on hardware; either way the ALSA-level fallback target is the `wm8960-soundcard`.

---

## 7. boot-check integration

`runtime/cli/boot-check` is a **bash** script (not Python). It already has a mic probe at lines 78–84:
```bash
# TODO(phase-5): plughw:2,0 hardcoded; replace with auto-detected device.
if arecord -D plughw:2,0 -d 1 /dev/null 2>/dev/null; then echo "OK Microphone (WM8960)"; ((PASS++)); ...
```
Structure: `check_service`/`check_port` helpers, `PASS`/`FAIL` counters, a `HARDWARE:` section, plaintext `OK`/`FAIL`/`WARN` lines, final `Results: N passed, M failed`. It is human-oriented; there is **no structured/JSON output today**.

**Recommended Phase-5 changes:**
1. Replace the hardcoded `plughw:2,0` probe with the auto-detected capture device (call the new audio module — easiest is a tiny `python3 -m arlowe_audio --resolve-capture` that prints the resolved `plughw:N,0`, or a bash helper that parses `/proc/asound`).
2. Add a **capture sentinel**: `arecord` a short buffer on the resolved device and assert it is non-silent (RMS above a floor) — "audio moved." Retry-then-report (locked-decision: retry then report).
3. Add a **playback sentinel**: emit a short tone via the resolved playback device (`sox -n synth ... | aplay -D <playback>`), checked independently (locked decision: "move audio, no acoustic coupling" — capture and playback verified separately, no loopback dependency).
4. **Emit structured status for Phase 11.** boot-check currently prints only human text. Add a machine-readable artifact so Phase 11's health view can consume it without re-running probes: write a JSON file to `/var/lib/arlowe/state/` (already in `ReadWritePaths` of the voice unit; boot-check runs as a CLI — confirm its run context/writability) **and** emit a greppable journal line. Suggested shape:
   ```json
   {"check":"audio","capture":{"device":"plughw:2,0","ok":true},
    "playback":{"device":"plughw:1,0","ok":false,"error":"no playback card"},
    "ts":"2026-06-08T..."}
   ```
   Mirror the existing greppable-stderr convention used by the config loader (`[arlowe-config] ...` lines) with an `[arlowe-audio] ...` prefix for the journal. Phase 11 then reads the JSON file (preferred) or greps the journal.

**Decide in planning:** whether the sentinel logic lives in bash inside `boot-check` or in `arlowe_audio.py` invoked by boot-check. Given the capture-RMS check is easier in Python (numpy already a voice dep), recommend a `python3 -m arlowe_audio --selfcheck` subcommand that does both sentinels and prints/writes the JSON, called from `boot-check`. Keeps bash thin and reuses the enumeration code.

---

## 8. Dashboard plumbing

**Backend already built (Phase 4):**
- `POST /api/config` (`runtime/dashboard/app/api/config/route.ts`): ajv-validates body against `schema.yml` (422 on violation, nothing written), atomic temp+rename write to `/etc/arlowe/config.yml`, diffs changed top-level keys, restarts mapped units. **Audio overrides flow through this unchanged** — POST a body with `audio.capture_device`/`audio.playback_device` set to the chosen card-id token (or `"auto"`).
- `restart-map.ts` already maps `audio → ['arlowe-voice.service']` (line 9). So saving an audio override auto-restarts voice. **No restart-map change needed** unless you decide playback changes should also bounce something else (they don't — voice owns both paths). The map's INVARIANT (only `arlowe-*`/`qwen-*`/`whisper-stt` unit prefixes) is satisfied.
- `ARLOWE_SYSTEMCTL_MODE=system` is set in `arlowe-dashboard.service:17`, and the polkit rule authorizes the restart.

**What's missing (greenfield in Phase 5):**
1. **No "detected devices" endpoint exists.** The browser cannot read ALSA — enumeration must be server-side. **Add `runtime/dashboard/app/api/audio/devices/route.ts`** that shells `arecord -l` + `aplay -l` (or `cat /proc/asound/cards` + per-card id) and returns `{ capture: [{id, name, index}], playback: [...] }`. **Pattern to copy verbatim:** `runtime/dashboard/app/api/connectivity/networks/route.ts` — it `exec`s `nmcli`, parses terse output to JSON, returns the array. Replace `nmcli` with the ALSA command. (Pitfall P2: the dashboard unit has `PrivateDevices=yes` — see §9; `arecord -l` reads `/proc/asound` not `/dev/snd` so should still work, but **confirm on hardware**; if blocked, the endpoint can read `/proc/asound/cards` directly via `fs` instead of shelling out, which is unaffected by `PrivateDevices`.)
2. **No config/settings UI page exists at all.** There is no page consuming `/api/config` today (grep confirms only `restart-map.ts` references it). The audio picker is a **new client page** (e.g. `app/audio/page.tsx` or a settings page) + nav entry. **Pattern to copy:** the connectivity feature (`app/connectivity/page.tsx` + `components/NetworkList.tsx` + modal): a list fetched from a GET endpoint, click-to-select, POST on confirm, error toast. The audio picker is simpler: two dropdowns (capture/playback) populated from `/api/audio/devices`, friendly card names, a Save that POSTs the override to `/api/config`, an empty state when no devices (locked decision). On save the existing route restarts `arlowe-voice`.
3. **Friendly names:** map raw ALSA card IDs/longnames to readable labels in the endpoint (e.g. longname → "USB Audio Device", "Whisplay (WM8960)"). Keep the card-id token as the stored value.

**Files to extend:** new `app/api/audio/devices/route.ts` (mirror connectivity/networks), new `app/audio/page.tsx` + components (mirror connectivity), `app/components/Navigation.tsx` (add nav link). **No change** to `config/route.ts` or `restart-map.ts`.

---

## 9. Pitfalls

**P1 — voice_client.py has TWO capture surfaces; the live wake-word mic is pyaudio, not arecord.** `record_audio()` uses `arecord -D RECORD_DEVICE`, but the always-on wake-word stream (`main_loop()` lines 337–353) uses pyaudio and picks "first input device by PortAudio index," ignoring `RECORD_DEVICE`. If Phase 5 only fixes the `arecord` string, the wake-word mic is still auto-picked by PortAudio and can diverge from the configured device. The audio module must produce BOTH an ALSA `plughw:N,0` string (for arecord/aplay paths) AND a way to point pyaudio at the same physical card (resolve PortAudio `input_device_index` by name substring, or set the ALSA default device so PortAudio's default follows). **This is the single biggest correctness trap in the phase.**

**P2 — dashboard unit has `PrivateDevices=yes` (`arlowe-dashboard.service:37`).** It cannot open `/dev/snd` nodes. `arecord -l`/`aplay -l` read `/proc/asound` (procfs, not a device node) so likely still work, but this is unverified under the sandbox. **Safer:** the devices endpoint reads `/proc/asound/cards` + `/proc/asound/card*/id` directly via `fs` (unaffected by `PrivateDevices`) instead of shelling `arecord -l`. Confirm on hardware which works.

**P3 — capture vs playback conflation in `ARLOWE_ALSA_DEVICE`.** Today one env var feeds both RECORD_DEVICE and PLAY_DEVICE. Phase 5 must split into two resolved strings (capture, playback) since USB-in/codec-out can be different cards.

**P4 — hotplug restart storm.** A single USB plug emits multiple `sound` udev events (control, pcm-capture, pcm-playback, timer). Without debounce, each triggers a voice restart. Anchor the trigger on `controlC*` add/remove or debounce via a `.path`/timer. (`91-arlowe-gpio-spi.rules` header already documents this kernel's flaky device enumeration — expect similar noise on sound.)

**P5 — race between hotplug restart and an in-flight recording.** Restarting `arlowe-voice` mid-`arecord`/mid-TTS aborts the interaction. Acceptable for v1 (rare), but note it; a future reconfigure-in-place avoids it.

**P6 — `plughw` resampling is intentional but lossy/quiet.** The forgiving `plughw` (vs `hw`) lets ALSA convert 16k S16_LE mono ↔ the card's native rate. This mirrors the old behavior and is the locked decision — but the capture sentinel's RMS floor must tolerate the resampler's quirks (don't set the "non-silent" threshold too high).

**P7 — `additionalProperties: false` on the `audio` schema object.** You cannot add new `audio.*` keys (e.g. a separate `card_id` field) without editing `config/schema.yml`. Store the card-id token inside the existing `capture_device`/`playback_device` strings.

**P8 — STT unit has `PrivateDevices=yes` and no `audio` group** (`whisper-stt.service:18`). That's correct — STT only receives WAV bytes over HTTP and never touches the mic. **Do not** add audio access to STT.

**P9 — boot-check run context.** boot-check is a CLI (`/usr/local/sbin/arlowe-*` symlink per Phase 3). Confirm under which user/sandbox it runs when invoked at boot and whether it can write the structured JSON to `/var/lib/arlowe/state/` (owned by `arlowe`). If it runs as root or interactively, writability differs.

**P10 — README/comment drift.** `runtime/voice/README.md:11` calls `plughw:2,0` "the WM8960 USB audio HAT" — WM8960 is an I2C codec, not USB. boot-check:79 labels the mic "(WM8960)". Don't trust these labels as ground truth for what card index 2 is; enumerate at runtime.

---

## 10. Suggested plan breakdown

Respecting the atomic-PR cap (<400 net, hard 600) and the established "foundational lib/schema first → consumers → non-autonomous hardware-verify slice" pattern (Phases 1/3/4):

**Wave 1 — foundation (no hardware needed; CI-testable with fixtures):**
- **05-01 — `runtime/lib/arlowe_audio.py`**: enumerate cards from `/proc/asound` (+`arecord -l`/`aplay -l` cross-check), resolve `"auto"`/card-id token → `plughw:N,0` for capture and playback per the §3 pick orders and Target-B fallback. Unit-tested against captured `/proc/asound` fixtures (no real audio). Pure logic + parsing. ~ small.

**Wave 2 — consumers (depend on 05-01; parallelizable streams):**
- **05-02 (Stream A, capture+playback wiring)**: import `arlowe_audio` into `voice_client.py` (both the arecord path AND the pyaudio wake-word path — P1), `tts_sync.py`, and the bash CLI (`record`, `stt`, `speak`, `auto_collect.py`). Replace `plughw:2,0`/`ARLOWE_ALSA_DEVICE` with resolved capture/playback strings; split capture vs playback. Watch the net-line cap — this touches many files; may need a split (Python vs bash).
- **05-03 (Stream B, dashboard)**: `app/api/audio/devices/route.ts` (mirror connectivity/networks, read `/proc/asound`) + `app/audio/page.tsx` picker (mirror connectivity page) + nav link. POSTs override to existing `/api/config`. Empty-state + friendly names. Independent of 05-02.
- **05-04 (Stream C, hotplug)**: `provision/udev/9X-arlowe-audio.rules` (`SUBSYSTEM=="sound"` → `systemctl --no-block restart arlowe-voice`), debounced; picked up by existing install script. Tested in the Phase-3-style Docker harness for rule shape (no real hotplug in CI).

**Wave 3 — boot-check sentinel (depends on 05-01):**
- **05-05**: extend bash `boot-check` to use the resolved devices + add capture/playback sentinels via `python3 -m arlowe_audio --selfcheck`, emit structured JSON to `/var/lib/arlowe/state/` + `[arlowe-audio]` journal line for Phase 11. Logic-testable; the real-audio assertion is hardware.

**Wave 4 — non-autonomous hardware verify (mirror plan 03-05 / 04-04):**
- **05-06 (non-autonomous, requires owner + real Pi + USB adapter)**: verify SC1 (plug USB capture → auto-selected; unplug/replug → next boot picks up), SC2 (USB out preferred, fallback to wm8960), SC4 (sentinel pass/fail surfaces in journal). **Likely deferred** the same way as Phase 1/3/4 SC4: the founder's `arlowe-1` is the daily driver and **has no `/opt/arlowe` layout/venvs** (STATE.md:14, ROADMAP Phase-4 note). Recommend: write the procedure in `docs/operations/phase-5-audio.md` and **defer the on-real-arlowe SC verification to the Phase-3-style staging harness or Phase 6/12**, exactly as Phases 1/3/4 did. SC3 (override persists across reboot) is the most CI/staging-friendly and can be partially proven without arlowe layout (config write+read), but the "honored over auto-detect at runtime" half needs hardware.

**SC deferral flags (matches house pattern):**
- **SC1, SC2, SC4 likely need the hardware-verify checkpoint** (real USB plug/unplug, real codec, real audio movement) and should follow the Phase 1/3/4 deferral precedent (arlowe-1 has no arlowe layout). Flag explicitly in the plan.
- **SC3** can be largely validated autonomously (schema round-trip + atomic write + restart-map) with the runtime-honoring half deferred to hardware.

---

## Open Questions

1. **`/dev/snd/by-id` contents on the target Pi 5 image** — recommend storing card ID regardless (don't depend on by-id). Confirm: `ls -l /dev/snd/by-id /dev/snd/by-path 2>/dev/null` on the Pi.
2. **Which `sound` udev events fire on USB plug/unplug, and the right debounce anchor** — confirm: `udevadm monitor --subsystem-match=sound` while plugging.
3. **Does `arecord -l` work under the dashboard's `PrivateDevices=yes`?** — if not, read `/proc/asound/cards` via `fs` instead. Confirm on hardware.
4. **boot-check's boot-time run user/sandbox and write access to `/var/lib/arlowe/state/`** — confirm how/where it's invoked at boot.
5. **Exact WM8960 soundcard name + whether a physical jack exists off the codec** — confirm: `cat /proc/asound/cards` on the Whisplay Pi; matters only for label friendliness, not selection logic (match on `wm8960` substring).
6. **PortAudio↔ALSA mapping for the wake-word stream** — confirm the name-substring match resolves correctly, or whether setting the ALSA default device is the cleaner fix (P1).

---

## Sources

### Primary (HIGH) — in-repo, cited inline
- `runtime/voice/voice_client.py` (49–50, 256–259, 337–353), `runtime/tts/tts_sync.py` (91, 291), `runtime/wake-word/auto_collect.py` (21, 34–44), `runtime/cli/{record,stt,speak,boot-check}`, `config/schema.yml` (53–68), `config/defaults.yml` (13–15), `runtime/lib/arlowe_config.py`, `units/arlowe-voice.service` / `arlowe-dashboard.service` / `whisper-stt.service`, `runtime/dashboard/app/api/config/route.ts` + `restart-map.ts`, `runtime/dashboard/app/api/connectivity/networks/route.ts` + `app/connectivity/page.tsx`, `provision/udev/91-arlowe-gpio-spi.rules`, `provision/polkit/50-arlowe-systemctl.rules`, `scripts/provision/install-arlowe-udev-polkit.sh`, `docs/operations/phase-3-staging.md` (69, 71, 72), `.planning/ROADMAP.md` (128–143), `.planning/STATE.md` (14).

### Secondary (MEDIUM) — web, verified by multiple sources
- Pi 5 has no onboard 3.5mm jack: Raspberry Pi Forums (t=357073, t=357012), The Register (2023/09/28). https://www.theregister.com/2023/09/28/raspberry_pi_5_revealed/
- ALSA card ID stability / `/proc/asound/cards` + `/proc/asound/card*/id` as the stable card identifier; `arecord -l`/`-L`, `aplay -l`: ArchWiki ALSA, James Ahlstrom "ALSA Device Names". https://wiki.archlinux.org/title/Advanced_Linux_Sound_Architecture
- `/dev/snd/by-id` not auto-populated like serial: habets.se "Linux sound devices are a mess." https://blog.habets.se/2021/12/Linux-Sound-devices-are-a-mess.html

---

## Metadata

**Confidence breakdown:**
- Current call sites / blast radius: HIGH (read every file).
- Config + dashboard backend reuse: HIGH (Phase-4 code present and inspected).
- Target A (store card ID): HIGH on the recommendation; MEDIUM on by-id absence specifics (confirm with one `ls`).
- Target B (no 3.5mm jack; fallback = wm8960): HIGH that Pi 5 has no jack and repo /dev/snd is wm8960+HDMI; MEDIUM on production-jack physicality.
- Hotplug/udev approach: MEDIUM (sound-event specifics unverified on hardware).

**Research date:** 2026-06-08
**Valid until:** ~2026-09-08 (stable domain: ALSA/udev/Pi-5 hardware facts don't move fast; the in-repo facts are valid until the code changes).
