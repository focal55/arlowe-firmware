# 05-05 Summary: udev hotplug rule — debounced arlowe-voice restart

**Completed:** 2026-06-13
**PR:** feat/05-05-udev-audio-hotplug (Closes #92)
**Security note:** package:security — reviewed by Opus per label contract.

---

## What was built

`provision/udev/92-arlowe-audio.rules` — a udev rule that restarts
`arlowe-voice.service` on USB audio device add/remove, so the arlowe_audio
resolver (05-01) re-picks the device on the running system.

`tests/docker/phase-5-hotplug/test-udev-rule.sh` — a CI-runnable shape test
that verifies rule scope, debounce anchor, `--no-block`, target unit, and
install shape without real hardware.

---

## Rule scope and anchor

```
SUBSYSTEM=="sound", KERNEL=="controlC[0-9]*", ACTION=="add",    RUN+="/bin/systemctl --no-block restart arlowe-voice.service"
SUBSYSTEM=="sound", KERNEL=="controlC[0-9]*", ACTION=="remove", RUN+="/bin/systemctl --no-block restart arlowe-voice.service"
```

- **SUBSYSTEM=="sound"** — strictly scoped, not a broad device match.
- **KERNEL=="controlC[0-9]*"** — the debounce anchor. A single USB audio plug
  fires multiple kernel sound sub-events (controlC*, pcmC*D*c, pcmC*D*p, timer).
  Anchoring on the control node fires exactly once per card add/remove, not once
  per sub-node. Avoids a restart storm from a single physical plug.
- **RUN+="/bin/systemctl --no-block restart arlowe-voice.service"** — `--no-block`
  returns immediately; mandatory to avoid the udev<->systemd deadlock where udev
  waits for the unit transaction and systemd needs udev to settle devices.

---

## Install glob

`scripts/provision/install-arlowe-udev-polkit.sh` line 42 installs
`provision/udev/*.rules` to `/etc/udev/rules.d/` with mode 0644. The `92-`
prefix follows existing `90-`/`91-` numbering; no script edit required.

---

## v1 mechanism and known trade-off

The rule is a thin trigger — device-selection logic is entirely in arlowe_audio
(05-01). The mechanism is a full service restart, reusing the Phase 4 restart
pattern. An in-process reconfigure (SIGHUP or D-Bus signal) is a future
optimization and is not in scope here.

**Known trade-off (Pitfall P5):** a restart mid-recording aborts an in-flight
interaction. Acceptable for v1 because a hotplug event is inherently disruptive
(the device itself changed); the consistent restart behavior is easier to reason
about than a partial-reconfigure path.

---

## systemctl path assumption

The rule uses `/bin/systemctl`. Pi OS provides `/bin/systemctl` as a symlink to
`/usr/bin/systemctl`. If the target image ever loses that symlink, plan 05-07's
real-hardware verification step should confirm the path.

---

## Deferred: hardware confirmation (plan 05-07)

The exact sound events fired by this Pi's USB adapter and whether `controlC*`
is the correct anchor must be confirmed with `udevadm monitor --subsystem-match=sound`
on real hardware (research Open Q2). The controlC anchor is the standard Linux
ALSA event model and is correct by construction, but multi-sub-event behavior
can vary across USB audio class drivers and kernel versions.

---

## Shape test evidence (CI, no hardware)

```
=== Phase 5 hotplug rule shape test ===
  SKIP: udevadm not available — skipping syntax verification (acceptable in CI without udev)
  PASS: rule is scoped to SUBSYSTEM=="sound"
  PASS: rule uses --no-block
  PASS: rule anchored on controlC* (debounce: one restart per card, not per pcm sub-node)
  PASS: rule does not match pcmC* sub-nodes (debounce intact)
  PASS: rule targets arlowe-voice.service
  PASS: no non-arlowe-* unit referenced in RUN+= lines
  PASS: install glob places 92-arlowe-audio.rules at expected path
  PASS: installed file has mode 0644
  PASS: filename 92-arlowe-audio.rules matches installer glob 9?-arlowe-*.rules

=== Results: 9 passed, 0 failed ===
=== PASS ===
```
