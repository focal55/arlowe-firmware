"""SC2 and SC3 end to end, before any hardware: only the radio and systemd are faked.

Run from repo root (the image's Python packages plus python3-botocore):
    PYTHONPATH=runtime:runtime/lib python3 -m pytest tests/phase-8/test_pairing_e2e.py -q \
        --import-mode=importlib
"""
import json
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
