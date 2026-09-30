"""The pairing E2E's world: a temp root, the fake nmcli, a real TLS broker with the
stub IoT, the real arlowe-identity CLI, and systemd faked by PATH shims.

The systemctl shim runs the real pair-commit for arlowe-pair-commit.service and
records every other call. Every shim, the display and the portal append to one
events file, so the test can assert the order the pieces ran in.
"""
import functools
import http.client
import json
import os
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PKI = REPO / "scripts" / "pki"
sys.path.insert(0, str(PKI))

import claim_codes  # noqa: E402
import pair.__main__ as pair_main  # noqa: E402
from pair.app import build_app  # noqa: E402
from pair.commit import Committer  # noqa: E402
from pair.display import Display, lines  # noqa: E402
from pair.flow import PairingFlow  # noqa: E402
from pair.netman import NetMan  # noqa: E402
from pair.portal import make_server  # noqa: E402

FAKE_NMCLI = REPO / "runtime" / "pair" / "tests" / "fixtures" / "fake-nmcli"
HOME_PSK = "home-wifi-pass-1"
SCENARIO = {"scan": [{"ssid": "Home", "signal": 70, "security": "WPA2"}],
            "ip4": "192.168.1.23/24", "join": {"correct_psk": HOME_PSK}}
RECORD = """#!/bin/sh
cfg=absent; [ -e "$E2E_ROOT/etc/arlowe/config.yml" ] && cfg=present
echo "$(basename "$0") $* |config=$cfg" >> "$E2E_EVENTS"
"""
SYSTEMCTL = RECORD + """[ "$*" = "start arlowe-pair-commit.service" ] || exit 0
ARLOWE_ROOT="$E2E_ROOT" exec {py} {repo}/runtime/cli/pair-commit >> "$E2E_LOG" 2>&1
"""
IDENTITY = """#!/bin/bash
{py} {repo}/runtime/cli/identity "$@" 2>> "$E2E_LOG" | tee -a "$E2E_LOG"
exit "${{PIPESTATUS[0]}}"
"""


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class FakeBoard:
    def __init__(self, events):
        self.events, self.button = events, None

    def set_backlight(self, level):
        pass

    def draw_image(self, *args):
        pass

    def set_rgb(self, *rgb):
        pass

    def on_button_press(self, cb):
        self.button = cb

    def cleanup(self):
        with open(self.events, "a") as f:
            f.write("display close\n")


class RecordingDisplay(Display):
    """The real Display on a fake board; keeps each screen's text."""

    def __init__(self, events):
        super().__init__(board=FakeBoard(events))
        self.screens, self._events = [], events

    def show(self, screen):
        text = lines(self._screen(screen))
        self.screens.append(text)
        with open(self._events, "a") as f:
            f.write("display %s\n" % " / ".join(text))
        super().show(screen)


class World:
    def __init__(self, tmp, monkeypatch):
        self.tmp, self.root = tmp, tmp / "root"
        self.events, self.log = tmp / "events.log", tmp / "e2e.log"
        self.identity_dir = self.root / "var/lib/arlowe/identity"
        self.config = self.root / "etc/arlowe/config.yml"
        self.broker_file = self.root / "boot/firmware/arlowe-broker.json"
        self.claims, self.ca_dir, self.tls = tmp / "claims.json", tmp / "stub-ca", tmp / "tls"
        self.broker_log, self.nm_log, self.nm_state = tmp / "broker.log", tmp / "nm.log", tmp / "nm.json"
        for d in ("var/lib/arlowe/identity", "var/lib/arlowe/dashboard", "etc/arlowe",
                  "run/arlowe-pair", "boot/firmware", "proc/device-tree/chosen"):
            (self.root / d).mkdir(parents=True, exist_ok=True)
        self.identity_dir.chmod(0o700)
        (self.root / "proc/device-tree/chosen/rpi-duid").write_bytes(b"e2e-duid-0001\0")
        (self.root / "etc/hosts").write_text("127.0.0.1\tlocalhost\n127.0.1.1\tarlowe\n")
        self._shims(monkeypatch)
        subprocess.run(["arlowe-identity", "init", "--json"], check=True, capture_output=True)
        self.device_id = (self.identity_dir / "device-id").read_text().strip()
        self.code = claim_codes.ClaimStore(self.claims).mint("e2e")
        subprocess.run([sys.executable, str(PKI / "stub_iot.py"), "tls", "--san", "127.0.0.1",
                        "--out", str(self.tls)], check=True)
        self.url = "https://127.0.0.1:%d" % free_port()
        self.broker_file.write_text(json.dumps(
            {"url": self.url, "ca_bundle_pem": (self.tls / "ca.pem").read_text()}))
        monkeypatch.setattr(pair_main, "BROKER_FILE", str(self.broker_file))
        monkeypatch.setattr(pair_main, "RUN_DIR", str(self.root / "run/arlowe-pair"))
        self.broker = self.app = None
        self.start_broker()

    def _shims(self, mp):
        bindir = self.tmp / "bin"
        bindir.mkdir()
        fmt = {"py": sys.executable, "repo": REPO}
        for name, body in (("systemctl", SYSTEMCTL.format(**fmt)), ("hostnamectl", RECORD),
                           ("journalctl", RECORD), ("arlowe-identity", IDENTITY.format(**fmt))):
            (bindir / name).write_text(body)
            (bindir / name).chmod(0o755)
        (bindir / "nmcli").symlink_to(FAKE_NMCLI)
        for key, value in {
                "PATH": "%s:%s" % (bindir, os.environ["PATH"]), "E2E_ROOT": self.root,
                "E2E_EVENTS": self.events, "E2E_LOG": self.log, "ARLOWE_LIB": REPO / "runtime/lib",
                "ARLOWE_IDENTITY_DIR": self.identity_dir, "ARLOWE_SERIAL_ROOT": self.root,
                "FAKE_NMCLI_LOG": self.nm_log, "FAKE_NMCLI_STATE": self.nm_state,
                "FAKE_NMCLI_SCENARIO": json.dumps(SCENARIO)}.items():
            mp.setenv(key, str(value))
        self.systemctl = str(bindir / "systemctl")

    def start_broker(self, fail=False):
        port = urllib.parse.urlsplit(self.url).port
        argv = [sys.executable, str(PKI / "broker.py"), "--host", "127.0.0.1", "--port", str(port),
                "--certfile", str(self.tls / "broker-cert.pem"),
                "--keyfile", str(self.tls / "broker-key.pem"),
                "--stub-iot", "--stub-ca-dir", str(self.ca_dir)] + (["--stub-fail", "issuance"] if fail else [])
        with open(self.broker_log, "a") as out:
            self.broker = subprocess.Popen(argv, stdout=out, stderr=subprocess.STDOUT, env={
                **os.environ, "ARLOWE_BROKER_CLAIM_CODES": str(self.claims)})
        end = time.monotonic() + 10
        while True:
            try:
                socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
                return
            except OSError:
                assert self.broker.poll() is None and time.monotonic() < end, "broker did not start"
                time.sleep(0.05)

    def stop_broker(self):
        if self.broker and self.broker.poll() is None:
            self.broker.terminate()
            self.broker.wait(5)

    def start_app(self):
        self.display = RecordingDisplay(self.events)
        self.committer = Committer(
            etc_dir=self.root / "etc/arlowe", run_dir=self.root / "run/arlowe-pair",
            state_dir=self.root / "var/lib/arlowe/dashboard", systemctl=self.systemctl)
        self.app = build_app(
            net=NetMan(), display=self.display, portal_factory=self._portal,
            flow_factory=functools.partial(PairingFlow, ntp_synced=lambda: True,
                                           sleep=lambda s: None),
            committer=self.committer, clock=time.monotonic,
            broker_source=pair_main.broker_source,
            device_id_reader=(self.identity_dir / "device-id").read_text,
            bind_addr=("127.0.0.1", 0), hold_s=0, poll_s=0.01)
        self.rc, self.done = [], 0
        self.thread = threading.Thread(target=lambda: self.rc.append(self.app.run()), daemon=True)
        self.thread.start()
        self.wait(lambda: self.app.state.get("status") == "waiting" and self.app._server)
        self.session = (self.app.session.ssid, self.app.session.psk)

    def _portal(self, state, on_submit, host, port):
        def counted(form):
            try:
                on_submit(form)
            finally:
                self.done += 1
        return make_server(state, counted, host, port)

    def wait(self, pred, timeout=30):
        end = time.monotonic() + timeout
        while not pred():
            assert time.monotonic() < end, "timed out"
            time.sleep(0.02)

    def _http(self, method, path, body=None):
        conn = http.client.HTTPConnection(*self.app._server.server_address[:2], timeout=10)
        headers = {"Host": "10.42.0.1", "Content-Type": "application/x-www-form-urlencoded"}
        conn.request(method, path, body=body, headers=headers)
        res = conn.getresponse()
        data = res.read().decode()
        conn.close()
        return res.status, data

    def submit(self, psk=HOME_PSK, password="dash-pass-99", code=None, name="Kitchen Test"):
        """POST the form; None leaves that field blank (reuse the held value)."""
        before = self.done
        fields = {"ssid": "Home", "psk": psk or "", "name": name, "password": password or "",
                  "password_confirm": password or "", "claim_code": self.code if code is None else code}
        status, _ = self._http("POST", "/pair", urllib.parse.urlencode(fields))
        assert status == 200
        self.wait(lambda: self.done > before)
        return self.app.flow.state.value

    def portal_status(self):
        return json.loads(self._http("GET", "/status")[1])

    def claim(self):
        return claim_codes.ClaimStore(self.claims).load()[claim_codes.code_hash(self.code)]

    def lines_of(self, path):
        return path.read_text().splitlines() if path.exists() else []

    def reset(self):
        res = subprocess.run(
            [sys.executable, str(REPO / "runtime/cli/factory-reset"), "--trigger", "dashboard",
             "--no-reboot"], capture_output=True, text=True, env={
                **os.environ, "ARLOWE_ROOT": str(self.root),
                "ARLOWE_BROKER_FILE": "/boot/firmware/arlowe-broker.json"})
        with open(self.log, "a") as f:
            f.write(res.stdout + res.stderr)
        return res

    def streams(self):
        return "\n".join(p.read_text() for p in (self.log, self.broker_log, self.nm_log, self.events)
                         if p.exists())

    def close(self):
        if self.app is not None and self.thread.is_alive():
            self.app.stop()
            self.thread.join(5)
        self.stop_broker()
