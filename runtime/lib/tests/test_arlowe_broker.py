"""resolve_broker: the one broker lookup pairing and factory reset share."""

import json
import logging
import stat

from arlowe_broker import resolve_broker

PEM = "-----BEGIN CERTIFICATE-----\nMIIBsecretish\n-----END CERTIFICATE-----\n"
FILE_URL = "https://10.42.0.1:8443"
CONFIG_URL = "https://broker.example.com"


def _broker_file(tmp_path, **body):
    f = tmp_path / "arlowe-broker.json"
    f.write_text(json.dumps(body))
    return f


def test_file_wins_and_ca_is_private(tmp_path, caplog):
    caplog.set_level(logging.DEBUG)
    ca_dir = tmp_path / "ca"
    ca_dir.mkdir()
    f = _broker_file(tmp_path, url=FILE_URL, ca_bundle_pem=PEM)
    url, ca_path = resolve_broker(f, CONFIG_URL, ca_dir)
    assert url == FILE_URL
    assert ca_path.parent == ca_dir and ca_path.read_text() == PEM
    assert stat.S_IMODE(ca_path.stat().st_mode) == 0o600
    assert "broker source: file" in caplog.text
    assert "MIIB" not in caplog.text


def test_file_without_ca_uses_system_trust(tmp_path):
    f = _broker_file(tmp_path, url=FILE_URL)
    assert resolve_broker(f, CONFIG_URL, tmp_path) == (FILE_URL, None)


def test_non_https_file_is_rejected(tmp_path, caplog):
    caplog.set_level(logging.DEBUG)
    f = _broker_file(tmp_path, url="http://10.42.0.1:8443", ca_bundle_pem=PEM)
    assert resolve_broker(f, CONFIG_URL, tmp_path) is None
    assert "https" in caplog.text and "MIIB" not in caplog.text
    assert not (tmp_path / "broker-ca.pem").exists()


def test_config_fallback(tmp_path, caplog):
    caplog.set_level(logging.DEBUG)
    assert resolve_broker(tmp_path / "absent.json", CONFIG_URL, tmp_path) == (CONFIG_URL, None)
    assert "broker source: config" in caplog.text


def test_neither_is_none(tmp_path, caplog):
    caplog.set_level(logging.DEBUG)
    assert resolve_broker(tmp_path / "absent.json", "", tmp_path) is None
    assert "broker source: none" in caplog.text
