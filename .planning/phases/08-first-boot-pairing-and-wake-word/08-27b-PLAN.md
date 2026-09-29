---
phase: 08-first-boot-pairing-and-wake-word
plan: 27b
type: execute
wave: 7
depends_on: ["08-27a"]
files_modified:
  - docs/operations/phase-8-pairing.md
  - .planning/ROADMAP.md
  - .planning/REQUIREMENTS.md
autonomous: false

must_haves:
  truths:
    - "SC1: a freshly flashed unit with no config.yml runs arlowe-pair and none of the six runtime units, shows the waiting screen with SSID, password and QR on the Whisplay, and a phone that scans the QR joins the setup network and gets the captive setup page."
    - "SC2: submitting Wi-Fi, device name, dashboard password and claim code gets the unit a certificate from the local broker, writes config.yml, starts all six units, and the phone reaches http://<name>.local:3000, which asks for and accepts the pairing password."
    - "SC3: wrong Wi-Fi password, broker stopped, unminted claim code and broker issuance failure each show a different message on the Whisplay and on the page, and after each the setup network comes back and the unit holds no saved Wi-Fi profile."
    - "SC4: a reset from the dashboard and a reset from the button each end, after reboot, in pairing mode with no config.yml, a new device id, an emptied identity store and owner data, no saved Wi-Fi profile, a revoked old certificate (or an orphaned-cert record when offline), and one audit line."
    - "No pairing secret appears in the journal."
  artifacts:
    - path: "docs/operations/phase-8-pairing.md"
      provides: "hardware evidence for SC1-SC4"
      contains: "SC4"
  key_links:
    - from: "docs/operations/phase-8-pairing.md"
      to: ".planning/ROADMAP.md"
      via: "SC1-SC4 marked with named evidence"
      pattern: "Phase 8"
---

<objective>
Prove SC1-SC4 on hardware with the 08-27a image, following the 08-17 runbook, then close the phase records.

Purpose: the radio, the Whisplay, a real phone's captive-portal handling, avahi, polkit under a real systemd, and the reset's reboot cannot be proven anywhere else.

**Honest PR size: ~110 lines** (evidence in the runbook; `.planning` excluded).
- SC1-SC4 evidence blocks: 4 × 20 = 80
- runbook corrections the hardware forces: ~30

80 + 30 = 110.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@docs/operations/phase-8-pairing.md
@docs/architecture/0011-pairing-setup-channel.md
@docs/architecture/0013-factory-reset.md
@.planning/phases/08-first-boot-pairing-and-wake-word/08-27a-SUMMARY.md
</context>

<execution_notes>
- **Flash through the Mac's built-in SD slot with `scripts/flash-sd.sh`, which reads the whole card back.** Never the USB reader: it lands bulk writes 64 KiB low and bmaptool still reports OK (memory).
- The dev login is #200's path: `userconf.txt` plus the key in `/etc/skel`, and the `ssh` file on the FAT partition. The image ships no default login.
- Before booting, put `arlowe-broker.json` on the FAT partition with the dev machine's LAN URL and the stub CA (08-15 README). Start the local broker on the dev machine with `--stub-iot`, and mint two claim codes.
- Capture disconfirming evidence while at the hardware (memory): for every claim, run the command that would falsify it, with sudo where permissions could hide the truth, before writing the finding.
- Hardware-only checks carried from earlier plans: `lsmod | grep cfg80211` and `iw reg get` (08-08's modprobe assumption); `systemd-run --uid=arlowe --pipe nmcli general permissions` shows `yes` for the five granted actions (08-08); the brcmfmac reason code for a wrong PSK is 7, 8 or 11 (08-07); the radio-init unit's sysfs write works under its sandbox.
- If a defect needs a code fix, stop the checkpoint, fix it through a normal plan-sized PR, rebuild via 08-27a's Task 2 (without accept, which also proves the reference), and resume here.
</execution_notes>

<tasks>

<task type="auto">
  <name>Task 1: Flash, stage the FAT files, start the local broker</name>
  <files>(none; evidence only)</files>
  <action>Flash the 08-27a image per the runbook; confirm the read-back passed. Write `userconf.txt`, `ssh` and `arlowe-broker.json` to the FAT partition. Start the broker; mint codes A and B; record their hash prefixes (never the codes) in the evidence. Boot the unit on the bench with the Whisplay attached and an ethernet cable for the SSH session.</action>
  <verify>
    # flash-sd.sh exit 0 and its read-back line; broker log shows "listening"; `ssh` to the unit over ethernet succeeds
  </verify>
  <done>The unit is booting a verified card and the local broker is up.</done>
</task>

<task type="checkpoint:human-verify" gate="blocking">
  <name>Task 2: SC1-SC4 on hardware</name>
  <what-built>A Phase 8 image: pairing daemon, captive portal, Whisplay screens, certificate from the local broker, dashboard login, and factory reset from the dashboard and the button.</what-built>
  <how-to-verify>
Claude runs every command over SSH and records output; the owner does the phone and button steps.
1. **SC1.** `systemctl is-active arlowe-pair` → active; `systemctl show -p ConditionResult arlowe-face arlowe-dashboard` → `no`; `sudo boot-check` → READY TO PAIR. Owner: the Whisplay shows the SSID, the password and a QR; scan the QR with an iPhone camera → it joins and the captive sheet opens the setup page. Repeat on an Android phone.
2. **SC3 (run before SC2, from the pairing state).** Provoke each of the four failures per the runbook table, in order: wrong Wi-Fi password, broker stopped, unminted claim code, broker restarted with `--stub-fail issuance`. For each: the Whisplay message, the page message after rejoining the setup network with the same password, and `nmcli -t -f TYPE connection show | grep -c 802-11-wireless` → 0. The four messages must differ. Restore the broker to normal afterwards.
3. **SC2.** From the last SC3 error, correct the form and resubmit (this also proves recovery without a power cycle). Owner submits home Wi-Fi, name "Kitchen Test", a dashboard password, code A. Whisplay: connecting → provisioning → paired with `http://kitchen-test.local:3000` and an IP. Claude: `test -f /etc/arlowe/config.yml`; `hostnamectl --static` → `kitchen-test`; all six `active`; `arlowe-identity status --json` shows a certificate. Owner: the phone opens the URL, sees the login page, logs in with the password, sees the dashboard. Claude: the journal secret grep from the runbook → 0.
4. **SC4.**
   a. Dashboard reset (password re-entry). After the reboot: pairing mode; `config.yml` absent; `cat /var/lib/arlowe/identity/device-id` differs from before; identity store has no `device.crt`; `sudo ls -A /var/lib/arlowe/conversations` empty; no Wi-Fi profile; `sudo tail -1 /var/lib/arlowe/reset-ledger/resets.log` → `trigger: dashboard, revoke: ok`; broker log shows the revoke and the claim store shows code A `unused`.
   b. Pair again with code A (proves the release). Then the button: hold 10 s (countdown from 3 s, LED red), release, press within 5 s. Same checks, `trigger: button`.
   c. Offline reset: pair with code B, stop the broker, reset from the dashboard. `orphaned-certs.jsonl` gains a line; `resets.log` says `revoke: failed`; the unit still lands in pairing.
   d. Recovery SD: documentation only; confirm the runbook section reads correctly.
5. The hardware-only checks from the execution notes.
  </how-to-verify>
  <resume-signal>Type "approved" with any observations, or describe what failed</resume-signal>
</task>

<task type="auto">
  <name>Task 3: Record the evidence and close the phase records</name>
  <files>docs/operations/phase-8-pairing.md, .planning/ROADMAP.md, .planning/REQUIREMENTS.md</files>
  <action>Write the SC1-SC4 evidence blocks verbatim (commands and outputs, redacting nothing but secrets, which never appear). Correct the runbook wherever the hardware disagreed. ROADMAP Phase 8: mark SC1-SC4 with named evidence and tick 08-01 through 08-27b; leave 08-28 open with its blocker. REQUIREMENTS: mark PAIR-01..07, DASH-01, DASH-02 complete, noting that the certificate came from the local broker and the real-cloud run is 08-28. Run the sanitize gate.</action>
  <verify>
    grep -c 'SC4' docs/operations/phase-8-pairing.md       # expect: >= 1
    scripts/sanitize/check.sh --grep-only
    git diff --shortstat main -- . ':(exclude).planning/**' # expect: ~110
  </verify>
  <done>Every SC has hardware evidence in the runbook, and the records say exactly what was and was not proven.</done>
</task>

</tasks>

<verification>
- The evidence covers each truth in must_haves; anything not observed is written as not observed.
</verification>

<success_criteria>
Phase 8's SC1-SC4 are proven on hardware against the local broker.
</success_criteria>

<output>
After completion, create `.planning/phases/08-first-boot-pairing-and-wake-word/08-27b-SUMMARY.md`.
</output>
