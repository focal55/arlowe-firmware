"""
Device identity derivation and the identity-store path contract.

Installed flat at /opt/arlowe/runtime/lib/arlowe_identity.py; import as:
    from arlowe_identity import ensure_device_id

Standard library only. Every Phase 7 consumer (CSR generation, the cloud client,
the identity CLI) takes its paths and its secret writer from here, so the store
is defined in exactly one place.

Store lifecycle: /var/lib/arlowe is a dedicated ext4 partition (p4, owner_state)
shared by both A/B slots, so the identity survives a slot flip and an app OTA and
is destroyed only by factory reset (PAIR-07).

Testing overrides: ARLOWE_IDENTITY_DIR relocates the store, ARLOWE_SERIAL_ROOT
prefixes the hardware serial sources. Both are read at import time, mirroring
arlowe_config's ARLOWE_*_PATH pattern, so tests monkeypatch the module attributes
as well as the environment.
"""

import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path

IDENTITY_DIR = Path(os.environ.get("ARLOWE_IDENTITY_DIR", "/var/lib/arlowe/identity"))
DEVICE_ID_PATH = IDENTITY_DIR / "device-id"
ENTROPY_PATH = IDENTITY_DIR / "device-entropy"
KEY_PATH = IDENTITY_DIR / "device.key"
CSR_PATH = IDENTITY_DIR / "device.csr"
CERT_PATH = IDENTITY_DIR / "device.crt"
METADATA_PATH = IDENTITY_DIR / "identity.json"

SECRET_MODE = 0o600
ENTROPY_BYTES = 32
DERIVATION_VERSION = 1
HOSTNAME_PLACEHOLDER = "${device_serial}"


class IdentitySourceUnavailable(RuntimeError):
    """No hardware serial source could be read."""


def _build_sources(root: Path):
    """Return the ordered (source_tag, path) serial sources under a root prefix."""
    return [
        ("rpi-duid", root / "proc/device-tree/chosen/rpi-duid"),
        ("dt-serial", root / "sys/firmware/devicetree/base/serial-number"),
        ("cpuinfo", root / "proc/cpuinfo"),
    ]


SERIAL_ROOT = Path(os.environ.get("ARLOWE_SERIAL_ROOT", "/"))
SERIAL_SOURCES = _build_sources(SERIAL_ROOT)


def write_secret(path: Path, data: bytes) -> None:
    """Write identity material once, at 0600, refusing to clobber.

    The single writer for every write-once file in the store: device-id,
    device-entropy, device.key, device.csr, device.crt. identity.json is the one
    documented exception and belongs to update_metadata.

    O_EXCL is the write-once guarantee, so an existing path raises FileExistsError
    by design; a caller that means to replace key material must unlink it first and
    say so. The explicit chmod after the open makes the mode independent of the
    process umask, which otherwise masks os.open's mode argument.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, SECRET_MODE)
    with os.fdopen(fd, "wb") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(path, SECRET_MODE)


def _cpuinfo_serial(text: str) -> str:
    for line in text.splitlines():
        key, _, value = line.partition(":")
        if key.strip() == "Serial":
            return value.strip()
    return ""


def read_serial() -> tuple:
    """Return (source_tag, serial) from the first readable hardware source.

    rpi-duid is preferred because it is factory-allocated rather than RNG-derived
    and matches the 2D data-matrix laser-etched on the PCB, which is what RMA and
    support quote. Device-tree properties are NUL-terminated, so raw bytes are
    stripped before use. Exhausting every source raises rather than defaulting:
    on real hardware that is a boundary condition worth failing loudly on.
    """
    for tag, path in SERIAL_SOURCES:
        try:
            raw = path.read_bytes()
        except OSError:
            continue
        value = raw.decode("utf-8", "replace").replace("\x00", "").strip()
        if tag == "cpuinfo":
            value = _cpuinfo_serial(value)
        if value:
            return tag, value
    checked = ", ".join(str(path) for _, path in SERIAL_SOURCES)
    raise IdentitySourceUnavailable(f"no hardware serial source available; checked {checked}")


def ensure_entropy() -> bytes:
    """Return the per-device entropy, generating it exactly once.

    This is not a TPM and not hardware-backed. It exists to close the documented
    Pi-4-era duplicate-serial hole, to guarantee two units that share a serial
    cannot derive the same id, and to keep the id unguessable from the serial
    alone so it is not an enumeration vector.
    """
    if ENTROPY_PATH.exists():
        return ENTROPY_PATH.read_bytes()
    entropy = os.urandom(ENTROPY_BYTES)
    write_secret(ENTROPY_PATH, entropy)
    return entropy


def derive_device_id(source_tag: str, serial: str, entropy: bytes) -> str:
    """Return the 32-hex-char opaque device id. Pure function, no I/O."""
    material = f"{source_tag}:{serial}:{entropy.hex()}".encode()
    return hashlib.sha256(material).hexdigest()[:32]


def read_metadata() -> dict:
    """Return identity.json as a dict, or {} if it does not exist.

    The only sanctioned reader. Unparseable JSON raises ValueError rather than
    returning {}: a corrupt identity.json on a provisioned device is a real fault,
    and swallowing it yields a device that merely looks unprovisioned.
    """
    if not METADATA_PATH.exists():
        return {}
    return json.loads(METADATA_PATH.read_text())


def update_metadata(**fields) -> dict:
    """Merge fields into identity.json atomically and return the merged dict.

    The only sanctioned mutator. identity.json is the one file in the store that
    is legitimately mutable -- it is bookkeeping (which serial source, which
    certificate id), not key material. Every other file here is write-once through
    write_secret, and this temp-and-replace is NOT a licence to weaken O_EXCL
    anywhere else: O_EXCL is the write-once guarantee on device.key,
    device-entropy and device-id, and trading it away to make a metadata update
    convenient would cost the load-bearing property of the whole module.

    Atomicity is not decorative. An unlink-then-rewrite leaves a window where
    identity.json does not exist, and a power cut inside it permanently loses
    serial_source and derived_at, because ensure_device_id short-circuits on the
    persisted device-id and never rewrites metadata. os.replace closes the window:
    a reader sees either the old file or the new one, never neither. The temp file
    is opened O_EXCL and chmod'd explicitly so it is never world-readable even for
    an instant under a permissive umask -- a naive open(tmp, "w") would inherit it.
    """
    merged = {**read_metadata(), **fields}
    data = json.dumps(merged, indent=2, sort_keys=True).encode()

    METADATA_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = METADATA_PATH.with_name(METADATA_PATH.name + ".tmp")
    tmp.unlink(missing_ok=True)
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, SECRET_MODE)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, SECRET_MODE)
        os.replace(tmp, METADATA_PATH)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise
    return merged


def ensure_device_id() -> str:
    """Return the persisted device id, deriving and persisting it on first call.

    Never re-derives: once device-id exists it is returned verbatim, so replacing
    or corrupting the entropy afterwards cannot change the device's identity.
    """
    if DEVICE_ID_PATH.exists():
        return DEVICE_ID_PATH.read_text().strip()

    source_tag, serial = read_serial()
    device_id = derive_device_id(source_tag, serial, ensure_entropy())
    write_secret(DEVICE_ID_PATH, device_id.encode())
    # The raw serial is deliberately absent: the device id is the opaque token,
    # and serial_source alone is what makes a field failure diagnosable.
    update_metadata(
        device_id=device_id,
        serial_source=source_tag,
        derivation_version=DERIVATION_VERSION,
        derived_at=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    )
    return device_id


def resolve_hostname(template: str, device_id: str) -> str:
    """Substitute ${device_serial} in a hostname template.

    The substituted value is "d" + device_id[:12], NOT the raw id, and that is not
    cosmetic. scripts/sanitize/check.sh matches tracked files and the mounted
    rootfs with `rg -iF` against scripts/sanitize/banlist.txt, whose entries
    include one of the form <this prefix>-<digit>. Fixed-string matching has no
    word boundaries, so a hostname whose first substituted character is that digit
    contains the banned literal and trips the gate -- and --scan-dir mode, which
    build-image.sh uses over the slot-A rootfs, ignores .sanitize-allowlist, so
    there is no exception to grant. The constant "d" forces a letter immediately
    after the prefix, and hex digits cannot spell any other banlist entry. Do not
    "simplify" this back to the raw id.
    """
    if HOSTNAME_PLACEHOLDER not in template:
        raise ValueError(f"hostname template has no {HOSTNAME_PLACEHOLDER}: {template!r}")
    return template.replace(HOSTNAME_PLACEHOLDER, "d" + device_id[:12])
