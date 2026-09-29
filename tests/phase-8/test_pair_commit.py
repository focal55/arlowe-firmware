"""pair-commit against an ARLOWE_ROOT tree and PATH shims for hostnamectl and systemctl.

Banned names are built from scripts/sanitize/banlist.txt at run time so no
banlist literal is written into this file.
"""
import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "runtime" / "cli" / "pair-commit"
UNIT = REPO_ROOT / "units" / "arlowe-pair-commit.service"
BANLIST = REPO_ROOT / "scripts" / "sanitize" / "banlist.txt"

HOSTS = "127.0.0.1\tlocalhost\n::1\t\tlocalhost ip6-localhost\n127.0.1.1\tarlowe\n# keep me\n"

SHIM = """#!/bin/sh
echo "$(basename "$0") $*" >> "{log}"
[ "$(basename "$0")" = hostnamectl ] && exit "${{SHIM_HOSTNAMECTL_RC:-0}}"
exit 0
"""


@pytest.fixture
def env(tmp_path):
    root = tmp_path / "root"
    (root / "etc").mkdir(parents=True)
    (root / "run" / "arlowe-pair").mkdir(parents=True)
    (root / "etc" / "hosts").write_text(HOSTS)
    shims = tmp_path / "bin"
    shims.mkdir()
    log = tmp_path / "calls.log"
    log.touch()
    for tool in ("hostnamectl", "systemctl"):
        p = shims / tool
        p.write_text(SHIM.format(log=log))
        p.chmod(p.stat().st_mode | stat.S_IXUSR)
    e = {
        "PATH": f"{shims}:/usr/bin:/bin",
        "ARLOWE_ROOT": str(root),
        "ARLOWE_LIB": str(REPO_ROOT / "runtime" / "lib"),
    }
    return root, log, e


def request(root, body):
    p = root / "run" / "arlowe-pair" / "commit-request.json"
    p.write_text(body if isinstance(body, str) else json.dumps(body))
    return p


def run(e, **extra):
    return subprocess.run([sys.executable, str(SCRIPT)], env={**e, **extra},
                          capture_output=True, text=True, timeout=30)


def calls(log):
    return log.read_text().splitlines()


def assert_untouched(root, log):
    assert (root / "etc" / "hosts").read_text() == HOSTS
    assert calls(log) == []


def test_applies_hostname_hosts_and_avahi(env):
    root, log, e = env
    request(root, {"display_name": "Kitchen Test"})
    r = run(e)
    assert r.returncode == 0, r.stderr
    assert calls(log) == [
        "hostnamectl set-hostname kitchen-test",
        "hostnamectl set-hostname --pretty Kitchen Test",
        "systemctl restart avahi-daemon",
    ]
    assert (root / "etc" / "hosts").read_text() == HOSTS.replace(
        "127.0.1.1\tarlowe\n", "127.0.1.1\tkitchen-test\n")


def test_appends_loopback_line_when_absent(env):
    root, _, e = env
    base = "127.0.0.1\tlocalhost\n::1\t\tlocalhost\n"
    (root / "etc" / "hosts").write_text(base)
    request(root, {"display_name": "Kitchen Test"})
    assert run(e).returncode == 0
    assert (root / "etc" / "hosts").read_text() == base + "127.0.1.1\tkitchen-test\n"


def test_symlinked_request_refused(env, tmp_path):
    root, log, e = env
    target = tmp_path / "elsewhere.json"
    target.write_text(json.dumps({"display_name": "Kitchen Test"}))
    (root / "run" / "arlowe-pair" / "commit-request.json").symlink_to(target)
    assert run(e).returncode == 2
    assert_untouched(root, log)


def test_oversized_request_refused(env):
    root, log, e = env
    request(root, json.dumps({"display_name": "Kitchen Test", "pad": "x" * 5000}))
    assert run(e).returncode == 2
    assert_untouched(root, log)


def test_missing_request_refused(env):
    root, log, e = env
    assert run(e).returncode == 2
    assert_untouched(root, log)


@pytest.mark.parametrize("body", ["not json", "[]", json.dumps({"name": "Kitchen"}),
                                  json.dumps({"display_name": 7})])
def test_malformed_request_refused(env, body):
    root, log, e = env
    request(root, body)
    assert run(e).returncode == 2
    assert_untouched(root, log)


def test_banned_name_rejected(env):
    root, log, e = env
    entries = [line.strip().lower() for line in BANLIST.read_text().splitlines()
               if line.strip() and not line.lstrip().startswith("#")]
    shaped = sorted((x for x in entries if re.fullmatch(r"[a-z0-9-]+", x)), key=len)
    assert shaped, "expected a hostname-shaped banlist entry"
    request(root, {"display_name": f"My {shaped[0]}"})
    r = run(e)
    assert r.returncode == 3
    assert shaped[0] not in r.stdout + r.stderr
    assert_untouched(root, log)


def test_hostnamectl_failure_leaves_hosts(env):
    root, log, e = env
    request(root, {"display_name": "Kitchen Test"})
    assert run(e, SHIM_HOSTNAMECTL_RC="1").returncode == 4
    assert (root / "etc" / "hosts").read_text() == HOSTS
    assert not any(c.startswith("systemctl") for c in calls(log))


def test_unit_shape():
    text = UNIT.read_text()
    assert UNIT.name.startswith("arlowe-")
    assert re.search(r"^Type=oneshot$", text, re.M)
    assert "[Install]" not in text
    assert not re.search(r"^User=", text, re.M)
    assert re.search(r"^ExecStart=/usr/bin/python3 /opt/arlowe/runtime/cli/pair-commit$",
                     text, re.M)
    assert re.search(r"^ReadWritePaths=/etc/hosts$", text, re.M)
    assert re.search(r"^ProtectHostname=no$", text, re.M)
