"""SC2 and SC3 end to end, before any hardware: only the radio and systemd are faked.

Run from repo root (the image's Python packages plus python3-botocore):
    PYTHONPATH=runtime:runtime/lib python3 -m pytest tests/phase-8/test_pairing_e2e.py -q \
        --import-mode=importlib
"""
import json
import logging
import os
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import e2e_harness  # noqa: E402
from e2e_harness import HOME_PSK, REPO  # noqa: E402

from argon2 import PasswordHasher  # noqa: E402
from cryptography import x509  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec  # noqa: E402

import yaml  # noqa: E402

from pair.commit import RUNTIME_UNITS  # noqa: E402
from pair.errors import MESSAGES, ErrorKind  # noqa: E402

PASSWORD = "dash-pass-99"


@pytest.fixture
def w(tmp_path, monkeypatch):
    world = e2e_harness.World(tmp_path, monkeypatch)
    yield world
    world.close()


def verify_issued_by(cert, ca):
    ca.public_key().verify(cert.signature, cert.tbs_certificate_bytes,
                           ec.ECDSA(cert.signature_hash_algorithm))


def assert_paired(w):
    w.thread.join(10)
    assert w.rc == [0]
    ident = w.identity_dir
    verify_issued_by(x509.load_pem_x509_certificate((ident / "device.crt").read_bytes()),
                     x509.load_pem_x509_certificate((w.ca_dir / "ca.pem").read_bytes()))
    claim = w.claim()
    assert (claim["state"], claim["device_id"]) == ("bound", w.device_id)
    assert "127.0.1.1\tkitchen-test" in (w.root / "etc/hosts").read_text().splitlines()
    env = {**os.environ, "ARLOWE_CONFIG_PATH": str(w.config),
           "ARLOWE_DEFAULTS_PATH": str(REPO / "config/defaults.yml"),
           "ARLOWE_SCHEMA_PATH": str(REPO / "config/schema.yml")}
    subprocess.run([sys.executable, "-m", "arlowe_config_validate"], env=env, check=True,
                   cwd=REPO / "runtime/lib")
    config = yaml.safe_load(w.config.read_text())
    assert config["device"]["hostname"] == "kitchen-test"
    assert config["identity"]["provisioning_url"] == w.url
    cred = json.loads((w.root / "var/lib/arlowe/dashboard/owner-credential.json").read_text())
    assert PasswordHasher().verify(cred["hash"], PASSWORD)


def test_happy_path(w):
    w.start_app()
    assert w.submit() == "paired"
    assert_paired(w)
    events = w.lines_of(w.events)
    commit = events.index("systemctl start arlowe-pair-commit.service |config=absent")
    paired = events.index("display Paired / Open / http://kitchen-test.local:3000 / or / "
                          "192.168.1.23")
    close = events.index("display close")
    starts = [e for e in events if e.startswith("systemctl start --no-block")]
    assert starts == ["systemctl start --no-block %s |config=present" % " ".join(RUNTIME_UNITS)]
    assert commit < paired < close < events.index(starts[0])


UNMINTED = "ZZZZZ-ZZZZZ-ZZZZZ-ZZZZZ"
FAILURES = {
    "wifi_rejected": lambda w: w.submit(psk="wrong-psk-9999"),
    "server_unreachable": lambda w: (w.stop_broker(), w.submit())[1],
    "claim_rejected": lambda w: w.submit(code=UNMINTED),
    "cert_failed": lambda w: (w.stop_broker(), w.start_broker(fail=True), w.submit())[2],
}


def assert_ap_restored(w):
    wifi = [p for p in w.nm_profiles() if p["type"] == "802-11-wireless"]
    assert [(p["name"], p["save"], p["ap"], p["active"], p["secret_supplied"]) for p in wifi] \
        == [("arlowe-setup", "no", True, True, True)]
    argvs = w.nm_argvs()
    ap = wifi[0]["uuid"]
    add = next(a for a in argvs if a[:2] == ["connection", "add"] and ap in a)
    assert add[add.index("ssid") + 1] == w.session[0]
    assert [a for a in argvs if ap in a][-1] == ["connection", "up", "uuid", ap,
                                                 "passwd-file", "/dev/stdin"]
    assert (w.app.session.ssid, w.app.session.psk) == w.session


@pytest.mark.parametrize("kind", FAILURES)
def test_failure_is_reported_and_recoverable(w, kind):
    assert len({MESSAGES[ErrorKind(k)] for k in FAILURES}) == len(FAILURES)
    w.start_app()
    assert FAILURES[kind](w) == "error"
    message = MESSAGES[ErrorKind(kind)]
    assert w.portal_status() == {"status": "error", "error_kind": kind, "message": message}
    assert w.display.screens[-1] == ["Setup error", message]
    assert_ap_restored(w)
    assert not w.config.exists()
    assert w.claim()["state"] == "unused"


def pair_after_wrong_psk(w):
    w.start_app()
    assert w.submit(psk="wrong-psk-9999") == "error"
    assert w.submit(psk=HOME_PSK, password="", code="") == "paired"
    assert_paired(w)


def test_correct_and_resubmit(w):
    pair_after_wrong_psk(w)
    issued = [x for x in w.lines_of(w.broker_log) if "POST /v1/certificates device=" in x]
    assert len(issued) == 1 and "-> 200" in issued[0]


def test_reset_revokes_against_tls_broker(w):
    w.start_app()
    assert w.submit() == "paired"
    assert_paired(w)
    res = w.reset()
    assert res.returncode == 0, res.stderr
    ledger = w.root / "var/lib/arlowe/reset-ledger"
    assert json.loads(w.lines_of(ledger / "resets.log")[-1])["revoke"] == "ok"
    assert w.lines_of(ledger / "orphaned-certs.jsonl") == []
    assert w.claim()["state"] == "unused"
    assert any("POST /v1/certificates/revoke device=%s" % w.device_id in x and "-> 200" in x
               for x in w.lines_of(w.broker_log))
    assert not w.config.exists()


def test_no_secret_in_logs(w, caplog):
    caplog.set_level(logging.DEBUG)
    pair_after_wrong_psk(w)
    assert w.reset().returncode == 0
    streams = w.streams() + caplog.text
    assert w.device_id in streams and "pairing: paired" in caplog.text
    secrets = {"wrong-psk-9999", HOME_PSK, PASSWORD, w.code, w.code.replace("-", ""),
               w.session[1]}
    assert [line for line in streams.splitlines() if any(s in line for s in secrets)] == []
