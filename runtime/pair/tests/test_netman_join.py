"""
Home-network join against the scripted fake-nmcli.

Run from repo root:
    PYTHONPATH=runtime:runtime/lib python3 -m pytest runtime/pair/tests/test_netman_join.py -q
"""

import json
import logging
import uuid
from pathlib import Path

import pytest

from pair import netman
from pair.errors import ErrorKind, JoinError
from pair.netman import NetMan, passwd_line

FAKE = Path(__file__).resolve().parent / "fixtures" / "fake-nmcli"
PSK = "hunter2-home-psk"
ADVERSARIAL = " a\\b:#c "


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
def stdin_seen():
    return []


@pytest.fixture
def nm(fake, stdin_seen):
    def runner(argv, input=None):
        stdin_seen.append(input)
        return netman._default_runner(argv, input=input)

    return NetMan(runner=runner, nmcli=str(FAKE))


def _after(argv, word):
    return argv[argv.index(word) + 1]


def test_join_success(nm, fake):
    fake.scenario(join={"correct_psk": PSK})
    nm.join("Home", PSK)
    add, up = fake.argvs()
    u = _after(add, "connection.uuid")
    assert uuid.UUID(u).version == 4
    assert _after(add, "con-name") == "Home" and _after(add, "ssid") == "Home"
    assert _after(add, "wifi-sec.key-mgmt") == "wpa-psk"
    assert _after(add, "wifi-sec.psk-flags") == "0"
    assert "wifi-sec.psk" not in add
    assert up == ["--wait", "45", "connection", "up", "uuid", u,
                  "passwd-file", "/dev/stdin"]
    (p,) = fake.profiles()
    assert p["name"] == "Home" and p["uuid"] == u and p["active"] is True
    assert p["secret_supplied"] is True and p["psk_flags"] == 0


def test_adversarial_psk_round_trips(nm, fake):
    assert passwd_line("802-11-wireless-security.psk", ADVERSARIAL) == \
        b"802-11-wireless-security.psk:\\ a\\\\b:#c\\ \n"
    for bad in ("a\nb", "a\rb", "a\0b"):
        with pytest.raises(ValueError):
            passwd_line("802-11-wireless-security.psk", bad)
    fake.scenario(join={"correct_psk": ADVERSARIAL})
    nm.join("Home", ADVERSARIAL)
    assert fake.profiles()[0]["active"] is True


def test_dash_ssid(nm, fake):
    fake.scenario(join={"correct_psk": PSK})
    nm.join("-id", PSK)
    add = fake.argvs()[0]
    assert _after(add, "con-name") == "-id" and _after(add, "ssid") == "-id"
    fake.scenario(join={"exit": 4, "stderr": "Connection activation failed: (7) x"})
    with pytest.raises(JoinError):
        nm.join("-id", "wrong-psk")
    delete = fake.argvs()[-1]
    u = _after(fake.argvs()[-3], "connection.uuid")
    assert delete == ["connection", "delete", "uuid", u]
    for argv in fake.argvs():
        if argv[:2] != ["connection", "add"]:
            assert "-id" not in argv
    assert [p["name"] for p in fake.profiles()] == ["-id"]


def test_no_secret_in_argv(nm, fake, stdin_seen):
    fake.scenario(join={"correct_psk": PSK})
    nm.join("Home", PSK)
    fake.scenario(join={"correct_psk": "something-else"})
    with pytest.raises(JoinError):
        nm.join("Home2", PSK)
    assert not any(PSK in arg for argv in fake.argvs() for arg in argv)
    assert stdin_seen.count(passwd_line("802-11-wireless-security.psk", PSK)) == 2


def test_wrong_psk_rejected(nm, fake):
    fake.scenario(join={"correct_psk": PSK})
    with pytest.raises(JoinError) as exc:
        nm.join("Home", "not-the-psk")
    assert exc.value.kind is ErrorKind.wifi_rejected
    assert fake.profiles() == []


@pytest.mark.parametrize("stderr, kind", [
    ("Connection activation failed: (53) The Wi-Fi network could not be found.",
     ErrorKind.wifi_not_found),
    ("No network with SSID 'Home' found.", ErrorKind.wifi_not_found),
    ("Connection activation failed: (3) No reason given.", ErrorKind.wifi_failed),
])
def test_failure_classified_and_cleaned(nm, fake, stderr, kind):
    fake.scenario(join={"exit": 4, "stderr": stderr})
    with pytest.raises(JoinError) as exc:
        nm.join("Home", PSK)
    assert exc.value.kind is kind
    assert fake.profiles() == []


def test_open_network(nm, fake, stdin_seen):
    nm.join("Cafe", "")
    add, up = fake.argvs()
    assert not any(a.startswith("wifi-sec") for a in add)
    assert "passwd-file" not in up
    assert stdin_seen == [None, None]
    assert fake.profiles()[0]["active"] is True


def test_saved_ssid_profile_deletes_by_uuid(nm, fake):
    nm.join("-id", PSK)
    u = fake.profiles()[0]["uuid"]
    nm.saved_ssid_profile("-id")
    assert fake.argvs()[-1] == ["connection", "delete", "uuid", u]
    assert fake.profiles() == []
    nm.saved_ssid_profile("-id")


def test_join_secrets_not_logged(nm, fake, caplog):
    caplog.set_level(logging.DEBUG)
    nm.join("Home", PSK)
    fake.scenario(join={"correct_psk": "other"})
    with pytest.raises(JoinError) as exc:
        nm.join("Home2", PSK)
    assert caplog.records
    assert PSK not in caplog.text and PSK not in str(exc.value)
