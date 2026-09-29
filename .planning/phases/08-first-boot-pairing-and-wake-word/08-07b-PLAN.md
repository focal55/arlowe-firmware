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
    - "Joining the home network never puts the PSK in argv: the join profile is created without it, with a daemon-generated `connection.uuid`, and brought up with `connection up uuid <uuid> passwd-file /dev/stdin`; failure cleanup deletes by uuid."
    - "Any PSK the owner can type arrives at NetworkManager unchanged: the passwd-file line is escaped to NetworkManager 1.42.4's parser rules, and the fake parses with the same rules, so a PSK with leading/trailing spaces, a backslash, a colon and a hash round-trips."
    - "An SSID that looks like an nmcli option (`-id`) is joined and cleaned up correctly, because no nmcli call addresses the profile by name."
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

**Honest PR size: ~251 lines.**
- netman.py: 76 (`passwd_line(key, value)` escaper 14 and `ap_up` routed through it 1; join: uuid4 and `connection add` without secret 14, `connection up uuid … passwd-file /dev/stdin` 8, open-network branch 5, reason-code classification 15, delete by uuid on failure 5; saved_ssid_profile via the recorded uuid 14)
- fake-nmcli: 50 (a port of NetworkManager 1.42.4's passwd-file parser replacing 08-07's plain split 30; join scenario: a `correct_psk` compared with the parsed value, or a scripted `{exit, stderr}`; a successful join records `psk_flags: 0` and `secret_supplied` 20)
- tests: 125 (10 cases)

76 + 50 + 125 = 251.
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
  1. `u = str(uuid.uuid4())`; `nmcli connection add type wifi ifname wlan0 con-name <ssid> connection.uuid <u> ssid <ssid> autoconnect yes` plus, when `psk` is non-empty, `wifi-sec.key-mgmt wpa-psk wifi-sec.psk-flags 0` (no `wifi-sec.psk`). Values after a property name in `connection add` are read literally by nmcli 1.42 (`get_value` in `src/nmcli/connections.c`), so `con-name -id` and `ssid -id` are safe there; the con-name stays the SSID so the keyfile is `<ssid>.nmconnection` (08-27b's persistence check).
  2. `nmcli --wait 45 connection up uuid <u> passwd-file /dev/stdin` with `input=passwd_line("802-11-wireless-security.psk", psk)`; for an empty psk, no `passwd-file` pair and no stdin. Never `connection up <ssid>`: a positional name goes through nmcli's `next_arg`, which consumes `-a`/`--ask`/`-s`/`--show-secrets`-shaped words as global options (`parse_global_arg`, `src/nmcli/utils.c`, tag 1.42.4).
  3. On failure: `nmcli connection delete uuid <u>`, raise `JoinError(kind)`. On success record `self._join_uuids[ssid] = u`.
- **`passwd_line(key, value)` (W2).** Rules pinned in 08-07's notes from NetworkManager tag `1.42.4` (`nmc_utils_parse_passwd_file`, `nm_utils_buf_utf8safe_unescape` with `STRIP_SPACES`), matching the image's `network-manager 1.42.4-1+rpt1+deb12u1`. Raise `ValueError` for `\r`, `\n` or `\0` in the value (a raw line break ends the line; the portal's validation already refuses them). Otherwise write every `\` as `\\`, every space as `\ `, every tab as `\t`, and return `(key + ":" + escaped + "\n").encode()`. Escaping every space, not just the ends, keeps the rule trivially correct; `:`, `=` and `#` need no escape because the key ends at the first `:` and `#` is a comment only as a line's first non-space character. `ap_up` uses it too (its alphabet makes it a no-op).
- **The fake's reader (W2).** Replace 08-07's split with a port of the two C functions: split lines on `\r\n`, `\r` or `\n`; skip a line whose first non-space character is `#` or that is empty; key up to the first `:` or `=`; value with leading whitespace stripped, then unescaped (`\\`, `\b \f \n \r \t \v`, octal `\N`, `\NN`, `\NNN` with the first digit 0-9 and later digits 0-7, any other `\c` → `c`, trailing lone `\` dropped), then the unescaped trailing whitespace of the final literal run stripped. Cite the tag and both source files in the header. A value that fails UTF-8 validation is an error, as in NetworkManager.
- `psk-flags 0` makes the secret system-owned, so NetworkManager stores the PSK the passwd-file supplied. MEDIUM confidence; 08-27b checks `sudo grep -c '^psk=' /etc/NetworkManager/system-connections/<ssid>.nmconnection` → 1 and a reboot rejoin. If hardware shows it does not persist, stop and fix through a plan-sized PR; do not fall back to argv.
- Reason codes: `7`, `8`, `11` → `wifi_rejected`; `53` or "No network with SSID" → `wifi_not_found`; anything else → `wifi_failed`. The code is in nmcli's stderr as `(N)`. Mark the brcmfmac mapping MEDIUM in a comment; 08-27b confirms it.
- `saved_ssid_profile(ssid)` deletes a saved profile after a later failure (the invariant: an unpaired unit has no saved networks). It keeps its signature (08-13 calls it with the SSID) and deletes by the uuid recorded at join time (`connection delete uuid <u>`), tolerating "not found".
- **Fallback, never argv (W4, ADR-0011).** If 08-27b shows the PSK does not persist, check polkit `settings.modify.system` first (it is load-bearing: without it NetworkManager cannot store a system-owned secret); if the passwd-file path itself is the problem, the fallback is in-process libnm, gated as in 08-07's notes.
</execution_notes>

<feature>
  <name>Home-network join</name>
  <files>runtime/pair/netman.py, runtime/pair/tests/test_netman_join.py</files>
  <behavior>
    - Join success: the fake's state holds one profile named `<ssid>` with `secret_supplied` and `psk_flags: 0`; the add argv carries `connection.uuid <uuid4>`; the `up` argv is `… connection up uuid <that uuid> passwd-file /dev/stdin`.
    - `test_adversarial_psk_round_trips`: PSK `" a\\b:#c "` (Python literal: space, `a`, one backslash, `b:#c`, space) joins successfully against a fake whose `correct_psk` is that exact string, i.e. the fake's NetworkManager-exact parser recovered it unchanged; `passwd_line` of it equals `b"802-11-wireless-security.psk:\\ a\\\\b:#c\\ \n"`; and `passwd_line` raises on a value containing `\n`.
    - `test_dash_ssid`: SSID `-id` joins (the add argv has `-id` right after `con-name` and right after `ssid`); a failed join with SSID `-id` deletes by `uuid`; no `up` or `delete` argv contains `-id` as a selector.
    - `test_no_secret_in_argv`: across a successful and a failed join, no argv line in the log contains the psk.
    - Wrong PSK (fake `correct_psk` differs; stderr `(7)`) → `JoinError(wifi_rejected)`, profile gone from state.
    - `(53)` → `wifi_not_found`, profile gone. `(3)` → `wifi_failed`, profile gone.
    - Open network (empty psk): no `wifi-sec` keys, no `passwd-file`, no stdin.
    - `saved_ssid_profile(ssid)` removes a profile left by a successful join, by uuid.
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
    git diff --shortstat main -- . ':(exclude).planning/**'                     # expect: ~251
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
