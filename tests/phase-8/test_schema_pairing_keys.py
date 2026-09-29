"""The config schema accepts what pairing writes and nothing else.

Each case runs the validator in a subprocess because arlowe_config reads its
paths from the environment at import time. That is also how the pairing daemon
validates a candidate overlay before it commits one.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[2]

IDENTITY = {
    "provisioning_url": "https://broker.example.invalid",
    "credentials_endpoint": "",
    "role_alias": "",
    "poll_interval_seconds": 3600,
}


def _env(overlay_path):
    env = dict(os.environ)
    env.update(
        PYTHONPATH=str(REPO / "runtime" / "lib"),
        ARLOWE_SCHEMA_PATH=str(REPO / "config" / "schema.yml"),
        ARLOWE_DEFAULTS_PATH=str(REPO / "config" / "defaults.yml"),
        ARLOWE_CONFIG_PATH=str(overlay_path),
    )
    return env


def _validate(tmp_path, overlay):
    path = tmp_path / "config.yml"
    path.write_text(yaml.safe_dump(overlay))
    proc = subprocess.run(
        [sys.executable, "-m", "arlowe_config_validate"],
        env=_env(path), capture_output=True, text=True,
    )
    return proc.returncode, proc.stderr


def test_pairing_overlay_validates(tmp_path):
    rc, err = _validate(tmp_path, {
        "device": {"hostname": "kitchen-test", "display_name": "Kitchen Test"},
        "owner": {"paired_at": "2026-09-28T12:00:00Z"},
        "network": {"wifi_label": "HomeNet"},
        "identity": IDENTITY,
    })
    assert rc == 0, err


def test_display_name_bounds(tmp_path):
    for name in ("", "x" * 33):
        rc, err = _validate(tmp_path, {"device": {"hostname": "h", "display_name": name}})
        assert rc == 78, f"{name!r} accepted"
        assert "device" in err


def test_owner_rejects_unknown_key(tmp_path):
    # The owner's password hash lives outside the overlay (ADR-0012); this
    # fails if a later edit tries to put it here.
    rc, err = _validate(tmp_path, {"owner": {"password": "x"}})
    assert rc == 78
    assert "owner" in err


def test_network_rejects_psk(tmp_path):
    rc, err = _validate(tmp_path, {"network": {"psk": "x"}})
    assert rc == 78
    assert "network" in err


def test_legacy_overlay_still_valid(tmp_path):
    rc, err = _validate(tmp_path, {"device": {"hostname": "arlowe-legacy"}})
    assert rc == 0, err


def test_defaults_carry_display_name(tmp_path):
    proc = subprocess.run(
        [sys.executable, "-c",
         "import json, arlowe_config; print(json.dumps(arlowe_config.load()['device']))"],
        env=_env(tmp_path / "absent.yml"), capture_output=True, text=True,
    )
    assert proc.returncode == 0, proc.stderr
    assert json.loads(proc.stdout).get("display_name") == "Arlowe"
