# ADR-0013: Factory reset — new identity, revoke first, one commit point

<!-- status: accepted -->
**Status:** Accepted (owner decisions of 2026-09-28)
**Date:** 2026-09-28
**Phase:** 8 (First-boot pairing, PAIR reset)
**Hardware validation:** plan 08-27b

## Context

Reset must return a unit to the state pairing expects (ADR-0011): no `/etc/arlowe/config.yml`,
no saved Wi-Fi profile, no owner data. It also has to hand the unit to a new owner without
carrying the old owner's cloud binding.

Constraints:

- **A power cut can land at any step.** A half-wiped unit that is neither paired nor pairable is
  the failure to design out.
- **NetworkManager keyfiles hold the home PSK in plaintext.** The saved Wi-Fi profile must go.
- **The journal holds transcripts.** It lives on owner state (`/var/lib/arlowe/journal`).
- **There is no device-initiated revoke today.** `scripts/pki/revoke.sh` is an operator AWS call
  and `arlowe-identity reset` is offline. Revoke needs the network, and a reset often runs
  because the network is broken.
- **Slot B has never booted** (research B7).

## Decision

### New identity on reset

`arlowe-identity reset --force` wipes the identity store; the next boot's `identity init`
generates new entropy and therefore a new `device_id`. The old certificate is revoked first, on
a best-effort basis.

### Order

The reset helper follows this order exactly:

1. Write `/var/lib/arlowe/reset-ledger/in-progress` and fsync.
2. Stop the six runtime units and `arlowe-pair`.
3. Best effort: `arlowe-identity revoke --json`, 20 s timeout, against the broker
   `arlowe_broker.resolve_broker` returns. That is the same resolver pairing used (ADR-0011): the
   FAT file `/boot/firmware/arlowe-broker.json` with its CA first, then
   `identity.provisioning_url` with system trust. On failure, append
   `{certificate_id, thing_name, device_id, at, reason}` to
   `/var/lib/arlowe/reset-ledger/orphaned-certs.jsonl` and fsync. A successful revoke also
   releases the claim-code binding (ADR-0012).
4. `rm /etc/arlowe/config.yml`. **The commit point: the unit is now unpaired.**
5. Delete every `802-11-wireless` NetworkManager profile, and
   `/var/lib/NetworkManager/{seen-bssids,timestamps,*.lease}`.
6. `arlowe-identity reset --force`.
7. Empty `conversations/`, `wake-word/`, `state/`, `dashboard/` (credential, session key,
   cache), `logs/*` and `cache/`, then recreate the skeleton with the owners and modes
   `scripts/provision/install-arlowe-fs.sh` uses.
8. `journalctl --rotate`, then `journalctl --vacuum-time=1s`.
9. Hostname back to `arlowe`, and the `127.0.1.1` line in `/etc/hosts` with it.
10. Append `{at, trigger, revoke: ok|failed|skipped}` to `reset-ledger/resets.log`, remove the
    marker, sync, reboot.

**Resume.** A boot that finds the marker resumes the reset
(`arlowe-factory-reset-resume.service`, `ConditionPathExists=` on the marker), so every step
must be safe to repeat.

### What survives

The reset ledger only: `/var/lib/arlowe/reset-ledger/`, root 0700, on owner state and outside
every wipe path. It holds `orphaned-certs.jsonl` and `resets.log`.

Never touched: `/opt/arlowe/models` (read-only partition), `.firstboot-done`,
`.models-grow-done`.

### Triggers

| Trigger | Mechanism | Authorization |
|---|---|---|
| Dashboard | `POST /api/device/reset` → `arlowe-factory-reset@dashboard.service` | Session plus password re-entry (ADR-0012) |
| Whisplay button | Hold 10 s, countdown drawn from 3 s, LED red at 10 s, release, confirming press within 5 s → `arlowe-factory-reset@button.service` | Physical access |
| Recovery SD card | Reflash; documentation only, `docs/operations/phase-8-pairing.md` | Physical access |

The instance name is the `trigger` recorded in `resets.log`. The button reset lives in
`arlowe-face`, which owns the Whisplay on a paired unit; `arlowe-pair` owns it on an unpaired
unit, where there is nothing to reset.

**Slot B is not a trigger.** It has never booted (B7), so a reset path through it is untested
code on the one path that must work.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| Preserve the identity across resets | Carries the old owner's cloud binding, and the certificate the old owner's setup obtained, to the next owner. |
| Revoke required before wipe | A unit whose network is broken could never be reset, and a broken network is a common reason to reset. |
| Wipe first, revoke on the next pairing | The identity and certificate needed to prove the revoke are gone by then. |
| Delete `config.yml` last | A power cut mid-wipe would leave a "paired" unit with its data half gone and the six units starting against it. |
| Keep the orphan list in `state/` or the journal | Both are wiped by the reset that creates the entry. |
| Slot B as a recovery trigger | Never booted (B7). |

## Consequences

- Every reset produces either a revoked certificate or a ledger line. No certificate is silently
  abandoned.
- A reset that could not revoke leaves the claim code bound to the orphaned `device_id` until an
  operator runs `claim_codes.py release` (ADR-0012).
- A power cut at any step leaves either "reset in progress, resumes on boot" or "unpaired,
  pairing runs".

### Residual risks

- A unit paired against a self-signed dev broker whose FAT file was removed afterwards cannot
  verify that broker at reset time. The revoke fails TLS and the certificate lands in the orphan
  ledger, which is the designed outcome for any failed revoke.
- The ledger is local. A unit that is reflashed or lost takes its orphan ledger with it.

### Open

Who reaps orphaned certificates (research open question 9). The ledger records them; the
consumer (upload on the next successful pairing, or a support procedure) is unassigned.
