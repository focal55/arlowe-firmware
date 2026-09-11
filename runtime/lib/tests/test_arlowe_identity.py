"""
Unit tests for arlowe_identity.

Run from repo root:
    PYTHONPATH=runtime/lib python3 -m pytest runtime/lib/tests/test_arlowe_identity.py -q

Fully offline: serial sources come from the fixture trees under fixtures/identity/
via ARLOWE_SERIAL_ROOT, and the store is a tmp_path via ARLOWE_IDENTITY_DIR.
"""

import json
import os
import re
import stat
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

import arlowe_identity as ident

FIXTURES = Path(__file__).parent / "fixtures" / "identity"
# Resolved from the test file, never the cwd: CI runs pytest from the repo root
# but a developer may not, and a cwd-relative path would make the banlist
# property test pass or fail depending on where it was invoked.
BANLIST = Path(__file__).resolve().parents[3] / "scripts/sanitize/banlist.txt"

STORE_FILES = {
    "DEVICE_ID_PATH": "device-id",
    "ENTROPY_PATH": "device-entropy",
    "KEY_PATH": "device.key",
    "CSR_PATH": "device.csr",
    "CERT_PATH": "device.crt",
    "METADATA_PATH": "identity.json",
}

DUID = "DUID0123456789AB"
HOSTNAME_TEMPLATE = "arlowe-${device_serial}"


def _set_paths(monkeypatch, tmp_path) -> Path:
    """Point the module at a throwaway store; paths are import-time constants."""
    store = tmp_path / "identity"
    store.mkdir(parents=True, exist_ok=True)
    monkeypatch.setenv("ARLOWE_IDENTITY_DIR", str(store))
    monkeypatch.setattr(ident, "IDENTITY_DIR", store)
    for attr, name in STORE_FILES.items():
        monkeypatch.setattr(ident, attr, store / name)
    return store


def _set_serial_root(monkeypatch, root: Path) -> None:
    monkeypatch.setenv("ARLOWE_SERIAL_ROOT", str(root))
    monkeypatch.setattr(ident, "SERIAL_SOURCES", ident._build_sources(root))


@pytest.fixture
def store(monkeypatch, tmp_path):
    _set_serial_root(monkeypatch, FIXTURES / "all_three")
    return _set_paths(monkeypatch, tmp_path)


@pytest.fixture
def hostile_umask():
    previous = os.umask(0o000)
    yield
    os.umask(previous)


def test_read_serial_prefers_rpi_duid(store):
    assert ident.read_serial() == ("rpi-duid", DUID)


def test_read_serial_falls_back_to_device_tree(monkeypatch):
    _set_serial_root(monkeypatch, FIXTURES / "dt_serial_only")
    assert ident.read_serial() == ("dt-serial", "100000001234abcd")


def test_read_serial_falls_back_to_cpuinfo(monkeypatch):
    _set_serial_root(monkeypatch, FIXTURES / "cpuinfo_only")
    assert ident.read_serial() == ("cpuinfo", "00000000c0ffee11")


def test_read_serial_raises_when_no_source_available(monkeypatch, tmp_path):
    _set_serial_root(monkeypatch, tmp_path / "empty")
    with pytest.raises(ident.IdentitySourceUnavailable):
        ident.read_serial()


def test_device_tree_nul_termination_is_stripped(monkeypatch, tmp_path):
    duid = tmp_path / "root/proc/device-tree/chosen/rpi-duid"
    duid.parent.mkdir(parents=True)
    duid.write_bytes(b"ABC123\x00")
    _set_serial_root(monkeypatch, tmp_path / "root")
    assert ident.read_serial() == ("rpi-duid", "ABC123")


def test_derive_device_id_is_deterministic_32_hex():
    first = ident.derive_device_id("rpi-duid", "ABC123", b"\x01" * 32)
    assert first == ident.derive_device_id("rpi-duid", "ABC123", b"\x01" * 32)
    assert re.fullmatch(r"[0-9a-f]{32}", first)


def test_same_serial_different_entropy_diverges():
    """The duplicate-serial collision hole: entropy must be load-bearing."""
    assert ident.derive_device_id("rpi-duid", "ABC123", b"\x01" * 32) != ident.derive_device_id(
        "rpi-duid", "ABC123", b"\x02" * 32
    )


def test_same_serial_different_source_tag_diverges():
    assert ident.derive_device_id("rpi-duid", "ABC123", b"\x01" * 32) != ident.derive_device_id(
        "dt-serial", "ABC123", b"\x01" * 32
    )


def test_ensure_entropy_generates_exactly_once(store):
    first = ident.ensure_entropy()
    mtime = ident.ENTROPY_PATH.stat().st_mtime_ns
    assert len(first) == 32
    assert ident.ensure_entropy() == first
    assert ident.ENTROPY_PATH.stat().st_mtime_ns == mtime


def test_ensure_device_id_is_idempotent_and_never_rederives(store):
    device_id = ident.ensure_device_id()
    assert ident.ensure_device_id() == device_id
    ident.ENTROPY_PATH.write_bytes(b"\xff" * 32)
    assert ident.ensure_device_id() == device_id
    assert ident.DEVICE_ID_PATH.read_text().strip() == device_id


def test_ensure_device_id_records_metadata_without_the_raw_serial(store):
    device_id = ident.ensure_device_id()
    meta = ident.read_metadata()
    assert meta["device_id"] == device_id
    assert meta["serial_source"] == "rpi-duid"
    assert meta["derivation_version"] == 1
    assert meta["derived_at"].endswith("Z")
    assert DUID not in json.dumps(meta)


def test_store_files_are_0600_under_hostile_umask(store, hostile_umask):
    ident.ensure_device_id()
    for path in (ident.DEVICE_ID_PATH, ident.ENTROPY_PATH, ident.METADATA_PATH):
        assert stat.S_IMODE(path.stat().st_mode) == 0o600


def test_write_secret_refuses_to_overwrite(store):
    ident.write_secret(ident.KEY_PATH, b"first")
    with pytest.raises(FileExistsError):
        ident.write_secret(ident.KEY_PATH, b"second")
    assert ident.KEY_PATH.read_bytes() == b"first"


def test_resolve_hostname_substitutes_the_prefixed_id(store):
    device_id = ident.ensure_device_id()
    assert ident.resolve_hostname(HOSTNAME_TEMPLATE, device_id) == "arlowe-d" + device_id[:12]


def test_resolve_hostname_rejects_a_template_without_a_placeholder():
    with pytest.raises(ValueError):
        ident.resolve_hostname("arlowe-fixed", "0" * 32)


def test_resolved_hostname_never_contains_a_banned_literal():
    """The only live check on the sanitize-gate trap.

    The banlist is read from the repo, not copied here, so the property tracks the
    real gate. A vacuous run (missing or empty banlist) fails loudly.
    """
    assert BANLIST.is_file(), f"banlist missing at {BANLIST}; property would be vacuous"
    banned = [line.strip().lower() for line in BANLIST.read_text().splitlines() if line.strip()]
    assert banned, f"{BANLIST} is empty; property would be vacuous"
    for _ in range(5000):
        device_id = ident.derive_device_id("rpi-duid", "SERIAL", os.urandom(32))
        hostname = ident.resolve_hostname(HOSTNAME_TEMPLATE, device_id).lower()
        for literal in banned:
            assert literal not in hostname, f"{hostname} contains {literal}"


def test_read_metadata_returns_empty_when_absent(store):
    assert ident.read_metadata() == {}


def test_read_metadata_raises_on_corrupt_json(store):
    ident.METADATA_PATH.write_text("{not json")
    with pytest.raises(ValueError):
        ident.read_metadata()


def test_update_metadata_merges_into_a_file_ensure_device_id_created(store):
    """Regression for the O_EXCL collision: 07-08a's provision step would raise
    FileExistsError if update_metadata went through write_secret."""
    device_id = ident.ensure_device_id()
    merged = ident.update_metadata(certificate_id="abc")
    assert merged["certificate_id"] == "abc"
    on_disk = ident.read_metadata()
    assert on_disk["device_id"] == device_id
    assert on_disk["serial_source"] == "rpi-duid"
    assert on_disk["certificate_id"] == "abc"


def test_update_metadata_creates_the_file_when_absent(store):
    ident.update_metadata(certificate_id="abc")
    assert ident.read_metadata() == {"certificate_id": "abc"}


def test_update_metadata_is_0600_under_hostile_umask(store, hostile_umask):
    ident.update_metadata(certificate_id="abc")
    assert stat.S_IMODE(ident.METADATA_PATH.stat().st_mode) == 0o600


def test_update_metadata_leaves_no_temp_file_on_success(store):
    ident.update_metadata(certificate_id="abc")
    assert list(store.glob("*.tmp")) == []


def test_update_metadata_temp_file_is_0600_before_replace(store, hostile_umask):
    real_replace = os.replace
    seen = {}

    def checking_replace(src, dst):
        seen["mode"] = stat.S_IMODE(os.stat(src).st_mode)
        return real_replace(src, dst)

    with pytest.MonkeyPatch.context() as mp:
        mp.setattr(os, "replace", checking_replace)
        ident.update_metadata(certificate_id="abc")
    assert seen["mode"] == 0o600


def test_update_metadata_failure_preserves_the_original_and_cleans_up(store):
    """Atomicity: an implementation that unlinked the target first would fail this."""
    ident.ensure_device_id()
    before = ident.METADATA_PATH.read_bytes()

    def boom(src, dst):
        raise OSError("replace failed")

    with pytest.MonkeyPatch.context() as mp:
        mp.setattr(os, "replace", boom)
        with pytest.raises(OSError):
            ident.update_metadata(certificate_id="abc")
    assert ident.METADATA_PATH.read_bytes() == before
    assert list(store.glob("*.tmp")) == []


def test_update_metadata_does_not_weaken_the_write_once_guarantee(store):
    ident.ensure_device_id()
    ident.update_metadata(certificate_id="abc")
    with pytest.raises(FileExistsError):
        ident.write_secret(ident.DEVICE_ID_PATH, b"replacement")
