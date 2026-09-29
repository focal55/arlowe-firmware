"""
Unit tests for pair.flow with every collaborator faked.

Run from repo root:
    PYTHONPATH=runtime:runtime/lib python3 -m pytest runtime/pair/tests/test_flow.py -q
"""

import json
import logging
import subprocess
import threading
import types

import pytest

from pair import flow
from pair.errors import ErrorKind, JoinError
from pair.flow import PairingFlow, State, classify_identity_failure
from pair.netman import NetManError

SESSION = types.SimpleNamespace(ssid="Arlowe-Setup-ab12", psk="SESSIONPSK23")
FORM = {"ssid": "Home", "psk": "home-wifi-pw", "display_name": "Kitchen",
        "password": "dash-pass-99", "claim_code": "ABCDE-FGHJK-MNPQR-STVWX"}
SECRETS = [FORM["psk"], FORM["password"], FORM["claim_code"], SESSION.psk]
ISSUED = {"device_id": "ab12cd34", "certificate_id": "c" * 64, "thing_name": "ab12cd34"}


class FakeNet:
    def __init__(self, join_error=None):
        self.calls, self.join_error, self.profiles, self.gate = [], join_error, [], None
        self.joining = threading.Event()

    def ap_up(self, ssid, psk):
        self.calls.append(("ap_up", ssid, psk))
        self.profiles.append("ap")

    def ap_down(self):
        self.calls.append(("ap_down",))
        self.profiles = [p for p in self.profiles if p != "ap"]

    def join(self, ssid, psk):
        self.calls.append(("join", ssid, psk))
        self.joining.set()
        if self.gate:
            self.gate.wait(5)
        if self.join_error:
            raise self.join_error
        self.profiles.append("home:" + ssid)

    def wifi_profiles(self):
        return list(self.profiles)

    def delete_profile(self, uuid_):
        self.calls.append(("delete", uuid_))
        self.profiles.remove(uuid_)


class FakeClock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t

    def sleep(self, s):
        self.t += s


@pytest.fixture
def h():
    """A harness: collaborators plus a flow built from them."""
    ns = types.SimpleNamespace(net=FakeNet(), shown=[], commits=[], paired=[],
                               clock=FakeClock(), identity_calls=[],
                               identity_result=(0, dict(ISSUED)), synced=lambda: True,
                               broker=lambda: ("https://broker.example", "/run/ca.pem"))
    ns.display = types.SimpleNamespace(show=ns.shown.append,
                                       close=lambda: pytest.fail("flow closed display"))

    def identity(url, ca, code):
        ns.identity_calls.append((url, ca, code))
        return ns.identity_result

    def build(**kw):
        args = dict(net=ns.net, display=ns.display, identity=identity,
                    commit=lambda form, prov: ns.commits.append((dict(form), prov)),
                    broker=lambda: ns.broker(), ntp_synced=lambda: ns.synced(),
                    on_paired=ns.paired.append, session=SESSION,
                    clock=ns.clock, sleep=ns.clock.sleep)
        args.update(kw)
        return PairingFlow(**args)

    ns.build = build
    return ns


def assert_recovered(h, kind):
    f = h.flow
    assert f.state is State.ERROR and f.status()["error_kind"] == kind.value
    assert h.net.calls[-1] == ("ap_up", SESSION.ssid, SESSION.psk)
    assert h.net.wifi_profiles() == ["ap"]
    assert h.shown[-1] == kind
    assert h.paired == []


def test_happy_path(h):
    h.flow = h.build()
    assert h.flow.submit(dict(FORM)) is True
    assert h.shown == ["connecting", "provisioning", "committing", "paired"]
    assert h.flow.state is State.PAIRED
    assert h.commits == [(FORM, {**ISSUED, "broker_url": "https://broker.example"})]
    assert h.paired == [h.commits[0][1]]
    assert h.net.calls[:2] == [("ap_down",), ("join", "Home", FORM["psk"])]
    assert not any(c[0] == "ap_up" for c in h.net.calls)
    assert h.identity_calls == [("https://broker.example", "/run/ca.pem", FORM["claim_code"])]
    assert h.clock.t >= flow.HANDOFF_DELAY_S
    assert h.flow.submit(dict(FORM)) is False


@pytest.mark.parametrize("kind", [ErrorKind.wifi_rejected, ErrorKind.wifi_not_found])
def test_join_failures(h, kind):
    h.net.join_error = JoinError(kind)
    h.flow = h.build()
    h.flow.submit(dict(FORM))
    assert_recovered(h, kind)
    assert h.identity_calls == []


def test_netman_error_is_wifi_failed(h):
    h.net.join_error = NetManError("join failed (rc=4): boom")
    h.flow = h.build()
    h.flow.submit(dict(FORM))
    assert_recovered(h, ErrorKind.wifi_failed)


@pytest.mark.parametrize("code,body,kind", [
    (4, {"http_status": None}, ErrorKind.server_unreachable),
    (3, {"http_status": 401}, ErrorKind.claim_rejected),
    (3, {"http_status": 400}, ErrorKind.cert_failed),
    (4, {"http_status": 502}, ErrorKind.cert_failed),
    (5, {"http_status": None}, ErrorKind.cert_failed),
    (0, {}, ErrorKind.cert_failed),
])
def test_identity_failures(h, code, body, kind):
    assert classify_identity_failure(code, body) is kind
    h.identity_result = (code, {"ok": False, "exit": code, "error": "x", **body})
    h.flow = h.build()
    h.flow.submit(dict(FORM))
    assert_recovered(h, kind)
    assert ("delete", "home:Home") in h.net.calls
    assert h.commits == []


def test_no_broker_is_not_configured(h):
    h.broker = lambda: None
    h.flow = h.build()
    h.flow.submit(dict(FORM))
    assert h.flow.status()["error_kind"] == "not_configured"
    assert h.identity_calls == [] and h.net.calls == []
    assert h.shown == [ErrorKind.not_configured]


def test_ntp_gate_waits_then_proceeds(h):
    h.synced = lambda: False
    h.flow = h.build()
    h.flow.submit(dict(FORM))
    assert h.flow.state is State.PAIRED
    assert h.clock.t >= flow.HANDOFF_DELAY_S + flow.NTP_WAIT_S


def test_ntp_gate_stops_waiting_once_synced(h):
    h.synced = lambda: h.clock.t >= flow.HANDOFF_DELAY_S + 5
    h.flow = h.build()
    h.flow.submit(dict(FORM))
    assert flow.HANDOFF_DELAY_S + 5 <= h.clock.t < flow.HANDOFF_DELAY_S + flow.NTP_WAIT_S


def test_resubmit_reuses_held_secrets(h):
    h.identity_result = (3, {"http_status": 401})
    h.flow = h.build()
    h.flow.submit(dict(FORM))
    st = h.flow.status()
    assert st["has_previous"] == {"psk": True, "password": True, "claim_code": True}
    assert st["last_form"] == {"ssid": "Home", "display_name": "Kitchen"}
    h.identity_result = (0, dict(ISSUED))
    h.flow.submit({**FORM, "psk": "", "password": "", "claim_code": "NEWCODE"})
    assert h.net.calls[-1] == ("join", "Home", FORM["psk"])
    assert h.identity_calls[-1][2] == "NEWCODE"
    assert h.commits[0][0]["password"] == FORM["password"]


def test_held_psk_not_reused_for_other_network(h):
    h.net.join_error = JoinError("wifi_rejected")
    h.flow = h.build()
    h.flow.submit(dict(FORM))
    h.flow.submit({**FORM, "ssid": "OpenCafe", "psk": ""})
    assert h.net.calls[-2] == ("join", "OpenCafe", "")


def test_commit_failure_is_setup_failed(h):
    def boom(form, prov):
        raise RuntimeError("hostname helper exited 1")
    h.flow = h.build(commit=boom)
    h.flow.submit(dict(FORM))
    assert_recovered(h, ErrorKind.setup_failed)


def test_concurrent_submit_refused(h):
    h.net.gate = threading.Event()
    h.flow = h.build()
    t = threading.Thread(target=h.flow.submit, args=(dict(FORM),))
    t.start()
    assert h.net.joining.wait(5)
    assert h.flow.submit(dict(FORM)) is False
    h.net.gate.set()
    t.join(5)
    assert h.flow.state is State.PAIRED and len(h.commits) == 1


def test_no_secret_in_logs(h, caplog):
    caplog.set_level(logging.DEBUG)
    h.flow = h.build()
    h.flow.submit(dict(FORM))
    h.net.join_error = JoinError("wifi_rejected")
    h.flow = h.build()
    h.flow.submit(dict(FORM))
    assert caplog.text
    assert not any(s in caplog.text for s in SECRETS)


@pytest.fixture
def shim(tmp_path, monkeypatch):
    """A fake arlowe-identity on PATH that logs argv and the token it saw."""
    log = tmp_path / "calls.jsonl"
    exe = tmp_path / "bin" / "arlowe-identity"
    exe.parent.mkdir()
    exe.write_text(
        "#!/usr/bin/env python3\n"
        "import json, os, sys\n"
        "with open(%r, 'a') as f:\n"
        "    f.write(json.dumps({'argv': sys.argv[1:],\n"
        "        'token': os.environ.get('ARLOWE_OWNER_TOKEN'),\n"
        "        'ca': os.environ.get('ARLOWE_BROKER_CA_BUNDLE')}) + '\\n')\n"
        "out = json.loads(os.environ['SHIM_' + sys.argv[1].upper()])\n"
        "print(json.dumps(out['json']))\n"
        "sys.exit(out['exit'])\n" % str(log))
    exe.chmod(0o755)
    monkeypatch.setenv("PATH", "%s:%s" % (exe.parent, flow.os.environ["PATH"]))

    def script(status, provision=None):
        monkeypatch.setenv("SHIM_STATUS", json.dumps(status))
        monkeypatch.setenv("SHIM_PROVISION", json.dumps(provision or {}))

    def calls():
        return [json.loads(line) for line in log.read_text().splitlines()]
    return types.SimpleNamespace(script=script, calls=calls)


UNPROVISIONED = {"exit": 0, "json": {"provisioned": False, "device_id": "ab12cd34"}}


def test_default_runner_token_in_env_not_argv(shim):
    shim.script(UNPROVISIONED, {"exit": 3, "json": {"ok": False, "http_status": 401}})
    code = "ABCDE-FGHJK-MNPQR-STVWX"
    assert flow.run_identity("https://b.example", "/tmp/ca.pem", code) == \
        (3, {"ok": False, "http_status": 401})
    status, prov = shim.calls()
    assert status["argv"] == ["status", "--json"] and status["token"] is None
    assert prov["argv"] == ["provision", "--json", "--ca-broker-url", "https://b.example"]
    assert prov["token"] == code and prov["ca"] == "/tmp/ca.pem"
    assert not any(code in a for c in shim.calls() for a in c["argv"])
    flow.run_identity("https://b.example", None, code)
    assert shim.calls()[-1]["ca"] is None


def test_default_runner_reuses_stored_certificate(shim):
    stored = {**ISSUED, "provisioned": True, "provisioned_at": "2026-09-28T00:00:00Z",
              "cert_present": True}
    shim.script({"exit": 0, "json": stored})
    code, body = flow.run_identity("https://b.example", None, "CODE")
    assert code == 0 and body["certificate_id"] == ISSUED["certificate_id"]
    assert [c["argv"][0] for c in shim.calls()] == ["status"]


def test_default_runner_timeout_is_unreachable(shim, monkeypatch):
    shim.script(UNPROVISIONED)
    real = subprocess.run

    def run(argv, **kw):
        if argv[1] == "provision":
            raise subprocess.TimeoutExpired(argv, kw["timeout"])
        return real(argv, **kw)
    monkeypatch.setattr(flow.subprocess, "run", run)
    code, body = flow.run_identity("https://b.example", None, "CODE")
    assert classify_identity_failure(code, body) is ErrorKind.server_unreachable
