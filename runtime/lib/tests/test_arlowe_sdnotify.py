"""
Unit tests for arlowe_sdnotify.

The receiving end is a real AF_UNIX datagram socket, the same kind systemd
listens on at $NOTIFY_SOCKET, so these exercise the actual send path rather
than a mock of it.
"""

import os
import socket
import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

import arlowe_sdnotify


@pytest.fixture
def listener():
    # Short dir: AF_UNIX paths are capped near 104 bytes on macOS.
    d = tempfile.mkdtemp(dir="/tmp")
    path = os.path.join(d, "notify")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    sock.bind(path)
    sock.settimeout(2)
    yield path, sock
    sock.close()
    os.unlink(path)
    os.rmdir(d)


def test_ready_sends_ready_1_to_notify_socket(listener, monkeypatch):
    path, sock = listener
    monkeypatch.setenv("NOTIFY_SOCKET", path)

    assert arlowe_sdnotify.ready() is True
    assert sock.recv(64) == b"READY=1"


def test_ready_is_a_noop_outside_systemd(monkeypatch):
    monkeypatch.delenv("NOTIFY_SOCKET", raising=False)

    assert arlowe_sdnotify.ready() is False


@pytest.mark.skipif(not sys.platform.startswith("linux"),
                    reason="abstract AF_UNIX namespace is Linux-only")
def test_ready_handles_abstract_socket_address(monkeypatch):
    name = "arlowe-sdnotify-test-%d" % os.getpid()
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    sock.bind("\0" + name)
    sock.settimeout(2)
    try:
        monkeypatch.setenv("NOTIFY_SOCKET", "@" + name)
        assert arlowe_sdnotify.ready() is True
        assert sock.recv(64) == b"READY=1"
    finally:
        sock.close()
