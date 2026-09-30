"""`python3 -m pair`: the pairing daemon with its production collaborators."""
import functools
import logging
import os
import signal
import subprocess
import sys
import time

import arlowe_config
import arlowe_identity
from arlowe_broker import resolve_broker
from pair.app import build_app
from pair.commit import Committer
from pair.display import Display
from pair.flow import PairingFlow
from pair.netman import NetMan
from pair.portal import make_server

RUN_DIR = "/run/arlowe-pair"
BROKER_FILE = os.environ.get("ARLOWE_BROKER_FILE", "/boot/firmware/arlowe-broker.json")
BIND_ADDR = ("10.42.0.1", 80)


def ntp_synced():
    try:
        res = subprocess.run(["timedatectl", "show", "-p", "NTPSynchronized", "--value"],
                             capture_output=True, text=True, timeout=5, check=False)
    except (OSError, subprocess.SubprocessError):
        return False
    return res.stdout.strip() == "yes"


def broker_source():
    url = (arlowe_config.load().get("identity") or {}).get("provisioning_url") or ""
    return resolve_broker(BROKER_FILE, url.strip(), RUN_DIR)


def main():
    logging.basicConfig(level=logging.INFO, format="%(name)s: %(message)s")
    app = build_app(
        net=NetMan(), display=Display(), portal_factory=make_server,
        flow_factory=functools.partial(PairingFlow, ntp_synced=ntp_synced),
        committer=Committer(), clock=time.monotonic, broker_source=broker_source,
        device_id_reader=arlowe_identity.DEVICE_ID_PATH.read_text,
        bind_addr=BIND_ADDR, hold_s=float(os.environ.get("ARLOWE_PAIR_HOLD_S", "30")))
    signal.signal(signal.SIGTERM, lambda *_: app.stop())
    return app.run()


if __name__ == "__main__":
    sys.exit(main())
