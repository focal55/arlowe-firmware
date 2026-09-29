# ADR-0012: Owner credential and claim codes

<!-- status: accepted -->
**Status:** Accepted (owner decisions of 2026-09-28)
**Date:** 2026-09-28
**Phase:** 8 (First-boot pairing, DASH-02)
**Hardware validation:** plan 08-27b

## Context

Two secrets enter at pairing (ADR-0011):

- **The dashboard password.** The dashboard today has no authentication; its `verifyAuth` bearer
  secret was never configured. DASH-02 is a from-scratch build. The password never leaves the
  device.
- **The claim code.** A per-unit code printed on the box card. The broker exchanges it for
  certificate issuance, so a bare image cannot obtain a certificate on its own.

Constraints:

- `POST /api/config` rewrites the `config.yml` overlay, and every service reads that file. A
  credential there is exposed to every reader and every rewrite.
- The dashboard is plain HTTP on the LAN. There is no origin a `Secure` cookie can use.
- Reset gives the unit a new `device_id` (ADR-0013). A strictly single-use claim code is spent on
  first pairing, so the owner could not re-pair after a reset with the card in the box, and a
  lost 200 after the broker marked the code used would strand the owner (research N7).
- The device contract of ADR-0007 is token-agnostic: the device sends a bearer token and nothing
  more.

## Decision

### Owner credential

- **Hash:** Argon2id (argon2id) via `python3-argon2`, parameters set explicitly, never inherited from
  library defaults: `time_cost=3, memory_cost=65536, parallelism=4, hash_len=32, salt_len=16`.
  The result is a PHC string, `$argon2id$v=19$m=65536,t=3,p=4$<salt>$<hash>`.
- **Location:** `/var/lib/arlowe/dashboard/owner-credential.json`, `{"hash", "created_at"}`,
  mode 0600, owner `arlowe`. Not in `config.yml`, for the reason above.
- **Verify:** the dashboard uses Node 24's `crypto.argon2` and `timingSafeEqual`, accepting only
  `argon2id` with `v=19`. The device runs Node 24; CI moves from Node 20 to Node 24 in the same
  change, so tests run against the runtime the device has (research N9). A PHC string produced
  by `python3-argon2` and verified by the Node code is the cross-implementation test vector.

### Session

- **Cookie:** stateless,
  `arlowe_session = base64url(payload).base64url(HMAC-SHA256(key, payload))`, payload
  `{v:1, iat, exp}`, 30-day absolute expiry.
- **Key:** 32 random bytes at `/var/lib/arlowe/dashboard/session.key`, written at pairing, wiped
  by reset. Rotating it logs out every session.
- **Attributes:** `HttpOnly; SameSite=Strict; Path=/`. **No `Secure`**: browsers drop Secure
  cookies on `http://` origins.
- **Every mutating route** checks the session and that `Origin` matches `Host`. The proxy
  redirects pages to `/login` and returns 401 JSON for `/api/*`; handlers check again rather than
  relying on the proxy alone.
- **Login throttle:** 5 failures, then 30 s.

**Forgotten password = factory reset.** There is no recovery path. The claim code is not a master
key.

### Claim codes

- **Format:** 20 Crockford base32 characters (100 bits), printed in groups of five. Normalized by
  uppercasing and stripping `-` and spaces.
- **Broker store:** `sha256(normalized) -> {state: unused|bound|revoked, device_id, minted_at,
  bound_at, note}`. With a 100-bit secret, a hash-keyed lookup leaks nothing useful.
- **One answer for every refusal:** unknown, bound-elsewhere and revoked codes all get an
  identical `401 {"error":"unauthorized"}`.
- **Binding:** a code binds to the first `device_id` that redeems it, after IoT issuance
  succeeds. The same `device_id` redeeming again is idempotent, which covers a lost 200.
- **Release:** a reset's revoke call (ADR-0013) releases the binding, so the same card works for
  the next owner. A reset that could not revoke leaves the code bound to the orphaned id;
  releasing it is an operator action, `claim_codes.py release`.
- **This supersedes "single-use".**
- **Tools:** `claim_codes.py mint [--note]`, `revoke <code>` and `release <code>` on the broker
  host. Nothing under `scripts/pki/` ships in the image.

### Device contract

The device stays token-agnostic, as ADR-0007 requires. It sends the claim code as its bearer
token (`ARLOWE_OWNER_TOKEN`, in the environment) and knows nothing about claim-code state. The
broker's "do not add a lookup" rule was Phase 7's constraint and lifts here. Swapping the claim
code for a hosted account token later needs no device change.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| Password hash in `config.yml` | Every service reads the overlay, and `POST /api/config` rewrites it. |
| bcrypt, scrypt or a hand-rolled KDF | Argon2id is the current recommendation and both runtimes (`python3-argon2`, Node 24 `crypto.argon2`) implement it: a Debian package and a Node built-in, with no npm addon. |
| Server-side session table | A stateless HMAC cookie needs no store, and rotating one key revokes every session. |
| `Secure` cookie attribute | The dashboard is plain HTTP; the browser would drop the cookie and login would never stick. |
| Strictly single-use claim codes | Collide with new identity on reset and strand the owner after a lost 200 (research N7). |
| Distinct errors for unknown, used and revoked codes | Tells a guesser which codes exist. |
| Claim code as password recovery | Turns a printed card into a master key for a paired unit. |

## Consequences

- DASH-02 is built from scratch; `verifyAuth` and `DASHBOARD_API_SECRET` are deleted.
- CI's dashboard jobs run Node 24.
- An owner who forgets the password loses the unit's local data through a factory reset.
- Offline resets create operator work (`claim_codes.py release`).

### Residual risks

- The hashed hostname banlist (ADR-0011) lets someone confirm a guess of a banned literal.
- A stolen card cannot claim a unit that is already paired, but it can claim an unpaired unit it
  was printed for, or a unit whose reset released the binding. The card is as sensitive as a key
  until first pairing.
- The session cookie crosses the LAN in cleartext. Anyone on the owner's network who can sniff
  it holds a session for up to 30 days.
