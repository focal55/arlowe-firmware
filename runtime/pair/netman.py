"""NetworkManager actions pairing needs: radio, scan, setup AP, wifi profiles.

Every nmcli call is an argv list handed to an injectable runner; no shell is
involved. Secrets never go in argv (ADR-0011): the setup AP is added without
its PSK and brought up with `passwd-file /dev/stdin`, the PSK on stdin. The AP
is addressed by a uuid chosen here, never by name, because nmcli 1.42 reads a
positional name through `next_arg`, which swallows option-shaped words. Log
lines carry the action and its outcome only, never argv or a secret.
"""
import logging
import re
import secrets
import subprocess
import uuid

from pair.errors import JoinError

log = logging.getLogger("arlowe.pair.netman")

IFNAME = "wlan0"
AP_CON_NAME = "arlowe-setup"
SSID_PREFIX = "Arlowe-Setup-"
PSK_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
PSK_LENGTH = 12
PSK_KEY = "802-11-wireless-security.psk"
NOT_FOUND = 10  # nmcli: connection, device or access point does not exist
# NMDeviceStateReason codes as nmcli prints them, "(N)". The brcmfmac mapping of
# a wrong PSK to 7/8/11 is MEDIUM confidence until 08-27b sees it on hardware.
REJECTED_REASONS = {7, 8, 11}
NOT_FOUND_REASONS = {53}
_PASSWD_ESCAPES = {"\\": "\\\\", " ": "\\ ", "\t": "\\t", "\v": "\\v", "\f": "\\f"}


class NetManError(RuntimeError):
    """An nmcli call failed; carries the action and exit code, never argv."""

    def __init__(self, msg, stderr=""):
        super().__init__(msg)
        self.stderr = stderr


def _default_runner(argv, input=None):
    return subprocess.run(argv, input=input, capture_output=True, check=False)


def session_credentials(device_id):
    psk = "".join(secrets.choice(PSK_ALPHABET) for _ in range(PSK_LENGTH))
    return SSID_PREFIX + device_id[:4], psk


def passwd_line(key, value):
    """One `passwd-file` line NetworkManager 1.42.4 reads back as exactly
    `value`: its parser strips unescaped edge whitespace and unescapes `\\`."""
    if any(c in value for c in "\r\n\0"):
        raise ValueError("secret contains a line break or NUL")
    escaped = "".join(_PASSWD_ESCAPES.get(c, c) for c in value)
    return (key + ":" + escaped + "\n").encode()


def _classify(stderr):
    m = re.search(r"\((\d+)\)", stderr)
    code = int(m.group(1)) if m else None
    if code in REJECTED_REASONS:
        return "wifi_rejected"
    if code in NOT_FOUND_REASONS or "No network with SSID" in stderr:
        return "wifi_not_found"
    return "wifi_failed"


def _split_terse(line):
    """Split one `nmcli -t` line on unescaped colons, undoing `\\:` and `\\\\`."""
    fields, cur, chars = [], [], iter(line)
    for c in chars:
        if c == "\\":
            cur.append(next(chars, ""))
        elif c == ":":
            fields.append("".join(cur))
            cur = []
        else:
            cur.append(c)
    fields.append("".join(cur))
    return fields


class NetMan:
    def __init__(self, runner=_default_runner, nmcli="nmcli"):
        self._runner = runner
        self._nmcli = nmcli
        self._ap_uuid = None
        self._join_uuids = {}

    def _run(self, action, args, input=None, ok=(0,)):
        res = self._runner([self._nmcli, *args], input=input)
        log.info("nmcli %s: rc=%d", action, res.returncode)
        if res.returncode not in ok:
            stderr = res.stderr.decode(errors="replace").strip()
            err = stderr.splitlines()
            raise NetManError("%s failed (rc=%d): %s"
                              % (action, res.returncode, err[0] if err else ""),
                              stderr)
        return res.stdout.decode(errors="replace")

    def radio_on(self):
        self._run("radio on", ["radio", "wifi", "on"])

    def scan(self):
        """Scan once, before the AP is up: brcmfmac cannot rescan in AP mode."""
        out = self._run("scan", ["-t", "-f", "SSID,SIGNAL,SECURITY", "device",
                                 "wifi", "list", "--rescan", "yes"])
        best = {}
        for line in out.splitlines():
            fields = _split_terse(line)
            if len(fields) != 3 or not fields[0]:
                continue
            ssid, signal, security = fields
            row = {"ssid": ssid, "signal": int(signal or 0),
                   "secure": security.strip() not in ("", "--")}
            if ssid not in best or row["signal"] > best[ssid]["signal"]:
                best[ssid] = row
        return sorted(best.values(), key=lambda r: (-r["signal"], r["ssid"]))

    def ap_up(self, ssid, psk):
        """Raise the in-memory WPA2 setup AP; the PSK goes to nmcli on stdin."""
        self._ap_uuid = str(uuid.uuid4())
        self._run("ap add", [
            "connection", "add", "save", "no", "type", "wifi", "ifname", IFNAME,
            "con-name", AP_CON_NAME, "connection.uuid", self._ap_uuid,
            "autoconnect", "no", "ssid", ssid,
            "802-11-wireless.mode", "ap", "802-11-wireless.band", "bg",
            "802-11-wireless.channel", "6",
            "wifi-sec.key-mgmt", "wpa-psk", "wifi-sec.proto", "rsn",
            "wifi-sec.pairwise", "ccmp", "wifi-sec.group", "ccmp",
            "ipv4.method", "shared", "ipv4.addresses", "10.42.0.1/24",
            "ipv6.method", "disabled",
        ])
        try:
            self._run("ap up", ["connection", "up", "uuid", self._ap_uuid,
                                "passwd-file", "/dev/stdin"],
                      input=passwd_line(PSK_KEY, psk))
        except NetManError:
            self.delete_profile(self._ap_uuid)
            self._ap_uuid = None
            raise

    def ap_down(self):
        if self._ap_uuid is None:
            return
        self._run("ap down", ["connection", "down", "uuid", self._ap_uuid],
                  ok=(0, NOT_FOUND))
        self.delete_profile(self._ap_uuid)
        self._ap_uuid = None

    def wifi_profiles(self):
        out = self._run("list profiles",
                        ["-t", "-f", "UUID,TYPE", "connection", "show"])
        return [f[0] for f in map(_split_terse, out.splitlines())
                if len(f) == 2 and f[1] == "802-11-wireless"]

    def delete_profile(self, uuid_):
        self._run("delete profile", ["connection", "delete", "uuid", uuid_],
                  ok=(0, NOT_FOUND))

    def join(self, ssid, psk):
        """Join the home network; the PSK reaches nmcli only on stdin.

        psk-flags 0 makes the secret system-owned, so NetworkManager keeps the
        PSK it received for later boots. A failure deletes the profile so
        NetworkManager cannot retry a wrong PSK forever.
        """
        line = passwd_line(PSK_KEY, psk) if psk else None
        u = str(uuid.uuid4())
        add = ["connection", "add", "type", "wifi", "ifname", IFNAME,
               "con-name", ssid, "connection.uuid", u, "ssid", ssid,
               "autoconnect", "yes"]
        up = ["--wait", "45", "connection", "up", "uuid", u]
        if psk:
            add += ["wifi-sec.key-mgmt", "wpa-psk", "wifi-sec.psk-flags", "0"]
            up += ["passwd-file", "/dev/stdin"]
        try:
            self._run("join add", add)
            self._run("join up", up, input=line)
        except NetManError as exc:
            self.delete_profile(u)
            raise JoinError(_classify(exc.stderr)) from exc
        self._join_uuids[ssid] = u

    def saved_ssid_profile(self, ssid):
        """Delete the profile a successful join left for `ssid`, by its uuid."""
        u = self._join_uuids.pop(ssid, None)
        if u is not None:
            self.delete_profile(u)
