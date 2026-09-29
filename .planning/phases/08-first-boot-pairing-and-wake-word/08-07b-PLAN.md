---
phase: 08-first-boot-pairing-and-wake-word
plan: 07b
type: tdd
wave: 2
depends_on: ["08-07"]
files_modified:
  - runtime/pair/netman.py
  - runtime/pair/tests/fixtures/fake-nmcli
  - runtime/pair/tests/test_netman_join.py
autonomous: true

must_haves:
  truths:
    - "Joining the home network never puts the PSK in argv: the join profile is created without it and brought up with `passwd-file /dev/stdin`."
    - "A failed join is classified as wifi_rejected or wifi_not_found from NetworkManager's reason code, and the half-made profile is deleted so NetworkManager cannot retry a wrong password forever."
    - "A successful join leaves one system-owned profile (psk-flags 0), so NetworkManager keeps the PSK it received for later boots."
  artifacts:
    - path: "runtime/pair/netman.py"
      provides: "NetMan.join and saved_ssid_profile"
      contains: "def join"
    - path: "runtime/pair/tests/test_netman_join.py"
      provides: "join classification and argv-secret cases"
  key_links:
    - from: "runtime/pair/netman.py"
      to: "nmcli connection up <ssid> passwd-file /dev/stdin"
      via: "runner(argv, input=psk line)"
      pattern: "passwd-file"
---

<objective>
Add the home-network join to `NetMan`: create the profile without the secret, bring it up with the PSK on stdin, classify failures, and delete what a failure leaves behind (research Pattern 3; ADR-0011 "Secrets never in argv").

Purpose: SC2's join and SC3's "wrong Wi-Fi password". Split from 08-07 to keep both PRs under 400 lines. 08-13 fakes `net`, so it does not wait for this plan; 08-23 and 08-26 use the real join.

**Honest PR size: ~165 lines.**
- netman.py: 55 (join: `connection add` without secret 12, `connection up … passwd-file /dev/stdin` 8, open-network branch 5, reason-code classification 15, delete on failure 5; saved_ssid_profile 10)
- fake-nmcli: 20 (join scenario: a `correct_psk` compared with the passwd-file value, or a scripted `{exit, stderr}`; a successful join records `psk_flags: 0` and `secret_supplied`)
- tests: 90 (7 cases)

55 + 20 + 90 = 165.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@docs/architecture/0011-pairing-setup-channel.md
@runtime/pair/netman.py
@runtime/pair/errors.py
@runtime/pair/tests/fixtures/fake-nmcli
</context>

<execution_notes>
- `join(ssid, psk)`:
  1. `nmcli connection add type wifi ifname wlan0 con-name <ssid> ssid <ssid> autoconnect yes` plus, when `psk` is non-empty, `wifi-sec.key-mgmt wpa-psk wifi-sec.psk-flags 0` (no `wifi-sec.psk`).
  2. `nmcli --wait 45 connection up <ssid> passwd-file /dev/stdin` with `input=b"802-11-wireless-security.psk:" + psk + b"\n"`; for an empty psk, no `passwd-file` pair and no stdin.
  3. On failure: delete the connection named `<ssid>`, raise `JoinError(kind)`.
- `psk-flags 0` makes the secret system-owned, so NetworkManager stores the PSK the passwd-file supplied. MEDIUM confidence; 08-27b checks `sudo grep -c '^psk=' /etc/NetworkManager/system-connections/<ssid>.nmconnection` → 1 and a reboot rejoin. If hardware shows it does not persist, stop and fix through a plan-sized PR; do not fall back to argv.
- Reason codes: `7`, `8`, `11` → `wifi_rejected`; `53` or "No network with SSID" → `wifi_not_found`; anything else → `wifi_failed`. The code is in nmcli's stderr as `(N)`. Mark the brcmfmac mapping MEDIUM in a comment; 08-27b confirms it.
- `saved_ssid_profile(ssid)` deletes a saved profile after a later failure (the invariant: an unpaired unit has no saved networks).
</execution_notes>

<feature>
  <name>Home-network join</name>
  <files>runtime/pair/netman.py, runtime/pair/tests/test_netman_join.py</files>
  <behavior>
    - Join success: the fake's state holds one profile named `<ssid>` with `secret_supplied` and `psk_flags: 0`; the `up` argv ends with `passwd-file /dev/stdin`.
    - `test_no_secret_in_argv`: across a successful and a failed join, no argv line in the log contains the psk.
    - Wrong PSK (fake `correct_psk` differs; stderr `(7)`) → `JoinError(wifi_rejected)`, profile gone from state.
    - `(53)` → `wifi_not_found`, profile gone. `(3)` → `wifi_failed`, profile gone.
    - Open network (empty psk): no `wifi-sec` keys, no `passwd-file`, no stdin.
    - `saved_ssid_profile(ssid)` removes a profile left by a successful join.
    - caplog contains no psk.
  </behavior>
  <implementation>Extend `NetMan`; reuse its runner and logging.</implementation>
</feature>

<tasks>

<task type="auto">
  <name>Task 1: Join scenario and cases (RED)</name>
  <files>runtime/pair/tests/fixtures/fake-nmcli, runtime/pair/tests/test_netman_join.py</files>
  <action>Add the join scenario to the fake (document the keys in its header next to 08-07's). Write one case per behaviour bullet. Run: fails (`NetMan` has no `join`).</action>
  <verify>
    PYTHONPATH=runtime:runtime/lib python3 -m pytest runtime/pair/tests/test_netman_join.py -q; echo "rc=$?"   # expect: failures
  </verify>
  <done>Cases fail because join does not exist; 08-07's cases still pass.</done>
</task>

<task type="auto">
  <name>Task 2: join (GREEN)</name>
  <files>runtime/pair/netman.py</files>
  <action>Implement per the notes.</action>
  <verify>
    PYTHONPATH=runtime:runtime/lib python3 -m pytest runtime/pair/tests -q     # expect: all pass
    git diff --shortstat main -- . ':(exclude).planning/**'                     # expect: ~165
  </verify>
  <done>The unit can join a home network without the PSK ever reaching argv, and every failure is classified and cleaned up.</done>
</task>

</tasks>

<verification>
- Passes in `pair-bookworm`.
</verification>

<success_criteria>
SC3's wrong-password case has a distinct kind, and the join leaks no secret into argv or logs.
</success_criteria>

<output>
After completion, create `.planning/phases/08-first-boot-pairing-and-wake-word/08-07b-SUMMARY.md`.
</output>
