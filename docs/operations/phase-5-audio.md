# Phase 5 audio auto-detection — hardware verification procedure

This document is the manual on-hardware verification procedure for Phase 5
(audio device auto-detection, plans 05-01 through 05-06). It covers SC1–SC4,
the live hotplug scenario (beyond SC1's boot-only wording), and a checklist of
hardware-only unknowns that must be resolved on a real Pi.

**Status: DEFERRED.** Like Phase 1 plan 13, Phase 3 plan 05-05, and Phase 4
plan 04-04, the on-device run is a human checkpoint deferred to the Phase 3-style
staging harness or Phase 6/12. The dev Pi (arlowe-1) has no `/opt/arlowe`
arlowe-user layout to run this against. The procedure is the deliverable; the
run is the checkpoint.

---

## SC2 reframe — read this before running anything

**The Pi 5 has no onboard 3.5mm analog audio jack.** The jack was removed from
the board (confirmed by research §6 in `05-RESEARCH.md`, corroborated by
Raspberry Pi Forums and The Register, 2023-09-28). The AUDIO-02/SC2 text
"3.5mm jack fallback" does not describe this hardware.

The real output card set on the Arlowe Pi (from staging notes at
`docs/operations/phase-3-staging.md:69`):
- `wm8960-soundcard` — the Whisplay HAT codec (I2C, in-kernel driver)
- `vc4-hdmi-0` and `vc4-hdmi-1` — two HDMI outputs

Any physical 3.5mm jack on the Whisplay HAT is wired off the WM8960 codec, not
off the Pi board. At the ALSA level, the fallback target is `wm8960-soundcard`,
not a Pi-board headphone jack.

**The implemented fallback chain for playback (AUDIO-02) is:**

```
USB output (if present)  ->  wm8960 codec (Whisplay HAT)  ->  HDMI
```

Selection matches the `wm8960` substring in the card-id, not a fixed index
(indices shuffle across reboots). The SC2 original text is preserved in
`.planning/ROADMAP.md` with an annotation; `docs/operations/phase-5-audio.md`
(this file) is the authoritative reframe.

---

## Preconditions

- A Pi 5 with Whisplay HAT attached and the Phase 5 runtime provisioned:
  - `/opt/arlowe/runtime/lib/arlowe_audio.py` present (plan 05-01)
  - `arlowe-voice.service` and `arlowe-dashboard.service` installed and running
  - Python venv at `/opt/arlowe/runtime/lib/` on `PYTHONPATH`
  - Dashboard reachable at `http://localhost:3000`
- A USB audio adapter that provides both capture (mic) and playback (speaker),
  or separate USB mic + USB speaker.
- SSH access or a local terminal as a user that can `sudo systemctl`.
- `PYTHONPATH` set: `export PYTHONPATH=/opt/arlowe/runtime/lib`

arlowe-1 (the dev Pi) does **not** have this layout. Run on a provisioned
staging or production device.

---

## Artifacts referenced by this procedure

| Artifact | Plan | Role |
|---|---|---|
| `runtime/lib/arlowe_audio.py` | 05-01 | Enumeration + resolution library |
| `runtime/voice/voice_client.py` | 05-02 | Wake-word pyaudio path + arecord path |
| `runtime/tts/tts_sync.py` | 05-02 | Playback path |
| `runtime/cli/record`, `stt`, `speak` | 05-03 | Bash CLI helpers |
| `runtime/dashboard/app/api/audio/devices/route.ts` | 05-04 | Server-side device enumeration |
| `runtime/dashboard/app/audio/page.tsx` | 05-04 | Dashboard picker UI |
| `provision/udev/92-arlowe-audio.rules` | 05-05 | Hotplug trigger |
| `runtime/cli/boot-check` | 05-06 | Boot sentinel |
| `runtime/lib/arlowe_audio.py` (`--selfcheck`) | 05-06 | Capture RMS + playback tone sentinel |

---

## SC1 — USB capture auto-select

### 1a. USB mic plugged

```bash
# Confirm the USB card is present in ALSA:
cat /proc/asound/cards
# Expect a line like: " 1 [Device         ]: USB-Audio - USB Audio Device"

# Resolve capture device via the library:
PYTHONPATH=/opt/arlowe/runtime/lib python3 -m arlowe_audio --resolve-capture
# Expect: plughw:N,0 where N is the USB card's index
```

Trigger a wake-word interaction ("Hey Arlowe") and confirm it works. Then check
the voice journal for the device in use:

```bash
journalctl -u arlowe-voice -n 50 | grep -i "capture\|device\|plughw"
# Expect a line referencing the USB card's plughw string
```

### 1b. USB mic unplugged — reboot — re-plug — reboot

Unplug the USB mic. Reboot.

```bash
PYTHONPATH=/opt/arlowe/runtime/lib python3 -m arlowe_audio --resolve-capture
# Expect: plughw:N,0 for the wm8960 codec (fallback; USB absent)
cat /proc/asound/cards
# Confirm no USB capture card listed
```

Re-plug the USB mic. Reboot.

```bash
PYTHONPATH=/opt/arlowe/runtime/lib python3 -m arlowe_audio --resolve-capture
# Expect: plughw:N,0 for the USB card (back to USB; no manual config needed)
```

### 1c. pyaudio wake-word path follows the same card (Pitfall P1)

The wake-word loop in `voice_client.py` uses pyaudio, not arecord. Confirm
that the pyaudio stream uses the same physical card as `--resolve-capture`:

```bash
journalctl -u arlowe-voice -n 100 | grep -i "Device:\|pyaudio\|\[arlowe-audio\]"
# Expect a log line identifying the PortAudio device by the same card name/substring
```

If the log shows a different device, the PortAudio name-match in
`portaudio_index_for_card()` did not resolve correctly — see the deferred
unknowns checklist (section below).

---

## SC2 — USB output preferred; wm8960 fallback (NOT a 3.5mm jack)

See the SC2 reframe at the top of this document. The fallback is the
wm8960 codec, not a Pi-board 3.5mm jack.

### 2a. USB speaker plugged

```bash
PYTHONPATH=/opt/arlowe/runtime/lib python3 -m arlowe_audio --resolve-playback
# Expect: plughw:N,0 for the USB card
```

Trigger TTS ("Arlowe, say hello") and confirm audio plays through the USB speaker.

### 2b. USB speaker unplugged

Unplug the USB speaker (or test without one plugged from the start).

```bash
PYTHONPATH=/opt/arlowe/runtime/lib python3 -m arlowe_audio --resolve-playback
# Expect: plughw:N,0 for the wm8960 card

cat /proc/asound/cards
# Confirm: wm8960-soundcard is present and is the resolved card
```

Trigger TTS and confirm audio plays through the Whisplay HAT (or its connected
speaker/jack).

Note: confirm the exact wm8960 soundcard name in step 2b — it is expected to
contain the `wm8960` substring. If the production image uses a different
dtoverlay name, record it in the deferred unknowns checklist.

---

## SC3 — Dashboard override persists across reboot and wins over auto-detect

### 3a. Save an override via the dashboard

Navigate to `http://localhost:3000/audio` and select a specific capture device
from the dropdown. Save. Or use the API directly:

```bash
# First, get the current card-id token for the device you want to pin:
PYTHONPATH=/opt/arlowe/runtime/lib python3 -m arlowe_audio --list
# Note the "id" field (e.g. "Device") for the target card

# POST the override:
curl -sS -X POST http://localhost:3000/api/config \
  -H 'Content-Type: application/json' \
  -d '{"audio":{"capture_device":"Device"}}'
# Expect: HTTP 200
```

Confirm the overlay was written atomically:

```bash
sudo cat /etc/arlowe/config.yml
# Expect: audio.capture_device: "Device" (or the token you set)
```

Confirm the voice service restarted (restart-map.ts maps audio -> arlowe-voice):

```bash
journalctl -u arlowe-voice -n 20
# Expect: a restart entry shortly after the POST
```

### 3b. Override survives reboot and wins over auto-detect

Reboot. After restart:

```bash
PYTHONPATH=/opt/arlowe/runtime/lib python3 -m arlowe_audio --resolve-capture
# Expect: plughw:N,0 for the pinned card, even if a different USB card is plugged
sudo cat /etc/arlowe/config.yml
# Confirm: capture_device still set to the token from 3a
```

### 3c. Override for an absent card silently falls back to auto-detect

Set an override to a card-id that is NOT plugged in:

```bash
curl -sS -X POST http://localhost:3000/api/config \
  -H 'Content-Type: application/json' \
  -d '{"audio":{"capture_device":"NotPresentCard"}}'
```

Reboot.

```bash
PYTHONPATH=/opt/arlowe/runtime/lib python3 -m arlowe_audio --resolve-capture
# Expect: plughw:N,0 for the auto-detected fallback (wm8960 or USB if plugged)
# NOT: an error or service failure
```

Confirm `arlowe-voice` is active (functional-degraded, not stopped):

```bash
systemctl is-active arlowe-voice
# Expect: active
```

### 3d. Clear the override

```bash
curl -sS -X POST http://localhost:3000/api/config \
  -H 'Content-Type: application/json' \
  -d '{"audio":{"capture_device":"auto","playback_device":"auto"}}'
# Expect: HTTP 200
sudo cat /etc/arlowe/config.yml
# Confirm: audio keys are "auto" or absent
```

---

## SC4 — Boot sentinel surfaces in journald and JSON status file

### 4a. selfcheck — both devices OK

```bash
PYTHONPATH=/opt/arlowe/runtime/lib python3 -m arlowe_audio --selfcheck
# Expect: JSON to stdout with both capture.ok=true and playback.ok=true
# Expect: exit 0
```

Confirm the JSON status file was written:

```bash
cat /var/lib/arlowe/state/audio-selfcheck.json
# Expect shape:
# {
#   "check": "audio",
#   "capture": {"device": "plughw:N,0", "ok": true},
#   "playback": {"device": "plughw:M,0", "ok": true},
#   "ts": "<iso8601>"
# }
```

Confirm the greppable journal line:

```bash
journalctl | grep '\[arlowe-audio\]'
# Expect: a line like: [arlowe-audio] selfcheck capture=ok playback=ok device=plughw:N,0
```

### 4b. selfcheck — capture failure

Unplug the USB mic (ensure no wm8960 capture path available, if testing total
failure). Or block the capture device by holding it open in another process.

```bash
PYTHONPATH=/opt/arlowe/runtime/lib python3 -m arlowe_audio --selfcheck
# Expect: JSON with capture.ok=false, error message present
# Expect: nonzero exit code
# Expect: [arlowe-audio] journal line with capture=FAIL
```

Verify that `arlowe-voice` remains active despite the selfcheck failure
(functional-degraded, locked decision: retry-then-report, never hard-block):

```bash
systemctl is-active arlowe-voice
# Expect: active
```

### 4c. boot-check integration

```bash
sudo boot-check
# Expect: "OK  Audio capture + playback sentinel" or "WARN Audio sentinel ..."
# In the HARDWARE section. No hardcoded plughw:2,0 probe.
```

The sentinel result in `/var/lib/arlowe/state/audio-selfcheck.json` is the
durable artifact Phase 11 will read; the boot-check line is the human echo.

---

## Hotplug (beyond SC1 locked decision — live service reconfigure)

With `arlowe-voice` running, plug a USB audio adapter:

```bash
# Watch the journal in one terminal:
journalctl -u arlowe-voice -f

# In another terminal, plug in the USB adapter.
# Expect: exactly ONE arlowe-voice restart (no restart storm)
# Expect: after restart, --resolve-capture returns the USB card
```

Unplug the adapter:

```bash
# Expect: exactly ONE arlowe-voice restart
# Expect: after restart, --resolve-capture returns the wm8960 fallback
```

The debounce in `provision/udev/92-arlowe-audio.rules` anchors on
`KERNEL=="controlC[0-9]*"` to prevent the multi-event storm (a single USB plug
fires control + pcm-capture + pcm-playback + timer events).

If more than one restart is observed per plug/unplug, the debounce anchor needs
adjustment — record the exact events with `udevadm monitor --subsystem-match=sound`
and update the rule.

---

## Confirm-on-hardware checklist (deferred unknowns from research)

These items cannot be verified without a real Pi running the Phase 5 runtime.
Check each one during the on-device run and record the findings.

- [ ] **Exact `sound` udev events on USB plug/unplug.** Run
  `udevadm monitor --subsystem-match=sound` while plugging in the USB adapter.
  Confirm which `KERNEL` names fire (expect `controlC*`, `pcmC*D*c`,
  `pcmC*D*p`, `timer`) and that `controlC[0-9]*` is the correct debounce
  anchor for a single restart per event. If a different anchor is needed,
  update `provision/udev/92-arlowe-audio.rules`.

- [ ] **`arecord -l` under dashboard `PrivateDevices=yes`.** The dashboard
  service unit has `PrivateDevices=yes` (`arlowe-dashboard.service:37`). The
  `/api/audio/devices` endpoint reads `/proc/asound` via the filesystem (not via
  device nodes), which should be unaffected. Confirm: `systemctl cat
  arlowe-dashboard | grep PrivateDevices` and then hit
  `http://localhost:3000/api/audio/devices` — expect a JSON response listing the
  correct cards. If the endpoint returns empty or errors, the fs-read path needs
  a fix; do not enable device nodes in the dashboard unit.

- [ ] **boot-check boot-time run-user and `/var/lib/arlowe/state` writability.**
  Confirm how `boot-check` is invoked at boot (which user, which sandbox), and
  that `/var/lib/arlowe/state/audio-selfcheck.json` is actually written.
  Run `ls -la /var/lib/arlowe/state/audio-selfcheck.json` after a reboot;
  if absent, check `boot-check`'s effective user and whether
  `/var/lib/arlowe/state` is writable from that context.

- [ ] **Production WM8960 soundcard name.** Run `cat /proc/asound/cards` and
  record the exact card-id for the WM8960 (expected to contain `wm8960`).
  Confirm that `arlowe_audio.py`'s `WM8960_MATCH = "wm8960"` substring matches.
  If the production image uses a different dtoverlay name (e.g. `wm8960soundcard`
  without a hyphen), the match still holds as long as `wm8960` appears in the id
  or longname.

- [ ] **`/dev/snd/by-id` contents.** Run `ls -l /dev/snd/by-id 2>/dev/null`.
  Expect "No such file or directory" or an empty directory. The Phase 5
  implementation stores the card-id token from `/proc/asound/card<N>/id`, not a
  by-id path, so this is informational. If by-id symlinks do exist, record the
  naming scheme; no code change is expected.

- [ ] **PortAudio/ALSA name-match for the wake-word stream.** With the USB mic
  plugged and `arlowe-voice` running (with SC1 satisfied), check the voice
  journal for a line confirming which PortAudio device index was selected for
  the wake-word stream. The library resolves via `portaudio_index_for_card()`
  by substring-matching the ALSA card id/longname against PortAudio device
  names. Confirm the match is correct (i.e. the wake-word mic and the
  arecord/STT mic are the same physical device). If the match fails (no
  substring overlap), the fallback is PortAudio's default device — which may
  or may not be the same card. Record the PortAudio device list
  (`PYTHONPATH=... python3 -c "import pyaudio; p=pyaudio.PyAudio(); [print(p.get_device_info_by_index(i)) for i in range(p.get_device_count())]"`)
  and update `portaudio_index_for_card()` if the name-match heuristic needs
  tuning.

---

## Deferral record

This run is **deferred** per the Phase 1/3/4 precedent. arlowe-1 (the dev daily
driver) has no `/opt/arlowe` arlowe-user layout with Phase 5 runtime installed,
so the on-device verification cannot run there without first completing Phase 6
(image build). The deferred checkpoint resumes at Phase 3-style staging, Phase 6
image integration, or Phase 12 first-flash — whichever is the first environment
with a fully provisioned Phase 5 runtime.

Outstanding hardware-confirm items carry forward to Phase 6/12 (see checklist above).

When the on-device run completes, record the results in
`.planning/phases/05-audio-device-auto-detection/05-07-SUMMARY.md`.
