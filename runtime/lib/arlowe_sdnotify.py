"""
Minimal sd_notify(3): tell systemd a Type=notify service is ready.

Stdlib only, so it adds nothing to any venv. A unit that depends on this service
with After= then waits for the service to be *ready*, not merely for its process
to exist -- the difference between qwen-api connecting to a listening tokenizer
and failing twice on every boot.
"""

import os
import socket


def ready():
    """Send READY=1. Returns False when not running under systemd."""
    addr = os.environ.get("NOTIFY_SOCKET")
    if not addr:
        return False
    if addr.startswith("@"):
        addr = "\0" + addr[1:]
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
        sock.connect(addr)
        sock.sendall(b"READY=1")
    return True
