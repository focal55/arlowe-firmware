"""The pairing commit (ADR-0011): PairingFlow's `commit(form, provisioned)`.

Crash-safe order, each step only after the previous one succeeded:
  1. owner-credential.json and session.key in the dashboard state dir;
  2. the hostname, through /run/arlowe-pair/commit-request.json and the root
     oneshot arlowe-pair-commit.service (synchronous: `systemctl start` waits
     for a oneshot to finish);
  3. /etc/arlowe/config.yml, validated as a tmp file by the same validator the
     units run in ExecStartPre, then fsync, os.replace and a directory fsync.
The os.replace is the commit point. Anything that fails before it leaves the
unit unpaired, and arlowe-pair.service runs again on the next boot.

The commit starts nothing. start_runtime() does, and only the daemon calls it,
after the paired hold and after releasing the Whisplay: ADR-0011 hands the
display over by exit, not by Conflicts=, which would cancel the face's start
job on every paired boot.

The overlay never carries a password, PSK or claim code.
"""
import datetime
import json
import logging
import os
import subprocess
import sys

import yaml

import arlowe_hostname
from arlowe_hostname import validate_display_name
from pair import credential

log = logging.getLogger("arlowe.pair.commit")

COMMIT_UNIT = "arlowe-pair-commit.service"
REQUEST_FILE = "commit-request.json"
CONFIG_FILE = "config.yml"
CONFIG_MODE = 0o640
WIFI_LABEL_BYTES = 32
RUNTIME_UNITS = ("arlowe-face.service", "arlowe-voice.service", "arlowe-dashboard.service",
                 "qwen-tokenizer.service", "qwen-api.service", "whisper-stt.service")
LIB_DIR = os.path.dirname(os.path.abspath(arlowe_hostname.__file__))


class CommitError(RuntimeError):
    pass


def _utcnow():
    return datetime.datetime.now(datetime.timezone.utc)


def wifi_label(ssid):
    """At most 32 UTF-8 bytes, cut on a character boundary."""
    return ssid.encode("utf-8")[:WIFI_LABEL_BYTES].decode("utf-8", "ignore")


class Committer:
    def __init__(self, etc_dir="/etc/arlowe", run_dir="/run/arlowe-pair",
                 state_dir="/var/lib/arlowe/dashboard", systemctl="systemctl",
                 defaults_path=None, python=sys.executable, clock=_utcnow):
        self.etc_dir, self.run_dir = os.fspath(etc_dir), os.fspath(run_dir)
        self.state_dir, self.systemctl = os.fspath(state_dir), systemctl
        self.defaults_path = os.fspath(defaults_path or os.environ.get(
            "ARLOWE_DEFAULTS_PATH", "/opt/arlowe/config/defaults.yml"))
        self.python, self.clock = python, clock

    def __call__(self, form, provisioned):
        display_name, slug = validate_display_name(form["display_name"])
        credential.write_owner_credential(self.state_dir, form["password"], self.clock())
        credential.write_session_key(self.state_dir)
        log.info("owner credential and session key written")
        self._set_hostname(form["display_name"])
        self._write_config(self._overlay(display_name, slug, form["ssid"],
                                         provisioned["broker_url"]))
        log.info("config.yml committed; unit is paired as %s", slug)

    def start_runtime(self):
        """One non-blocking start of the six; the caller logs a non-zero exit."""
        rc = subprocess.run([self.systemctl, "start", "--no-block", *RUNTIME_UNITS],
                            stdin=subprocess.DEVNULL, check=False).returncode
        if rc:
            log.error("systemctl start of the runtime units exited %d", rc)
        return rc

    def _set_hostname(self, display_name):
        request = os.path.join(self.run_dir, REQUEST_FILE)
        credential.write_private(request, json.dumps({"display_name": display_name}).encode())
        try:
            rc = subprocess.run([self.systemctl, "start", COMMIT_UNIT],
                                stdin=subprocess.DEVNULL, check=False).returncode
        finally:
            os.unlink(request)
        if rc:
            raise CommitError(f"{COMMIT_UNIT} exited {rc}")

    def _overlay(self, display_name, slug, ssid, broker_url):
        with open(self.defaults_path, encoding="utf-8") as f:
            identity = yaml.safe_load(f)["identity"]
        return {
            "device": {"hostname": slug, "display_name": display_name},
            "owner": {"paired_at": self.clock().strftime("%Y-%m-%dT%H:%M:%SZ")},
            "network": {"wifi_label": wifi_label(ssid)},
            # All four required keys, so the block stands on its own in the overlay.
            "identity": {**identity, "provisioning_url": broker_url},
        }

    def _write_config(self, overlay):
        path = os.path.join(self.etc_dir, CONFIG_FILE)
        tmp = path + ".tmp"
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                     CONFIG_MODE)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                os.fchmod(f.fileno(), CONFIG_MODE)
                yaml.safe_dump(overlay, f, sort_keys=False, allow_unicode=True)
                f.flush()
                os.fsync(f.fileno())
            self._validate(tmp)
            os.replace(tmp, path)
        except BaseException:
            if os.path.exists(tmp):
                os.unlink(tmp)
            raise
        dfd = os.open(self.etc_dir, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)

    def _validate(self, path):
        pythonpath = os.pathsep.join(p for p in (LIB_DIR, os.environ.get("PYTHONPATH")) if p)
        env = {**os.environ, "ARLOWE_CONFIG_PATH": path, "PYTHONPATH": pythonpath,
               "ARLOWE_DEFAULTS_PATH": self.defaults_path}
        res = subprocess.run([self.python, "-m", "arlowe_config_validate"], env=env,
                             stdin=subprocess.DEVNULL, capture_output=True, text=True,
                             check=False)
        if res.returncode:
            for line in res.stderr.splitlines()[-5:]:
                log.error("config validation: %s", line)
            raise CommitError(f"config validation exited {res.returncode}")
