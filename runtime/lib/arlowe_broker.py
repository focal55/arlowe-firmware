"""The one CSR-broker lookup pairing and factory reset share (ADR-0011, ADR-0013).

A unit paired against the self-signed local broker must reach that same broker at
reset time, so both flows resolve it here rather than each keeping its own copy.

Order: the FAT file (/boot/firmware/arlowe-broker.json, {"url", "ca_bundle_pem"}),
then identity.provisioning_url with system trust. Only the source is logged; the
file is operator-supplied and its contents stay out of the journal.
"""

import json
import logging
import os
from pathlib import Path

log = logging.getLogger("arlowe_broker")
CA_NAME = "broker-ca.pem"


def _from_file(broker_file, ca_dir):
    try:
        body = json.loads(Path(broker_file).read_text())
        url, pem = body["url"], body.get("ca_bundle_pem")
    except (OSError, ValueError, TypeError, KeyError):
        log.warning("broker file is unreadable or malformed; ignoring every broker source")
        return None
    if not isinstance(url, str) or not url.startswith("https://"):
        log.warning("broker file url is not https; refusing it")
        return None
    if not pem:
        return url, None
    ca_path = Path(ca_dir) / CA_NAME
    fd = os.open(ca_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as f:
        os.fchmod(fd, 0o600)
        f.write(pem)
    return url, ca_path


def resolve_broker(broker_file, config_url, ca_dir):
    """Return (url, ca_path or None), or None when no usable broker is configured.

    A present but invalid file returns None instead of falling back to the config:
    the file is the operator's explicit choice, and silently using another broker
    would bind the unit somewhere the operator did not intend.
    """
    if Path(broker_file).exists():
        log.info("broker source: file")
        return _from_file(broker_file, ca_dir)
    if config_url:
        log.info("broker source: config")
        return config_url, None
    log.info("broker source: none")
    return None
