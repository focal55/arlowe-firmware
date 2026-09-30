"""
Unit tests for pair.commit and pair.credential against a temp root and a
systemctl shim.

Run from repo root:
    PYTHONPATH=runtime:runtime/lib python3 -m pytest runtime/pair/tests/test_commit.py -q
"""

import datetime
import json
import logging
import os
import stat
import subprocess
import sys
from pathlib import Path

import pytest
import yaml
from argon2 import PasswordHasher

from pair import commit as commit_mod
from pair import credential

REPO = Path(__file__).resolve().parents[3]
DEFAULTS = REPO / "config/defaults.yml"
SCHEMA = REPO / "config/schema.yml"
LIB = REPO / "runtime/lib"
SIX = ["arlowe-face.service", "arlowe-voice.service", "arlowe-dashboard.service",
       "qwen-tokenizer.service", "qwen-api.service", "whisper-stt.service"]
FORM = {"ssid": "Home", "psk": "home-wifi-pw-77", "display_name": "Kitchen Pal",
        "slug": "kitchen-pal", "password": "dash-pass-99",
        "claim_code": "ABCDE-FGHJK-MNPQR-STVWX"}
SECRETS = [FORM["psk"], FORM["password"], FORM["claim_code"]]
PROVISIONED = {"device_id": "ab12cd34", "certificate_id": "c" * 64,
               "thing_name": "ab12cd34", "broker_url": "https://broker.example"}
NOW = datetime.datetime(2026, 9, 29, 12, 0, 0, tzinfo=datetime.timezone.utc)

SHIM = """#!/bin/sh
root="{root}"
echo "$* config=$([ -e "$root/etc/arlowe/config.yml" ] && echo yes || echo no)" >> "$root/calls.log"
case "$*" in
  *arlowe-pair-commit.service*)
    cat "$root/run/arlowe-pair/commit-request.json" > "$root/request.seen"
    exit "${{SHIM_COMMIT_RC:-0}}" ;;
esac
exit "${{SHIM_RC:-0}}"
"""


@pytest.fixture
def root(tmp_path, monkeypatch):
    for d in ("etc/arlowe", "run/arlowe-pair", "var/lib/arlowe/dashboard"):
        (tmp_path / d).mkdir(parents=True)
    shim = tmp_path / "systemctl"
    shim.write_text(SHIM.format(root=tmp_path))
    shim.chmod(0o755)
    monkeypatch.setenv("ARLOWE_SCHEMA_PATH", str(SCHEMA))
    monkeypatch.setenv("ARLOWE_DEFAULTS_PATH", str(DEFAULTS))
    return tmp_path


def make(root):
    return commit_mod.Committer(
        etc_dir=root / "etc/arlowe", run_dir=root / "run/arlowe-pair",
        state_dir=root / "var/lib/arlowe/dashboard", systemctl=str(root / "systemctl"),
        defaults_path=DEFAULTS, clock=lambda: NOW)


def calls(root):
    log = root / "calls.log"
    return log.read_text().splitlines() if log.exists() else []


def config(root):
    return root / "etc/arlowe/config.yml"


def test_credential_is_argon2id_0600_and_verifies(tmp_path):
    credential.write_owner_credential(tmp_path, "s3cret pass")
    path = tmp_path / "owner-credential.json"
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    body = json.loads(path.read_text())
    assert set(body) == {"hash", "created_at"}
    assert body["hash"].startswith("$argon2id$v=19$m=65536,t=3,p=4$")
    assert PasswordHasher().verify(body["hash"], "s3cret pass")
    assert b"s3cret pass" not in path.read_bytes()


def test_session_key_is_32_bytes_0600_and_fresh(tmp_path):
    credential.write_session_key(tmp_path)
    path = tmp_path / "session.key"
    first = path.read_bytes()
    assert len(first) == 32
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    credential.write_session_key(tmp_path)
    assert path.read_bytes() != first
    assert list(tmp_path.iterdir()) == [path]


def test_happy_path_commits_without_starting_the_six(root):
    make(root)(dict(FORM), dict(PROVISIONED))
    log = calls(root)
    assert log == ["start arlowe-pair-commit.service config=no"]
    assert json.loads((root / "request.seen").read_text()) == {"display_name": "Kitchen Pal"}
    assert not (root / "run/arlowe-pair/commit-request.json").exists()
    assert config(root).exists()
    state = root / "var/lib/arlowe/dashboard"
    assert (state / "owner-credential.json").exists()
    assert len((state / "session.key").read_bytes()) == 32


def test_start_runtime_starts_all_six_once_and_returns_rc(root, monkeypatch):
    monkeypatch.setenv("SHIM_RC", "3")
    assert make(root).start_runtime() == 3
    log = calls(root)
    assert len(log) == 1
    argv = log[0].split(" config=")[0].split()
    assert argv[:2] == ["start", "--no-block"]
    assert sorted(argv[2:]) == sorted(SIX)


def test_written_config_validates_and_carries_the_pairing_fields(root):
    make(root)(dict(FORM), dict(PROVISIONED))
    env = {**os.environ, "ARLOWE_CONFIG_PATH": str(config(root)), "PYTHONPATH": str(LIB)}
    res = subprocess.run([sys.executable, "-m", "arlowe_config_validate"], env=env,
                         capture_output=True, text=True)
    assert res.returncode == 0, res.stderr
    overlay = yaml.safe_load(config(root).read_text())
    assert overlay["device"] == {"hostname": "kitchen-pal", "display_name": "Kitchen Pal"}
    assert overlay["owner"] == {"paired_at": "2026-09-29T12:00:00Z"}
    assert overlay["network"] == {"wifi_label": "Home"}
    defaults = yaml.safe_load(DEFAULTS.read_text())["identity"]
    assert overlay["identity"] == {**defaults, "provisioning_url": "https://broker.example"}
    assert set(overlay) == {"device", "owner", "network", "identity"}


def test_hostname_helper_failure_raises_and_leaves_unit_unpaired(root, monkeypatch):
    monkeypatch.setenv("SHIM_COMMIT_RC", "3")
    with pytest.raises(commit_mod.CommitError):
        make(root)(dict(FORM), dict(PROVISIONED))
    assert not config(root).exists()
    assert calls(root) == ["start arlowe-pair-commit.service config=no"]
    assert not (root / "run/arlowe-pair/commit-request.json").exists()


def test_validator_failure_raises_and_removes_tmp(root, monkeypatch, tmp_path_factory):
    schema = yaml.safe_load(SCHEMA.read_text())
    del schema["properties"]["owner"]
    strict = tmp_path_factory.mktemp("schema") / "schema.yml"
    strict.write_text(yaml.safe_dump(schema))
    monkeypatch.setenv("ARLOWE_SCHEMA_PATH", str(strict))
    with pytest.raises(commit_mod.CommitError):
        make(root)(dict(FORM), dict(PROVISIONED))
    assert not config(root).exists()
    assert list((root / "etc/arlowe").iterdir()) == []


def test_stale_tmp_from_a_crash_is_overwritten(root):
    (root / "etc/arlowe/config.yml.tmp").write_text("garbage: [\n" * 50)
    make(root)(dict(FORM), dict(PROVISIONED))
    assert "garbage" not in config(root).read_text()
    assert not (root / "etc/arlowe/config.yml.tmp").exists()


def test_long_utf8_ssid_is_truncated_on_a_character_boundary(root):
    ssid = "café" * 8  # 5 bytes each, 40 bytes
    make(root)({**FORM, "ssid": ssid}, dict(PROVISIONED))
    label = yaml.safe_load(config(root).read_text())["network"]["wifi_label"]
    assert len(label.encode()) <= 32
    assert ssid.startswith(label)
    assert label == "café" * 6


def test_config_mode_is_0640(root):
    make(root)(dict(FORM), dict(PROVISIONED))
    assert stat.S_IMODE(config(root).stat().st_mode) == 0o640


def test_no_secret_in_logs_or_files(root, monkeypatch, caplog):
    caplog.set_level(logging.DEBUG)
    make(root)(dict(FORM), dict(PROVISIONED))
    monkeypatch.setenv("SHIM_COMMIT_RC", "4")
    with pytest.raises(commit_mod.CommitError):
        make(root)(dict(FORM), dict(PROVISIONED))
    for secret in SECRETS:
        assert secret not in caplog.text
        for f in root.rglob("*"):
            if f.is_file():
                assert secret.encode() not in f.read_bytes(), f
