# Phase 8: First-boot pairing and wake word - Context

**Gathered:** 2026-09-28 (revised the same day after the research refresh)
**Status:** Ready for planning

<domain>
## Phase Boundary

**Scope revised after research: the wake word (WAKE-01..03, SC5) moved to the inserted Phase 8.1.** Phase 8 is pairing, dashboard auth and factory reset. **Security prerequisite: #200** (every image ships `pi`/`raspberry` with passwordless sudo and SSH on) is fixed in a standalone PR before any Phase 8 plan executes; Phase 8 plans assume it has landed.

A factory-fresh unit (no `/etc/arlowe/config.yml`) boots into a pairing daemon. The owner, from a phone or laptop with no app, gives it Wi-Fi credentials, a dashboard password and a device display name. The unit obtains its device certificate, writes the config overlay, enables and starts the six runtime units, and is reachable at `http://<name>.local:3000` behind that password. The generic "Hey Arlowe" wake model ships in the image. Factory reset returns the unit to pairing. Requirements: PAIR-01..07, DASH-01, DASH-02 (WAKE-01..03 are Phase 8.1).

Out of this phase: OTA (Phase 9), support access (Phase 10), dashboard health/activity/settings views beyond login and reset (Phase 11).

**Research predates Phase 7.1.** `08-RESEARCH.md` blockers B1-B4 (empty venvs, no dashboard build, missing PIL, verifier crash) are closed by 7.1 and proven on hardware (6/6 units active from build A's image, 2026-09-27). B5-B9 still stand and must be re-verified against current main, not assumed: SSH open with a default login (B5), polkit/shell-injection in the Wi-Fi routes (B6), slot B never booted (B7), boot-check reporting an unpaired device as broken (B9). B8 (volatile journal) is closed: the journal is persistent.

</domain>

<decisions>
## Implementation Decisions

### Setup channel and handoff
- **Setup Wi-Fi hotspot, not BLE.** The unpaired device runs a NetworkManager AP ("Arlowe-Setup-XXXX") with a captive setup page. No companion app. BLE is out of v1 (ADR records why: app or Web Bluetooth, which iOS browsers lack).
- **Optimistic handoff.** On submit the page answers first ("switching networks, find me at `<name>.local`"), then the device drops the AP and joins. The Whisplay carries progress from there. If the join fails, the AP **must** come back and show the error; a mistyped password must never strand the unit. Validate-then-commit is the rejected alternative, recorded in the ADR.
- **QR code on the Whisplay** encoding the setup network, so a camera scan joins it. Verify the QR package exists in the pinned Pi OS / Debian snapshot before declaring it; the package must be added to the image's package list in the same change.
- **WPA2 hotspot with a fresh random password per pairing session** (revised: the owner first chose open, then reversed it once research showed the home Wi-Fi password, dashboard password and claim code would cross an open network in cleartext). The password is generated each time the unit enters pairing, shown on the Whisplay and encoded in the QR code (`WIFI:T:WPA;S:...;P:...;;`), never printed or stored after pairing. Up only while unpaired.
- **Research found the six units already enabled at build time** (`units/install-units.sh`), so they run on an unpaired device, `arlowe-face` holds the Whisplay GPIO, and the unauthenticated dashboard would face the setup network. Gate the six on `/etc/arlowe/config.yml` existing and make writing it the single commit point; pairing then starts them (the "enable --now" specific below is superseded).

### Owner account and claim code
- **Device-local dashboard password + per-unit claim code.** The owner sets a password at pairing; it is hashed with Argon2id (library, not hand-rolled) and never leaves the device. DASH-02 is a from-scratch build: session cookie, login page, middleware on every mutating route.
- **Claim code gates the cert.** A per-unit code printed on the box card is exchanged at the broker for the CSR token. Device code stays token-agnostic (ADR-0007 contract); the broker gains a list lookup, which Phase 8 is allowed to add.
- **Claim codes: a script mints one per unit and appends it to the list the broker checks.** Revocable. Early units get hand-printed cards.
- **A claim code is bound to the unit on first use; a factory reset's revoke call releases the binding** so the same card works for the next owner. A stolen card cannot claim a unit that is already paired. (Supersedes "single-use".)
- **Forgotten password = factory reset.** No recovery path; the claim code is not a master key.
- **Cert step tested against a local broker with a stubbed IoT backend.** The real-cloud run is a separate owner-gated checkpoint that waits on the AWS staging account (same blocker as Phase 7's 07-09). Do not plan SC2 as "cert from production".
- Schema work is a prerequisite: `config/schema.yml` has no place for a display name, owner record, Wi-Fi label or wake toggle (`additionalProperties: false`). A daemon that writes an unknown key bricks the unit it just paired.
- The display name becomes the hostname: it must be validated so it cannot produce a banned literal (the sanitize gate) or an invalid hostname, and pairing must actually apply it (`hostnamectl`, `/etc/hosts`, avahi restart) so two units don't both answer as `arlowe.local`.

### Wake word model
**Moved to Phase 8.1.** The decisions recorded for it stand and carry over unchanged: own "hey arlowe" openWakeWord model trained off-device; the first shipping model uses the stock recipe with the licensing liability recorded in its ADR (research adds that the negative-feature dataset is itself CC BY-NC-SA 4.0); acceptance bar >= 90% over 60 trials from 3 unseen voices and <= 1 false wake/hour; fallback is a pre-approved backup phrase; `hey_jarvis` leaves every shipped path. Research recommends upgrading the device to openWakeWord 0.6.0 (its wheel ships no models; 0.4.0's puts six non-commercial models into every image).

### Factory reset
- **New identity on reset, old cert revoked first.** Order: best-effort revoke of the current certificate while online; then wipe regardless; if the revoke failed, record the orphaned certificate ID durably for later cleanup. Preserving the identity across resets is the rejected alternative (ADR).
- **Three triggers:** dashboard button (authenticated), a long hold on the Whisplay's single button with an on-screen countdown and a confirming press (unauthenticated; physical access is the authorization), and the recovery SD card (documentation only; reflash). Not slot B: it has never booted.
- **Wipe the saved Wi-Fi profile** (NetworkManager system connections hold the PSK in plaintext). SC4 is amended to say so.
- **Survives a reset: only a reset audit line and orphaned cert IDs.** Wiped: config overlay, identity, conversations, wake-word personalization data, dashboard sessions/cache, runtime state, transcripts. Never touched: the read-only models partition.

### Claude's Discretion
- Wi-Fi regulatory country: the radio ships disabled until one is set, and the AP needs it before setup. Default for v1 at build time; the planner picks and records it.
- Hotspot timeout and what the unit does if nobody pairs.
- Setup page look and copy; Whisplay strings for the four SC3 failure modes (map them to `arlowe-identity`'s existing exit codes rather than a new taxonomy).
- Hold duration and countdown design for the button reset; how the reset listener shares the button with `arlowe-face`, which holds the GPIO chips.
- Session length and cookie details for the dashboard login.
- Where the orphaned-cert record lives, as long as it survives the wipe.

</decisions>

<specifics>
## Specific Ideas

- The pairing daemon runs after `arlowe-identity-init` and `arlowe-firstboot`, gated on the absence of `/etc/arlowe/config.yml`, not on the firstboot sentinel, so a reset returns to pairing on a unit that has already done first boot.
- On success the six units start (they are gated on `config.yml`, which pairing writes last as the commit point). The polkit rule allowing this already exists and names the pairing daemon in its comment.
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
