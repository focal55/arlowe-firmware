"""NetworkManager actions pairing needs: radio, scan, setup AP, wifi profiles.

Every nmcli call is an argv list handed to an injectable runner; no shell is
involved. Secrets never go in argv (ADR-0011): the setup AP is added without
its PSK and brought up with `passwd-file /dev/stdin`, the PSK on stdin. The AP
is addressed by a uuid chosen here, never by name, because nmcli 1.42 reads a
positional name through `next_arg`, which swallows option-shaped words. Log
lines carry the action and its outcome only, never argv or a secret.
"""
import logging
import secrets
import subprocess
import uuid

log = logging.getLogger("arlowe.pair.netman")

IFNAME = "wlan0"
AP_CON_NAME = "arlowe-setup"
SSID_PREFIX = "Arlowe-Setup-"
PSK_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
PSK_LENGTH = 12
PSK_KEY = "802-11-wireless-security.psk"
NOT_FOUND = 10  # nmcli: connection, device or access point does not exist


class NetManError(RuntimeError):
    """An nmcli call failed; carries the action and exit code, never argv."""


def _default_runner(argv, input=None):
    return subprocess.run(argv, input=input, capture_output=True, check=False)


def session_credentials(device_id):
    psk = "".join(secrets.choice(PSK_ALPHABET) for _ in range(PSK_LENGTH))
    return SSID_PREFIX + device_id[:4], psk


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

    def _run(self, action, args, input=None, ok=(0,)):
        res = self._runner([self._nmcli, *args], input=input)
        log.info("nmcli %s: rc=%d", action, res.returncode)
        if res.returncode not in ok:
            err = res.stderr.decode(errors="replace").strip().splitlines()
            raise NetManError("%s failed (rc=%d): %s"
                              % (action, res.returncode, err[0] if err else ""))
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
                      input=(PSK_KEY + ":" + psk + "\n").encode())
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
