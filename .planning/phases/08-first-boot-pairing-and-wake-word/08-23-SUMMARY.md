---
phase: 08-first-boot-pairing-and-wake-word
plan: 23
subsystem: pairing
tags: [pairing, daemon, networkmanager, whisplay, portal]
requires:
  - phase: 08-07b
    provides: NetMan, fake nmcli
  - phase: 08-11
    provides: Display, Screen
  - phase: 08-12
    provides: portal.make_server
  - phase: 08-13
    provides: PairingFlow
  - phase: 08-18
    provides: arlowe_broker.resolve_broker
  - phase: 08-20
    provides: Committer, start_runtime
provides:
  - pair.app.build_app / PairApp; `python3 -m pair`
  - NetMan.ipv4_address(); Screen.error(kind, detail="")
affects: [08-25 pairing unit, 08-27b hardware checkpoint]
key-files:
  created: [runtime/pair/app.py, runtime/pair/__main__.py, runtime/pair/tests/test_app.py]
  modified: [runtime/pair/netman.py, runtime/pair/display.py, runtime/pair/tests/fixtures/fake-nmcli]
key-decisions:
  - "A new PairingFlow per setup session; the portal server and its state dict are kept across sessions"
  - "The URL slug comes from the submitted form's slug (the committer re-derives the same one)"
  - "The home IP is looked up when the flow enters provisioning (the join is up) and becomes the portal's ip_hint for a retry"
duration: 40min
completed: 2026-09-29
---

# Phase 8 Plan 23: Pairing Daemon Summary

**`python3 -m pair` runs the whole pairing flow. It deletes stale Wi-Fi profiles, turns the radio on, scans, raises the WPA2 setup AP with a per-session password, and binds the portal to 10.42.0.1:80 after the first `ap_up`. After 30 idle minutes it drops the AP, and a button press starts a new session. The broker is resolved at each submission. After pairing: the paired screen with URL and IP, a 30 s or button-press hold, `display.close()`, then `start_runtime()` in a `finally`, and exit 0.**

## Tasks
1. RED: 10 cases, with the fake nmcli and a real PairingFlow (93842d3)
2. GREEN: app.py, __main__.py (48a13a0); test tightening (refactor commit)

## Deviations from Plan
- **[Rule 3] NetMan.ipv4_address() and fake-nmcli `-g IP4.ADDRESS device show`** (scenario key `ip4`). The plan asks for the IP "from the nmcli shim", and NetMan's runner is private, so the lookup went into netman.py.
- **[Rule 2] Screen.error(kind, detail="")**. 08-11's error screen had no detail line, and the plan needs "Device identity missing" on the Whisplay.
- **The paired screen is drawn by the daemon.** The flow's own `show("paired")` goes to an adapter that drops it, because only the daemon knows the URL and IP. "committing" needed no mapping: 08-11 draws it.
- **broker_source reads identity.provisioning_url at call time**, not once at startup. It runs `arlowe_config.load()` at each submission.
- **Setup-network failure (NetManError in radio/ap_up) shows the idle screen**, so a button press retries. A scan failure is logged and the daemon continues with no networks listed.
- A failed paired draw propagates the exception after `start_runtime()` runs, so the process exits non-zero. That is harmless: config.yml is committed, so the unit's condition is now false.

## Verification
- bookworm container with the image's package set: `runtime/pair/tests tests/phase-8`: 164 passed, 2 skipped. test_app.py ran 5 times with no flakes. `import pair.__main__` does not serve.
- Needs hardware (08-27b): whether the socket keeps listening across AP down/up, the real button callback, and `timedatectl` output.
