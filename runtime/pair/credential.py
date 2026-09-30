"""The owner's dashboard credential and session key (ADR-0012).

Both files are written 0600 through a fresh tmp file and os.replace, so a retry
after setup_failed replaces the previous attempt's files whole.
"""
import datetime
import json
import os
import secrets

from argon2 import PasswordHasher, Type

CREDENTIAL_FILE = "owner-credential.json"
SESSION_KEY_FILE = "session.key"
SESSION_KEY_BYTES = 32

# Explicit, never library defaults: the dashboard verifies whatever the PHC string
# says, so a library upgrade must not silently change what pairing stores.
HASHER = PasswordHasher(time_cost=3, memory_cost=65536, parallelism=4,
                        hash_len=32, salt_len=16, type=Type.ID)


def write_private(path, data):
    """Write bytes to path at 0600 via tmp + fsync + os.replace."""
    path = os.fspath(path)
    tmp = path + ".tmp"
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                 0o600)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def write_owner_credential(state_dir, password, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    body = {"hash": HASHER.hash(password),
            "created_at": now.strftime("%Y-%m-%dT%H:%M:%SZ")}
    write_private(os.path.join(state_dir, CREDENTIAL_FILE), json.dumps(body).encode())


def write_session_key(state_dir):
    write_private(os.path.join(state_dir, SESSION_KEY_FILE),
                  secrets.token_bytes(SESSION_KEY_BYTES))
