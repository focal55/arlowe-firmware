"""factory-reset's revoke step: revoke first when possible, record the orphan when not."""

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "runtime" / "cli" / "factory-reset"
CERT = {"certificate_id": "c0ffee", "thing_name": "arlowe-thing-1", "device_id": "dev-1"}
PEM = "-----BEGIN CERTIFICATE-----\nMIIBlocal\n-----END CERTIFICATE-----\n"
SHIM = """#!/bin/sh
cfg=absent; [ -e "$ARLOWE_ROOT/etc/arlowe/config.yml" ] && cfg=present
echo "$(basename "$0") $* |config=$cfg ca=${ARLOWE_BROKER_CA_BUNDLE:-}" >> "$SHIM_LOG"
case "$(basename "$0") $1" in
  "nmcli -t") printf 'wifi-home:802-11-wireless\\n';;
  "arlowe-identity revoke")
    [ -n "$ARLOWE_BROKER_CA_BUNDLE" ] && cp "$ARLOWE_BROKER_CA_BUNDLE" "$SHIM_LOG.ca"
    case "$SHIM_REVOKE" in
      ok) echo '{"ok": true, "certificate_id": "c0ffee"}';;
      hang) sleep 30;;
      *) echo '{"ok": false, "exit": 4, "error": "unavailable", "http_status": 503}'; exit 4;;
    esac;;
esac
"""


@pytest.fixture
def env(tmp_path):
    """Trimmed copy of tests/phase-8/test_factory_reset.py's fixture root."""
    root = tmp_path / "root"
    state = root / "var/lib/arlowe"
    for rel in ("conversations", "identity", "state", "reset-ledger"):
        (state / rel).mkdir(parents=True)
    (state / "reset-ledger").chmod(0o700)
    (state / "conversations/c1.json").write_text("x")
    (state / "identity/identity.json").write_text(json.dumps(CERT))
    (root / "etc/arlowe").mkdir(parents=True)
    (root / "etc/arlowe/config.yml").write_text(
        "identity:\n  provisioning_url: https://broker.example.com\n")
    (root / "etc/hosts").write_text("127.0.1.1\tarlowe-abcd\n")
    bindir = tmp_path / "bin"
    bindir.mkdir()
    for name in ("systemctl", "nmcli", "journalctl", "hostnamectl", "arlowe-identity"):
        (bindir / name).write_text(SHIM)
        (bindir / name).chmod(0o755)
    return {"root": root, "log": tmp_path / "calls.log", "vars": {
        "PATH": f"{bindir}:{os.environ['PATH']}", "ARLOWE_ROOT": str(root),
        "ARLOWE_LIB": str(REPO / "runtime/lib"), "SHIM_LOG": str(tmp_path / "calls.log")}}


def reset(env, **extra):
    result = subprocess.run([sys.executable, str(SCRIPT), "--trigger", "dashboard", "--no-reboot"],
                            capture_output=True, text=True, env={**env["vars"], **extra})
    assert result.returncode == 0, result.stderr
    calls = env["log"].read_text().splitlines()
    ledger = env["root"] / "var/lib/arlowe/reset-ledger"
    orphans = ledger / "orphaned-certs.jsonl"
    return {"calls": calls, "revoke": [c for c in calls if c.startswith("arlowe-identity revoke")],
            "audit": json.loads((ledger / "resets.log").read_text().splitlines()[-1])["revoke"],
            "orphans": [json.loads(x) for x in orphans.read_text().splitlines()]
            if orphans.exists() else []}


def assert_wiped(env, r):
    assert not (env["root"] / "etc/arlowe/config.yml").exists()
    assert not (env["root"] / "var/lib/arlowe/conversations/c1.json").exists()
    assert any(c.startswith("arlowe-identity reset --force") for c in r["calls"])


def test_revoke_ok_runs_before_commit(env):
    r = reset(env, SHIM_REVOKE="ok")
    assert r["audit"] == "ok" and r["orphans"] == []
    assert len(r["revoke"]) == 1 and "config=present" in r["revoke"][0]
    assert r["revoke"][0].startswith("arlowe-identity revoke --json --ca-broker-url "
                                      "https://broker.example.com |")
    assert r["revoke"][0].endswith("ca=")
    assert_wiped(env, r)


def test_broker_file_url_and_ca_are_passed(env):
    fat = env["root"] / "boot/firmware/arlowe-broker.json"
    fat.parent.mkdir(parents=True)
    fat.write_text(json.dumps({"url": "https://10.42.0.1:8443", "ca_bundle_pem": PEM}))
    r = reset(env, SHIM_REVOKE="ok", ARLOWE_BROKER_FILE="/boot/firmware/arlowe-broker.json")
    assert "--ca-broker-url https://10.42.0.1:8443 |" in r["revoke"][0]
    ca = Path(r["revoke"][0].rsplit("ca=", 1)[1])
    assert Path(str(env["log"]) + ".ca").read_text() == PEM
    assert not ca.parent.exists()


@pytest.mark.parametrize("mode,reason", [("fail", "unavailable"), ("hang", "timeout")])
def test_failed_revoke_records_orphan_and_wipes(env, mode, reason):
    r = reset(env, SHIM_REVOKE=mode, ARLOWE_RESET_REVOKE_TIMEOUT="1")
    assert r["audit"] == "failed"
    [orphan] = r["orphans"]
    assert {k: orphan[k] for k in CERT} == CERT and orphan["reason"] == reason
    assert set(orphan) == {*CERT, "at", "reason"}
    assert_wiped(env, r)


def test_no_certificate_is_skipped(env):
    (env["root"] / "var/lib/arlowe/identity/identity.json").write_text('{"device_id": "dev-1"}')
    r = reset(env, SHIM_REVOKE="ok")
    assert r["audit"] == "skipped" and r["revoke"] == [] and r["orphans"] == []


def test_no_broker_url_is_recorded(env):
    (env["root"] / "etc/arlowe/config.yml").write_text("identity:\n  provisioning_url: ''\n")
    r = reset(env, SHIM_REVOKE="ok")
    assert r["audit"] == "failed" and r["revoke"] == []
    assert [o["reason"] for o in r["orphans"]] == ["no_broker_url"]
    assert_wiped(env, r)
