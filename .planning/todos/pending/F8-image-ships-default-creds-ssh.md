# F8 — "Sanitized" image ships default pi/raspberry credentials + SSH enabled

**SEVERITY: HIGH (security).** Found 2026-07-09 during the Phase 6 hardware checkpoint, inspecting the first successfully-built image.

## Finding

`pi-gen/config` (committed) bakes, unconditionally:

```
FIRST_USER_NAME="pi"
FIRST_USER_PASS="raspberry"
ENABLE_SSH=1
```

So every image — including a production customer unit — boots with the **default Raspberry Pi login `pi`/`raspberry` AND SSH enabled**. Verified in the built rootfs: the `pi` user (uid 1000, `/bin/bash`) has an unlocked, usable password; `root` and `arlowe` are locked.

This directly contradicts the product thesis (sanitized, no founder identity, privacy/security as the differentiator). Anyone on the same network as a customer unit could `ssh pi@arlowe.local` with `raspberry`.

## Why it slipped through

- The Phase 2 sanitization gate greps for **founder literals** (`focal55`, `arlowe-1`, ...) but does NOT check for **default/weak credentials** or **SSH-enabled + password-auth**. Default creds are not a founder literal, so the gate is blind to them.
- No dev-vs-production gating in `pi-gen/config` — the same creds ship everywhere.

## Fix shape (before any real customer image)

- Remove the baked default password; do not enable password SSH by default. Options: SSH off until pairing; or key-only; or first-boot forces credential set during pairing (Phase 8).
- If a login is needed for dev/checkpoint images, gate it behind an explicit dev flag that production builds cannot set, and make the gate/CI fail if a production image has `pi`/`raspberry` or password-auth SSH.
- Extend the sanitization/security gate (Phase 2 / Phase 10 territory) to fail on default credentials and insecure SSH config.

## Checkpoint use (2026-07-09)

For THIS checkpoint we intentionally USE the `pi`/`raspberry` login to observe the boot (HDMI console, or SSH if arlowe-1 is put on ethernet), since the image has no other access path. That's a checkpoint convenience, not an endorsement — the finding stands.

Related: Phase 2 sanitization gate; Phase 8 pairing (credential setup); Phase 10 support-access SSH model. See [[F7-stage-arlowe-never-validated]].
</content>
