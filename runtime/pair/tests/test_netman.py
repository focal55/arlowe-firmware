"""
Unit tests for pair.netman against the scripted fake-nmcli.

Run from repo root:
    PYTHONPATH=runtime:runtime/lib python3 -m pytest runtime/pair/tests/test_netman.py -q
"""

import json
import logging
import subprocess
import uuid
from pathlib import Path

import pytest

from pair import netman
from pair.netman import PSK_ALPHABET, NetMan, session_credentials

FAKE = Path(__file__).resolve().parent / "fixtures" / "fake-nmcli"
PSK = "ABCDEFGH2345"


@pytest.fixture
def fake(tmp_path, monkeypatch):
    log, state = tmp_path / "argv.jsonl", tmp_path / "state.json"
    monkeypatch.setenv("FAKE_NMCLI_LOG", str(log))
    monkeypatch.setenv("FAKE_NMCLI_STATE", str(state))

    class Fake:
        def scenario(self, **kw):
            monkeypatch.setenv("FAKE_NMCLI_SCENARIO", json.dumps(kw))

        def argvs(self):
            return [json.loads(line) for line in log.read_text().splitlines()]

        def profiles(self):
            return json.loads(state.read_text())["profiles"] if state.exists() else []

    return Fake()


@pytest.fixture
def nm(fake):
    return NetMan(nmcli=str(FAKE))


def test_session_credentials():
    ssid, psk = session_credentials("ab12cd34")
    assert ssid == "Arlowe-Setup-ab12"
    assert len(psk) == 12 and set(psk) <= set(PSK_ALPHABET)
    assert session_credentials("ab12cd34")[1] != psk


def test_radio_on(nm, fake):
    nm.radio_on()
    assert fake.argvs() == [["radio", "wifi", "on"]]


def test_scan(nm, fake):
    fake.scenario(scan=[
        {"ssid": "Home", "signal": 40, "security": "WPA2"},
        {"ssid": "", "signal": 90, "security": "WPA2"},
        {"ssid": "Cafe", "signal": 70, "security": ""},
        {"ssid": "Home", "signal": 65, "security": "WPA2"},
    ])
    assert nm.scan() == [
        {"ssid": "Cafe", "signal": 70, "secure": False},
        {"ssid": "Home", "signal": 65, "secure": True},
    ]
    assert fake.argvs()[0] == ["-t", "-f", "SSID,SIGNAL,SECURITY", "device", "wifi",
                                   "list", "--rescan", "yes"]


def test_scan_escaped_colon(nm, fake):
    fake.scenario(scan=[{"ssid": "My:Net\\2", "signal": 50, "security": "WPA1 WPA2"}])
    assert nm.scan() == [{"ssid": "My:Net\\2", "signal": 50, "secure": True}]


def test_ap_up_and_down(nm, fake):
    nm.ap_up("Arlowe-Setup-ab12", PSK)
    add, up = fake.argvs()
    assert add[:2] == ["connection", "add"]
    for pair in (["ssid", "Arlowe-Setup-ab12"], ["802-11-wireless.mode", "ap"],
                 ["wifi-sec.key-mgmt", "wpa-psk"], ["wifi-sec.proto", "rsn"],
                 ["ipv4.method", "shared"], ["ipv4.addresses", "10.42.0.1/24"]):
        assert any(add[i:i + 2] == pair for i in range(len(add))), pair
    assert "wifi-sec.psk" not in add
    assert fake.profiles()[0]["active"] is True
    nm.ap_down()
    assert [a[:2] for a in fake.argvs()[2:4]] == [["connection", "down"],
                                                  ["connection", "delete"]]
    assert fake.profiles() == []
    nm.ap_up("Arlowe-Setup-ab12", PSK)
    nm.delete_profile(fake.profiles()[0]["uuid"])
    nm.ap_down()


def test_ap_up_failure_raises_and_cleans_up(nm, fake):
    fake.scenario(ap_up="fail")
    with pytest.raises(netman.NetManError):
        nm.ap_up("Arlowe-Setup-ab12", PSK)
    assert fake.profiles() == []


def test_ap_profile_not_saved(nm, fake):
    nm.ap_up("Arlowe-Setup-ab12", PSK)
    add = fake.argvs()[0]
    assert add[2:4] == ["save", "no"]
    assert fake.profiles()[0]["save"] == "no"


def test_no_secret_in_argv(fake):
    seen = []

    def runner(argv, input=None):
        seen.append(input)
        return netman._default_runner(argv, input=input)

    nm = NetMan(runner=runner, nmcli=str(FAKE))
    nm.ap_up("Arlowe-Setup-ab12", PSK)
    (ap,) = fake.profiles()
    assert ap["name"] == "arlowe-setup" and ap["secret_supplied"] is True
    assert seen == [None, b"802-11-wireless-security.psk:" + PSK.encode() + b"\n"]
    nm.ap_down()
    assert not any(PSK in arg for argv in fake.argvs() for arg in argv)
    assert fake.argvs()[1][-2:] == ["passwd-file", "/dev/stdin"]


def test_ap_addressed_by_uuid(nm, fake):
    nm.ap_up("Arlowe-Setup-ab12", PSK)
    nm.ap_down()
    add, up, down, delete = fake.argvs()
    u = add[add.index("connection.uuid") + 1]
    assert uuid.UUID(u).version == 4
    for argv in (up, down, delete):
        assert argv[2:4] == ["uuid", u]
        assert "arlowe-setup" not in argv


def test_wifi_profiles_and_delete(nm, fake):
    nm.ap_up("Arlowe-Setup-ab12", PSK)
    (u,) = nm.wifi_profiles()
    assert fake.argvs()[-1] == ["-t", "-f", "UUID,TYPE", "connection", "show"]
    nm.delete_profile(u)
    assert fake.argvs()[-1] == ["connection", "delete", "uuid", u]
    assert nm.wifi_profiles() == []
    nm.delete_profile(u)


def test_no_shell(fake, monkeypatch):
    calls = []
    real = subprocess.run

    def spy(*args, **kwargs):
        calls.append((args, kwargs))
        return real(*args, **kwargs)

    monkeypatch.setattr(netman.subprocess, "run", spy)
    nm = NetMan(nmcli=str(FAKE))
    nm.radio_on()
    nm.scan()
    nm.ap_up("Arlowe-Setup-ab12", PSK)
    nm.wifi_profiles()
    nm.ap_down()
    assert len(calls) == 7
    for args, kwargs in calls:
        assert isinstance(args[0], list) and all(isinstance(a, str) for a in args[0])
        assert not kwargs.get("shell")


def test_secrets_not_logged(nm, fake, caplog):
    caplog.set_level(logging.DEBUG)
    nm.ap_up("Arlowe-Setup-ab12", PSK)
    nm.ap_down()
    fake.scenario(ap_up="fail")
    with pytest.raises(netman.NetManError) as exc:
        nm.ap_up("Arlowe-Setup-ab12", PSK)
    assert caplog.records
    assert PSK not in caplog.text and PSK not in str(exc.value)
