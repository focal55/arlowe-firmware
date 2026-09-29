"""Factory reset engine (runtime/cli/factory-reset) in a fixture root with PATH shims."""

import json
import os
import shutil
import stat
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / "runtime" / "cli" / "factory-reset"
STEP_COUNT = 9
WIFI = {"wifi-home", "wifi-cafe"}
NM_LIST = "wifi-home:802-11-wireless\neth-lan:802-3-ethernet\nwifi-cafe:802-11-wireless\n"
SHIM = """#!/bin/sh
cfg=absent; [ -e "$ARLOWE_ROOT/etc/arlowe/config.yml" ] && cfg=present
conv=absent; [ -e "$ARLOWE_ROOT/var/lib/arlowe/conversations/c1.json" ] && conv=present
echo "$(basename "$0") $* |config=$cfg conv=$conv" >> "$SHIM_LOG"
case "$(basename "$0") $*" in "nmcli -t -f UUID,TYPE connection show") cat "$NM_LIST";; esac
"""
# Owners and modes from scripts/provision/install-arlowe-fs.sh; identity is emptied by
# arlowe-identity, the rest by the helper.
SKELETON = {
    "conversations": 0o700, "wake-word": 0o750, "state": 0o750, "dashboard": 0o750,
    "dashboard/cache": 0o750, "logs": 0o750, "cache": 0o750, "cache/huggingface": 0o750,
    **{f"logs/{s}": 0o750 for s in ("voice", "face", "stt", "tts", "llm", "dashboard")},
}
POPULATED = ["conversations/c1.json", "wake-word/model.onnx", "state/sub/s.json",
             "dashboard/owner-credential.json", "dashboard/session.key", "dashboard/cache/x",
             "logs/voice/voice_1.log", "logs/top.log", "cache/huggingface/hub/m.bin"]
SURVIVORS = ["var/lib/arlowe/reset-ledger/resets.log", "opt/arlowe/models/marker",
             "var/lib/arlowe/.firstboot-done", "var/lib/arlowe/.models-grow-done"]
OLD_AUDIT = '{"at": "2026-01-01T00:00:00Z", "trigger": "button", "revoke": "ok"}\n'


def _write(path, text="x", mode=0o640):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(mode)


@pytest.fixture
def env(tmp_path):
    root = tmp_path / "root"
    state = root / "var/lib/arlowe"
    for rel, mode in {**SKELETON, "identity": 0o700}.items():
        (state / rel).mkdir(parents=True, exist_ok=True)
        (state / rel).chmod(mode)
    for rel in POPULATED:
        _write(state / rel)
    (state / "state/link").symlink_to(root / "opt/arlowe/models/marker")
    _write(state / "identity/device.key", "KEY", 0o600)
    _write(state / "identity/identity.json", "{}", 0o600)
    _write(root / "etc/arlowe/config.yml", "identity: {}\n")
    _write(root / "etc/hosts", "127.0.0.1\tlocalhost\n127.0.1.1\tarlowe-abcd\n", 0o644)
    for name in ("home.nmconnection", "cafe.nmconnection", "lan.nmconnection"):
        _write(root / "etc/NetworkManager/system-connections" / name, "psk=x", 0o600)
    for name in ("seen-bssids", "timestamps", "internal-abc-wlan0.lease", "NetworkManager.state"):
        _write(root / "var/lib/NetworkManager" / name)
    for rel in SURVIVORS:
        _write(root / rel, OLD_AUDIT if rel.endswith("resets.log") else "keep")
    (state / "reset-ledger").chmod(0o700)
    bindir = tmp_path / "bin"
    bindir.mkdir()
    for name in ("systemctl", "nmcli", "journalctl", "hostnamectl", "arlowe-identity"):
        _write(bindir / name, SHIM, 0o755)
    _write(tmp_path / "nm-list", NM_LIST)
    return {"root": root, "log": tmp_path / "calls.log", "vars": {
        "PATH": f"{bindir}:{os.environ['PATH']}", "ARLOWE_ROOT": str(root),
        "SHIM_LOG": str(tmp_path / "calls.log"), "NM_LIST": str(tmp_path / "nm-list")}}


def run(env, *args, **extra):
    result = subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True,
                            env={**env["vars"], **extra})
    return result.returncode


def calls(env):
    log = env["log"]
    return [line.rstrip("\n") for line in log.read_text().splitlines()] if log.exists() else []


def cmds(env):
    return [c.split(" |")[0] for c in calls(env)]


def snapshot(root):
    """Every path with its mode and file content, minus the audit log (it carries a time)."""
    out = {}
    for p in sorted(root.rglob("*")):
        rel = str(p.relative_to(root))
        if rel.endswith("resets.log"):
            continue
        st = p.lstat()
        body = p.read_text() if stat.S_ISREG(st.st_mode) else os.readlink(p) if p.is_symlink() else None
        out[rel] = (stat.S_IMODE(st.st_mode), body)
    return out


def audit_lines(env):
    return (env["root"] / "var/lib/arlowe/reset-ledger/resets.log").read_text().splitlines()


def test_full_run_wipes_everything_listed(env):
    assert run(env, "--trigger", "dashboard") == 0
    root, state = env["root"], env["root"] / "var/lib/arlowe"
    c = cmds(env)
    assert not (root / "etc/arlowe/config.yml").exists()
    assert "arlowe-identity reset --force" in c
    deleted = {u for x in c if x.startswith("nmcli connection delete") for u in x.split()[3:]}
    assert deleted == WIFI
    left = sorted(p.name for p in (root / "var/lib/NetworkManager").iterdir())
    assert left == ["NetworkManager.state"]
    under = {str(p.relative_to(state)) for d in SKELETON if "/" not in d for p in (state / d).rglob("*")}
    assert under == {d for d in SKELETON if "/" in d}
    for rel, mode in SKELETON.items():
        assert stat.S_IMODE((state / rel).stat().st_mode) == mode, rel
    j = [x for x in c if x.startswith("journalctl")]
    assert j == ["journalctl --rotate", "journalctl --vacuum-time=1s"]
    assert "hostnamectl set-hostname arlowe" in c
    hosts = (root / "etc/hosts").read_text().splitlines()
    assert "127.0.1.1\tarlowe" in hosts and "127.0.0.1\tlocalhost" in hosts
    assert not any("arlowe-abcd" in h for h in hosts)
    new = json.loads(audit_lines(env)[-1])
    assert set(new) == {"at", "trigger", "revoke"}
    assert (new["trigger"], new["revoke"]) == ("dashboard", "skipped")
    assert not (state / "reset-ledger/in-progress").exists()
    assert c[-1] == "systemctl reboot"


def test_no_reboot_skips_reboot(env):
    assert run(env, "--trigger", "button", "--no-reboot") == 0
    assert "systemctl reboot" not in cmds(env)
    assert json.loads(audit_lines(env)[-1])["trigger"] == "button"


def test_survivors_untouched(env):
    assert run(env, "--trigger", "dashboard", "--no-reboot") == 0
    root = env["root"]
    for rel in SURVIVORS[1:]:
        assert (root / rel).read_text() == "keep", rel
    ledger = root / "var/lib/arlowe/reset-ledger"
    assert audit_lines(env)[0] == OLD_AUDIT.strip() and len(audit_lines(env)) == 2
    assert stat.S_IMODE(ledger.stat().st_mode) == 0o700


def test_stop_then_commit_then_wipe(env):
    assert run(env, "--trigger", "dashboard", "--no-reboot") == 0
    c = calls(env)
    assert c[0].startswith("systemctl stop ") and "config=present conv=present" in c[0]
    stopped = set(c[0].split(" |")[0].split()[2:])
    assert stopped == {"arlowe-dashboard.service", "arlowe-face.service", "arlowe-voice.service",
                       "qwen-api.service", "qwen-tokenizer.service", "whisper-stt.service",
                       "arlowe-pair.service"}
    assert all("config=absent" in x for x in c[1:])
    assert any("conv=present" in x for x in c[1:])


def test_ledger_created_on_demand(env):
    shutil.rmtree(env["root"] / "var/lib/arlowe/reset-ledger")
    assert run(env, "--trigger", "dashboard", "--no-reboot") == 0
    ledger = env["root"] / "var/lib/arlowe/reset-ledger"
    assert stat.S_IMODE(ledger.stat().st_mode) == 0o700 and len(audit_lines(env)) == 1


@pytest.mark.parametrize("step", range(1, STEP_COUNT + 1))
def test_resume_after_every_step(env, step):
    marker = env["root"] / "var/lib/arlowe/reset-ledger/in-progress"
    assert run(env, "--trigger", "dashboard", "--no-reboot", ARLOWE_RESET_FAIL_AFTER=str(step)) != 0
    assert marker.exists()
    assert json.loads(marker.read_text())["trigger"] == "dashboard"
    first = len(calls(env))
    assert run(env, "--resume", "--no-reboot") == 0
    assert not marker.exists()
    resumed = cmds(env)[first:]
    if step > 1:
        assert not any(x.startswith("systemctl stop") for x in resumed)
    assert run(env, "--resume", "--no-reboot") == 0
    new = [json.loads(x) for x in audit_lines(env)[1:]]
    assert [(n["trigger"], n["revoke"]) for n in new] == [("dashboard", "skipped")]


def test_resume_matches_clean_run(env, tmp_path):
    """Every interrupted-then-resumed run ends in the clean run's state and call set."""
    pristine = tmp_path / "pristine"
    shutil.copytree(env["root"], pristine, symlinks=True)
    assert run(env, "--trigger", "dashboard", "--no-reboot") == 0
    want_state, want_calls = snapshot(env["root"]), set(cmds(env))
    for step in range(1, STEP_COUNT + 1):
        shutil.rmtree(env["root"])
        shutil.copytree(pristine, env["root"], symlinks=True)
        env["log"].unlink()
        assert run(env, "--trigger", "dashboard", "--no-reboot",
                   ARLOWE_RESET_FAIL_AFTER=str(step)) != 0
        assert run(env, "--resume", "--no-reboot") == 0
        assert snapshot(env["root"]) == want_state, step
        assert set(cmds(env)) == want_calls, step


def test_resume_without_marker_is_noop(env):
    before = snapshot(env["root"])
    assert run(env, "--resume") == 0
    assert calls(env) == [] and snapshot(env["root"]) == before


@pytest.mark.parametrize("args", [["--trigger", "ssh"], ["--trigger", ""], []])
def test_bad_trigger_exits_2(env, args):
    before = snapshot(env["root"])
    assert run(env, *args) == 2
    assert calls(env) == [] and snapshot(env["root"]) == before
