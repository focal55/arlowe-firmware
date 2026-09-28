# Phase 8: First-boot pairing and wake word - Context

**Gathered:** 2026-09-28
**Status:** Ready for planning

<domain>
## Phase Boundary

A factory-fresh unit (no `/etc/arlowe/config.yml`) boots into a pairing daemon. The owner, from a phone or laptop with no app, gives it Wi-Fi credentials, a dashboard password and a device display name. The unit obtains its device certificate, writes the config overlay, enables and starts the six runtime units, and is reachable at `http://<name>.local:3000` behind that password. The generic "Hey Arlowe" wake model ships in the image. Factory reset returns the unit to pairing. Requirements: PAIR-01..07, WAKE-01..03, DASH-01, DASH-02.

Out of this phase: OTA (Phase 9), support access (Phase 10), dashboard health/activity/settings views beyond login and reset (Phase 11).

**Research predates Phase 7.1.** `08-RESEARCH.md` blockers B1-B4 (empty venvs, no dashboard build, missing PIL, verifier crash) are closed by 7.1 and proven on hardware (6/6 units active from build A's image, 2026-09-27). B5-B9 still stand and must be re-verified against current main, not assumed: SSH open with a default login (B5), polkit/shell-injection in the Wi-Fi routes (B6), slot B never booted (B7), boot-check reporting an unpaired device as broken (B9). B8 (volatile journal) is closed: the journal is persistent.

</domain>

<decisions>
## Implementation Decisions

### Setup channel and handoff
- **Setup Wi-Fi hotspot, not BLE.** The unpaired device runs a NetworkManager AP ("Arlowe-Setup-XXXX") with a captive setup page. No companion app. BLE is out of v1 (ADR records why: app or Web Bluetooth, which iOS browsers lack).
- **Optimistic handoff.** On submit the page answers first ("switching networks, find me at `<name>.local`"), then the device drops the AP and joins. The Whisplay carries progress from there. If the join fails, the AP **must** come back and show the error; a mistyped password must never strand the unit. Validate-then-commit is the rejected alternative, recorded in the ADR.
- **QR code on the Whisplay** encoding the setup network, so a camera scan joins it. Verify the QR package exists in the pinned Pi OS / Debian snapshot before declaring it; the package must be added to the image's package list in the same change.
- **Open hotspot, short-lived.** No WPA password; up only while unpaired. The claim code, not the hotspot, is what gates the certificate.

### Owner account and claim code
- **Device-local dashboard password + per-unit claim code.** The owner sets a password at pairing; it is hashed with Argon2id (library, not hand-rolled) and never leaves the device. DASH-02 is a from-scratch build: session cookie, login page, middleware on every mutating route.
- **Claim code gates the cert.** A per-unit code printed on the box card is exchanged at the broker for the CSR token. Device code stays token-agnostic (ADR-0007 contract); the broker gains a list lookup, which Phase 8 is allowed to add.
- **Claim codes: a script mints one per unit and appends it to the list the broker checks.** Single-use, revocable. Early units get hand-printed cards.
- **Forgotten password = factory reset.** No recovery path; the claim code is not a master key.
- **Cert step tested against a local broker with a stubbed IoT backend.** The real-cloud run is a separate owner-gated checkpoint that waits on the AWS staging account (same blocker as Phase 7's 07-09). Do not plan SC2 as "cert from production".
- Schema work is a prerequisite: `config/schema.yml` has no place for a display name, owner record, Wi-Fi label or wake toggle (`additionalProperties: false`). A daemon that writes an unknown key bricks the unit it just paired.
- The display name becomes the hostname: it must be validated so it cannot produce a banned literal (the sanitize gate) or an invalid hostname, and pairing must actually apply it (`hostnamectl`, `/etc/hosts`, avahi restart) so two units don't both answer as `arlowe.local`.

### Wake word model
- **Train our own "hey arlowe" openWakeWord model** off-device (Linux GPU box), ship the ONNX.
- **Owner decision, recorded as a known liability: the first shipping model is trained with the stock openWakeWord recipe (AudioSet / ACAV100M negatives), audit later.** These are the datasets that made openWakeWord's own models CC BY-NC-SA. The ADR must state plainly that units sold with this model carry that licensing risk, and that there is no field fix for them until model OTA exists (v1.1+; Phase 9 is app-only). An audited retrain is a deferred item, not a Phase 8 gate.
- **Acceptance bar:** >= 90% wake rate over 60 trials from 3 speakers whose voices were not in the training data, and <= 1 false wake per hour over a >= 1 h ambient session (TV/music/conversation), run with no personalization verifier present. Non-autonomous hardware checkpoint.
- **Fallback: change the phrase.** If "hey arlowe" misses the bar after the budgeted training cycles, switch to a pre-approved backup phrase that trains more reliably. The ADR records the go/no-go numbers.
- `hey_jarvis` (CC BY-NC) must be gone from every shipped code path by the end of the phase.

### Factory reset
- **New identity on reset, old cert revoked first.** Order: best-effort revoke of the current certificate while online; then wipe regardless; if the revoke failed, record the orphaned certificate ID durably for later cleanup. Preserving the identity across resets is the rejected alternative (ADR).
- **Three triggers:** dashboard button (authenticated), a long hold on the Whisplay's single button with an on-screen countdown and a confirming press (unauthenticated; physical access is the authorization), and the recovery SD card (documentation only; reflash). Not slot B: it has never booted.
- **Wipe the saved Wi-Fi profile** (NetworkManager system connections hold the PSK in plaintext). SC4 is amended to say so.
- **Survives a reset: only a reset audit line and orphaned cert IDs.** Wiped: config overlay, identity, conversations, wake-word personalization data, dashboard sessions/cache, runtime state, transcripts. Never touched: the read-only models partition.

### Claude's Discretion
- Hotspot timeout and what the unit does if nobody pairs.
- Setup page look and copy; Whisplay strings for the four SC3 failure modes (map them to `arlowe-identity`'s existing exit codes rather than a new taxonomy).
- Hold duration and countdown design for the button reset; how the reset listener shares the button with `arlowe-face`, which holds the GPIO chips.
- Session length and cookie details for the dashboard login.
- Whether to keep openWakeWord 0.4.0 on the device (it loads arbitrary ONNX) or upgrade it, decided explicitly in a plan.
- Where the orphaned-cert record lives, as long as it survives the wipe.

</decisions>

<specifics>
## Specific Ideas

- The pairing daemon runs after `arlowe-identity-init` and `arlowe-firstboot`, gated on the absence of `/etc/arlowe/config.yml`, not on the firstboot sentinel, so a reset returns to pairing on a unit that has already done first boot.
- On success it must `systemctl enable --now` the six units (not just `start`), or a paired unit comes up dead after a power cycle. The polkit rule for this already exists and names the pairing daemon in its comment.
- Every image-side Python import added in this phase ships its package in the same change, verified against the pinned archives. That class of miss is what bricked first boot before (verify against the declared image environment).
- Each SC3 failure mode needs a deliberate way to provoke it in tests: wrong PSK, broker unreachable, bad claim code, broker rejection.

</specifics>

<deferred>
## Deferred Ideas

- **Audited retrain of the wake model** with only commercially licensable data: replaces the stock-recipe model; reaches sold units only once model OTA exists.
- Bluetooth (BLE) provisioning or a companion app.
- Hosted owner accounts / account recovery; swapping the claim code for a real account token (the device side needs no change when this happens).
- Password recovery without a factory reset.
- Moving the personalization verifier to openWakeWord's built-in custom verifier (drops scikit-learn/joblib from the device): worth doing with WAKE-03 work, not required by this phase.

</deferred>

---

*Phase: 08-first-boot-pairing-and-wake-word*
*Context gathered: 2026-09-28*
