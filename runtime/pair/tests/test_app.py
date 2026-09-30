"""
The pairing daemon's wiring, with the fake nmcli and every other collaborator faked.

Run from repo root:
    PYTHONPATH=runtime:runtime/lib python3 -m pytest runtime/pair/tests/test_app.py -q
"""

import functools
import json
import threading
import time
import types
from pathlib import Path

import pytest

from pair import portal
from pair.app import build_app
from pair.display import Screen, lines
from pair.errors import ErrorKind
from pair.flow import PairingFlow
from pair.netman import NetMan

FAKE = Path(__file__).resolve().parent / "fixtures" / "fake-nmcli"
DEVICE_ID = "ab12cd34ef"
ISSUED = {"device_id": DEVICE_ID, "certificate_id": "c" * 64}
FORM = {"ssid": "Home", "psk": "home-wifi-pw", "display_name": "Kitchen Test",
        "slug": "kitchen-test", "password": "dash-pass-99",
        "claim_code": "ABCDEFGHJKMNPQRSTVWX"}
ETHERNET = {"uuid": "eth-1", "name": "Wired", "type": "802-3-ethernet", "active": True}


def wait_for(pred, timeout=5):
    end = time.monotonic() + timeout
    while not pred():
        assert time.monotonic() < end, "timed out"
        time.sleep(0.01)


class FakeDisplay:
    def __init__(self, order):
        self.shown, self.order, self.ssid, self.psk, self.url, self.ip = [], order, "", "", "", ""
        self.button, self.fail_paired = None, False

    def show(self, screen):
        if screen == "paired" and self.fail_paired:
            raise RuntimeError("panel gone")
        self.shown.append((screen, self.ssid, self.psk, self.url, self.ip))

    def on_button(self, cb):
        self.button = cb

    def close(self):
        self.order.append("close")


class FakeCommitter:
    def __init__(self, order):
        self.order, self.commits = order, []

    def __call__(self, form, provisioned):
        self.commits.append(provisioned)

    def start_runtime(self):
        self.order.append("start_runtime")
        return 0


@pytest.fixture
def h(tmp_path, monkeypatch):
    log, state = tmp_path / "argv.jsonl", tmp_path / "state.json"
    monkeypatch.setenv("FAKE_NMCLI_LOG", str(log))
    monkeypatch.setenv("FAKE_NMCLI_STATE", str(state))
    ns = types.SimpleNamespace(order=[], t=0.0, broker_calls=0, device_id=DEVICE_ID,
                               portal_calls=[], broker=("https://broker.example", None))
    ns.display, ns.committer = FakeDisplay(ns.order), FakeCommitter(ns.order)
    ns.argvs = lambda: [json.loads(x) for x in log.read_text().splitlines()]
    ns.profiles = lambda: json.loads(state.read_text())["profiles"]
    ns.seed = lambda profiles: state.write_text(json.dumps({"profiles": profiles}))
    ns.scenario = lambda **kw: monkeypatch.setenv("FAKE_NMCLI_SCENARIO", json.dumps(kw))
    ns.scenario(scan=[{"ssid": "Home", "signal": 70, "security": "WPA2"}],
                ip4="192.168.1.23/24")

    def broker():
        ns.broker_calls += 1
        return ns.broker

    def portal_factory(st, on_submit, host, port):
        ns.portal_calls.append(((host, port), len(ns.argvs())))
        ns.on_submit = on_submit
        return portal.make_server(st, on_submit, host, port)

    def device_id():
        if ns.device_id is None:
            raise FileNotFoundError("device-id")
        return ns.device_id

    def start():
        ns.app = build_app(
            net=NetMan(nmcli=str(FAKE)), display=ns.display, portal_factory=portal_factory,
            flow_factory=functools.partial(PairingFlow, identity=lambda *a: (0, dict(ISSUED)),
                                           ntp_synced=lambda: True, sleep=lambda s: None),
            committer=ns.committer, clock=lambda: ns.t, broker_source=broker,
            device_id_reader=device_id, bind_addr=("127.0.0.1", 0), hold_s=30, poll_s=0.01)
        ns.rc = []

        def run():
            try:
                ns.rc.append(ns.app.run())
            except RuntimeError as exc:
                ns.rc.append(exc)

        ns.thread = threading.Thread(target=run, daemon=True)
        ns.thread.start()

    ns.start = start
    ns.kinds = lambda: [s[0] for s in ns.display.shown]
    yield ns
    if getattr(ns, "app", None) and ns.thread.is_alive():
        ns.app.stop()
        ns.thread.join(5)


def waiting(h, n=1):
    wait_for(lambda: h.kinds().count("waiting") >= n)
    return [s for s in h.display.shown if s[0] == "waiting"][-1]


def test_stale_wifi_profiles_are_swept_before_the_radio(h):
    h.seed([{"uuid": "home-1", "name": "Home", "type": "802-11-wireless", "psk_flags": 0},
            {"uuid": "ap-1", "name": "arlowe-setup", "type": "802-11-wireless"}, ETHERNET])
    h.start()
    waiting(h)
    argvs = h.argvs()
    radio = argvs.index(["radio", "wifi", "on"])
    deletes = [i for i, a in enumerate(argvs) if a[:2] == ["connection", "delete"]]
    assert [argvs[i][3] for i in deletes] == ["home-1", "ap-1"] and max(deletes) < radio
    uuids = {p["uuid"] for p in h.profiles()}
    assert "eth-1" in uuids and not uuids & {"home-1", "ap-1"}


def test_start_raises_the_setup_network_and_shows_the_qr(h):
    h.start()
    _, ssid, psk, _, _ = waiting(h)
    argvs = h.argvs()
    assert argvs[1] == ["radio", "wifi", "on"]
    assert argvs[2][-5:] == ["device", "wifi", "list", "--rescan", "yes"]
    add, up = argvs[3], argvs[4]
    assert add[:4] == ["connection", "add", "save", "no"] and "wpa-psk" in add
    assert up[-2:] == ["passwd-file", "/dev/stdin"] and up[:3] == ["connection", "up", "uuid"]
    assert ssid == "Arlowe-Setup-ab12" and len(psk) == 12
    assert not any(psk in arg for a in argvs for arg in a)
    assert h.app.state["networks"] == [{"ssid": "Home", "signal": 70, "secure": True}]
    assert h.app.state["ap_ssid"] == ssid and h.app.state["status"] == "waiting"


def test_portal_binds_bind_addr_only_after_the_first_ap_up(h):
    h.start()
    waiting(h)
    ((addr, calls_before),) = h.portal_calls
    assert addr == ("127.0.0.1", 0)
    assert any(a[:3] == ["connection", "up", "uuid"] for a in h.argvs()[:calls_before])


def test_idle_timeout_then_button_starts_a_new_session(h):
    h.start()
    _, _, psk1, _, _ = waiting(h)
    h.t += 30 * 60
    wait_for(lambda: h.kinds()[-1] == "idle")
    assert h.argvs()[-2][:2] == ["connection", "down"]
    assert h.app.state["networks"]
    h.display.button()
    _, _, psk2, _, _ = waiting(h, 2)
    assert psk2 != psk1 and h.argvs()[-1][:3] == ["connection", "up", "uuid"]
    assert len(h.portal_calls) == 1


def test_a_submission_resets_the_idle_timer(h):
    h.broker = None
    h.start()
    waiting(h)
    h.t += 29 * 60
    h.on_submit(dict(FORM))
    h.t += 29 * 60
    time.sleep(0.1)
    assert "idle" not in h.kinds()
    h.t += 2 * 60
    wait_for(lambda: h.kinds()[-1] == "idle")


def test_the_broker_is_resolved_per_submission(h):
    h.broker = None
    h.start()
    waiting(h)
    assert h.broker_calls == 0
    h.on_submit(dict(FORM))
    assert h.broker_calls == 1 and h.display.shown[-1][0] is ErrorKind.not_configured
    assert h.app.state["error_kind"] == "not_configured"


def test_missing_device_identity_is_shown_and_the_daemon_stays_up(h):
    h.device_id = None
    h.start()
    wait_for(lambda: h.display.shown)
    screen = h.display.shown[-1][0]
    assert screen == Screen.error(ErrorKind.setup_failed, detail="Device identity missing")
    assert lines(screen)[-1] == "Device identity missing"
    time.sleep(0.1)
    assert h.thread.is_alive() and h.portal_calls == []
    assert ["radio", "wifi", "on"] not in h.argvs()


def pair(h):
    h.start()
    waiting(h)
    threading.Thread(target=h.on_submit, args=(dict(FORM),), daemon=True).start()


def test_paired_hold_then_release_then_start(h):
    pair(h)
    wait_for(lambda: h.kinds()[-1] == "paired")
    assert h.display.shown[-1][3:] == ("http://kitchen-test.local:3000", "192.168.1.23")
    assert h.app.state["ip_hint"] == "192.168.1.23"
    time.sleep(0.1)
    assert h.order == [] and h.rc == []
    h.t += 30
    h.thread.join(5)
    assert h.order == ["close", "start_runtime"] and h.rc == [0]


def test_a_button_press_ends_the_paired_hold(h):
    pair(h)
    wait_for(lambda: h.kinds()[-1] == "paired")
    h.display.button()
    h.thread.join(5)
    assert h.order == ["close", "start_runtime"] and h.rc == [0]


def test_a_failed_paired_draw_still_starts_the_runtime_once(h):
    h.display.fail_paired = True
    pair(h)
    h.thread.join(5)
    assert h.order.count("start_runtime") == 1 and isinstance(h.rc[0], RuntimeError)


def test_stop_releases_the_board_and_drops_the_ap(h):
    # __main__ routes SIGTERM to app.stop().
    h.start()
    waiting(h)
    h.app.stop()
    h.thread.join(5)
    assert h.order == ["close"] and h.rc == [0]
    assert h.argvs()[-2][:2] == ["connection", "down"]
    assert [s[0] for s in h.display.shown] == ["waiting"]
