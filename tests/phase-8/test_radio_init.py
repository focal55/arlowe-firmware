"""radio-init against a fixture sysfs and PATH shims for iw, nmcli and nft."""
import os
import stat
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "runtime" / "cli" / "radio-init"

SHIM = """#!/bin/sh
echo "$(basename "$0") $*" >> "{log}"
if [ "$(basename "$0")" = nmcli ] && [ "$1" = -t ]; then
    echo "wlan0:${{SHIM_WLAN0_STATE:-disconnected}}"
fi
if [ "$(basename "$0")" = iw ] && [ "$*" = "reg set ${{SHIM_IW_FAIL_COUNTRY:-none}}" ]; then
    echo "iw: simulated failure" >&2
    exit 1
fi
if [ "$(basename "$0")" = nft ]; then
    exit "${{SHIM_NFT_RC:-0}}"
fi
exit 0
"""


def _rfkill(root: Path, name: str, kind: str) -> Path:
    d = root / "sys" / "class" / "rfkill" / name
    d.mkdir(parents=True)
    (d / "type").write_text(kind + "\n")
    (d / "soft").write_text("1\n")
    return d / "soft"


@pytest.fixture
def env(tmp_path):
    root = tmp_path / "root"
    root.mkdir()
    shims = tmp_path / "bin"
    shims.mkdir()
    log = tmp_path / "calls.log"
    log.touch()
    for tool in ("iw", "nmcli", "nft"):
        p = shims / tool
        p.write_text(SHIM.format(log=log))
        p.chmod(p.stat().st_mode | stat.S_IXUSR)
    e = {
        "PATH": f"{shims}:/usr/bin:/bin",
        "ARLOWE_ROOT": str(root),
        "ARLOWE_RADIO_WAIT": "1",
    }
    return root, log, e


def run(e, **extra):
    return subprocess.run([sys.executable, str(SCRIPT)], env={**e, **extra},
                          capture_output=True, text=True, timeout=30)


def test_unblocks_wlan_only(env):
    root, _, e = env
    wlan = _rfkill(root, "rfkill0", "wlan")
    bt = _rfkill(root, "rfkill1", "bluetooth")
    r = run(e)
    assert r.returncode == 0, r.stderr
    assert wlan.read_text().strip() == "0"
    assert bt.read_text().strip() == "1"


def test_sets_regulatory_domain(env):
    root, log, e = env
    _rfkill(root, "rfkill0", "wlan")
    assert run(e).returncode == 0
    assert "iw reg set US" in log.read_text().splitlines()
    log.write_text("")
    assert run(e, ARLOWE_WIFI_COUNTRY="DE").returncode == 0
    assert "iw reg set DE" in log.read_text().splitlines()


def test_enables_networkmanager_wifi(env):
    root, log, e = env
    _rfkill(root, "rfkill0", "wlan")
    assert run(e).returncode == 0
    assert "nmcli radio wifi on" in log.read_text().splitlines()


def test_loads_setup_ap_forward_drop(env):
    root, log, e = env
    _rfkill(root, "rfkill0", "wlan")
    assert run(e).returncode == 0
    ruleset = root / "etc" / "arlowe" / "nftables" / "arlowe-setup-ap.nft"
    assert f"nft -f {ruleset}" in log.read_text().splitlines()

    r = run(e, SHIM_NFT_RC="1")
    assert r.returncode == 1
    assert "firewall" in r.stderr


def test_wlan0_stuck_unavailable_fails(env):
    root, _, e = env
    _rfkill(root, "rfkill0", "wlan")
    r = run(e, SHIM_WLAN0_STATE="unavailable")
    assert r.returncode == 1
    assert "unavailable" in r.stderr


def test_no_wlan_radio_fails(env):
    root, log, e = env
    _rfkill(root, "rfkill1", "bluetooth")
    r = run(e)
    assert r.returncode == 1
    assert "no wlan rfkill" in r.stderr
    assert log.read_text() == ""


def _calls(log):
    return log.read_text().splitlines()


def test_regdomain_runs_after_wifi_is_enabled(env):
    root, log, e = env
    _rfkill(root, "rfkill0", "wlan")
    assert run(e).returncode == 0
    calls = _calls(log)
    enable = calls.index("nmcli radio wifi on")
    reg = [i for i, c in enumerate(calls) if c.startswith("iw reg set ")]
    assert reg, calls
    assert min(reg) > enable, calls


def test_regdomain_forces_a_change_through_world_first(env):
    root, log, e = env
    _rfkill(root, "rfkill0", "wlan")
    assert run(e, ARLOWE_WIFI_COUNTRY="GB").returncode == 0
    reg = [c for c in _calls(log) if c.startswith("iw reg set ")]
    assert reg == ["iw reg set 00", "iw reg set GB"]
    calls = _calls(log)
    assert calls.index("iw reg set GB") == calls.index("iw reg set 00") + 1


def test_world_regdomain_failure_is_fatal(env):
    root, log, e = env
    _rfkill(root, "rfkill0", "wlan")
    r = run(e, SHIM_IW_FAIL_COUNTRY="00")
    assert r.returncode == 1
    assert "regulatory domain" in r.stderr
    calls = _calls(log)
    assert "iw reg set US" not in calls
    assert not any(c.startswith("nft ") for c in calls)
    assert not any(c.startswith("nmcli -t") for c in calls)


def test_country_regdomain_failure_is_fatal(env):
    root, log, e = env
    _rfkill(root, "rfkill0", "wlan")
    r = run(e, SHIM_IW_FAIL_COUNTRY="US")
    assert r.returncode == 1
    assert "regulatory domain" in r.stderr
    calls = _calls(log)
    assert not any(c.startswith("nft ") for c in calls)
    assert not any(c.startswith("nmcli -t") for c in calls)


def test_rfkill_unblock_precedes_wifi_enable(env):
    root, log, e = env
    soft = _rfkill(root, "rfkill0", "wlan")
    snapshot = log.parent / "soft-at-enable"
    nmcli = Path(e["PATH"].split(":")[0]) / "nmcli"
    nmcli.write_text(SHIM.format(log=log).replace(
        "exit 0\n",
        f'[ "$*" = "radio wifi on" ] && cat "{soft}" > "{snapshot}"\nexit 0\n'))
    assert run(e).returncode == 0
    assert snapshot.read_text().strip() == "0"
