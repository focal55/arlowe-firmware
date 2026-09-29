#!/usr/bin/env python3
"""Claim-code store for the CSR broker (ADR-0012). Dev host only.

A claim code is 20 Crockford base32 characters (100 bits) printed once, at mint,
in groups of five. The store is a JSON map sha256(normalized code) ->
{state, device_id, minted_at, bound_at, note}; the plaintext is never written.

A code binds to the first device_id that redeems it. The same device_id redeeming
again succeeds unchanged, which covers a 200 lost in transit. A reset's revoke
call releases the binding so the next identity on that unit can claim it; a reset
that could not reach the broker leaves it bound until an operator runs `release`.

The device side never sees any of this: it presents the code as an opaque bearer
token (ADR-0007). Nothing under scripts/pki/ ships in the firmware image.
"""

import argparse
import contextlib
import datetime
import fcntl
import hashlib
import json
import os
import secrets
import sys
from pathlib import Path

ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
CODE_LENGTH = 20
_ALIASES = str.maketrans({"I": "1", "L": "1", "O": "0", "-": None, " ": None, "\t": None})


def normalize(code):
    value = code.upper().translate(_ALIASES)
    if len(value) != CODE_LENGTH or any(c not in ALPHABET for c in value):
        raise ValueError("not a claim code")
    return value


def code_hash(code):
    return hashlib.sha256(normalize(code).encode()).hexdigest()


def _now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def redeem(entry, device_id, now=None):
    """Return the entry as it stands after a successful redemption, or None if refused.

    Pure over one entry so the broker can decide, issue and only then bind, all
    under a single store transaction. Unknown, revoked and bound-elsewhere all
    return None: callers must not be able to tell them apart.
    """
    if entry is None:
        return None
    if entry["state"] == "unused":
        return dict(entry, state="bound", device_id=device_id, bound_at=now or _now())
    if entry["state"] == "bound" and entry["device_id"] == device_id:
        return entry
    return None


def _released(entry):
    return dict(entry, state="unused", device_id=None, bound_at=None)


def release_device(entries, device_id):
    """Release, in place, every code in `entries` bound to device_id; return the count."""
    hits = [h for h, e in entries.items() if e["state"] == "bound" and e["device_id"] == device_id]
    for h in hits:
        entries[h] = _released(entries[h])
    return len(hits)


class ClaimStore:
    def __init__(self, path):
        self.path = Path(path)
        self.lock_path = self.path.with_name(self.path.name + ".lock")
        self.tmp_path = self.path.with_name(self.path.name + ".tmp")

    def load(self):
        with open(self.path) as f:
            return json.load(f)

    @contextlib.contextmanager
    def transaction(self, create=False):
        """Yield the entry map under an exclusive lock; persist it on clean exit if changed.

        The lock is a separate file because os.replace swaps the store's inode,
        and a flock on the old inode would not exclude a writer that opened the new one.
        """
        fd = os.open(self.lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            try:
                entries = self.load()
            except FileNotFoundError:
                if not create:
                    raise
                entries = None
            before = json.dumps(entries, sort_keys=True)
            entries = {} if entries is None else entries
            yield entries
            if json.dumps(entries, sort_keys=True) != before:
                self._write(entries)
        finally:
            os.close(fd)

    def _write(self, entries):
        fd = os.open(self.tmp_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(entries, f, indent=2, sort_keys=True)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(self.tmp_path, self.path)

    def mint(self, note=None):
        """Create the store if needed, add an unused code and return it grouped for printing."""
        code = "".join(secrets.choice(ALPHABET) for _ in range(CODE_LENGTH))
        with self.transaction(create=True) as entries:
            entries[code_hash(code)] = {
                "state": "unused",
                "device_id": None,
                "minted_at": _now(),
                "bound_at": None,
                "note": note,
            }
        return "-".join(code[i : i + 5] for i in range(0, CODE_LENGTH, 5))

    def redeem(self, code, device_id):
        try:
            key = code_hash(code)
        except ValueError:
            return False
        with self.transaction() as entries:
            after = redeem(entries.get(key), device_id)
            if after is None:
                return False
            entries[key] = after
            return True

    def release(self, code):
        """bound -> unused. Raises KeyError for an unknown code; other states are left alone."""
        key = code_hash(code)
        with self.transaction() as entries:
            if entries[key]["state"] == "bound":
                entries[key] = _released(entries[key])

    def release_device(self, device_id):
        with self.transaction() as entries:
            return release_device(entries, device_id)

    def revoke(self, code):
        key = code_hash(code)
        with self.transaction() as entries:
            entries[key] = dict(entries[key], state="revoked")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Mint, revoke, release and list broker claim codes.")
    parser.add_argument("--store", required=True, help="claim-code store (JSON); mint creates it")
    sub = parser.add_subparsers(dest="command", required=True)
    mint_p = sub.add_parser("mint", help="add a code and print it once")
    mint_p.add_argument("--note", help="operator note, e.g. which unit the card ships with")
    for name, text in (("revoke", "make a code permanently unusable"), ("release", "unbind a code so it can be claimed again")):
        sub.add_parser(name, help=text).add_argument("code")
    sub.add_parser("list", help="show hash prefix, state, device and dates; never a code")
    args = parser.parse_args(argv)

    store = ClaimStore(args.store)
    try:
        if args.command == "mint":
            print(store.mint(args.note))
        elif args.command == "revoke":
            store.revoke(args.code)
        elif args.command == "release":
            store.release(args.code)
        else:
            for key, e in sorted(store.load().items(), key=lambda kv: kv[1]["minted_at"]):
                print(
                    "%s  %-7s  %-8s  %s  %s  %s"
                    % (key[:12], e["state"], (e["device_id"] or "-")[:8], e["minted_at"], e["bound_at"] or "-", e["note"] or "")
                )
    except FileNotFoundError:
        sys.exit("claim_codes.py: store %s does not exist (mint creates it)" % args.store)
    except (KeyError, ValueError):
        sys.exit("claim_codes.py: no such claim code")


if __name__ == "__main__":
    main()
