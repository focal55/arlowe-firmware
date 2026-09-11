"""
Unit tests for arlowe_pki.

Run from repo root:
    PYTHONPATH=runtime/lib python3 -m pytest runtime/lib/tests/test_arlowe_pki.py -q

Fully offline. Every key and certificate is generated at test runtime into a
tmp_path store: committing a .key/.crt/.csr/.pem fixture anywhere under runtime/
would land it in the image, because pi-gen/stage-arlowe/01-runtime rsyncs all of
runtime/ with no excludes and 07-04's build gate scans that path.
"""

import os
import stat
import sys
from datetime import datetime, timedelta
from pathlib import Path

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

sys.path.insert(0, str(Path(__file__).parent.parent))

import arlowe_identity as ident
import arlowe_pki as pki

FIXTURES = Path(__file__).parent / "fixtures" / "identity"
STORE_FILES = {
    "DEVICE_ID_PATH": "device-id",
    "ENTROPY_PATH": "device-entropy",
    "KEY_PATH": "device.key",
    "CSR_PATH": "device.csr",
    "CERT_PATH": "device.crt",
    "METADATA_PATH": "identity.json",
}


@pytest.fixture
def store(monkeypatch, tmp_path):
    """Point the store and the serial sources at throwaway trees."""
    root = FIXTURES / "all_three"
    monkeypatch.setenv("ARLOWE_SERIAL_ROOT", str(root))
    monkeypatch.setattr(ident, "SERIAL_SOURCES", ident._build_sources(root))
    store_dir = tmp_path / "identity"
    store_dir.mkdir(parents=True)
    monkeypatch.setenv("ARLOWE_IDENTITY_DIR", str(store_dir))
    monkeypatch.setattr(ident, "IDENTITY_DIR", store_dir)
    for attr, name in STORE_FILES.items():
        monkeypatch.setattr(ident, attr, store_dir / name)
    return store_dir


@pytest.fixture
def hostile_umask():
    previous = os.umask(0o000)
    yield
    os.umask(previous)


def _self_signed(key, cn="issued") -> str:
    """A throwaway certificate over key's public key, standing in for the broker's."""
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])
    now = datetime.utcnow()
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(days=1))
        .not_valid_after(now + timedelta(days=1))
        .sign(key, hashes.SHA256())
    )
    return cert.public_bytes(serialization.Encoding.PEM).decode()


def test_ensure_keypair_generates_p256(store):
    key = pki.ensure_keypair()
    assert isinstance(key.curve, ec.SECP256R1)
    assert ident.KEY_PATH.is_file()


def test_ensure_keypair_is_write_once(store):
    first = pki.ensure_keypair()
    mtime = ident.KEY_PATH.stat().st_mtime_ns
    assert pki.ensure_keypair().private_numbers() == first.private_numbers()
    assert ident.KEY_PATH.stat().st_mtime_ns == mtime


def test_stored_material_is_0600_under_hostile_umask(store, hostile_umask):
    """Trap 4: systemd's default UMask 0022 would otherwise yield 0644."""
    key = pki.ensure_keypair()
    pki.ensure_csr(ident.ensure_device_id())
    pki.store_certificate(_self_signed(key))
    for path in (ident.KEY_PATH, ident.CSR_PATH, ident.CERT_PATH):
        assert stat.S_IMODE(path.stat().st_mode) == 0o600


def test_csr_subject_cn_is_the_device_id(store):
    device_id = ident.ensure_device_id()
    csr = x509.load_pem_x509_csr(pki.ensure_csr(device_id).encode())
    assert csr.subject.get_attributes_for_oid(NameOID.COMMON_NAME)[0].value == device_id
    assert isinstance(csr.signature_hash_algorithm, hashes.SHA256)
    assert csr.is_signature_valid


def test_ensure_csr_is_idempotent(store):
    device_id = ident.ensure_device_id()
    first = pki.ensure_csr(device_id)
    assert pki.ensure_csr(device_id) == first
    assert pki.load_csr_pem() == first


def test_ensure_csr_rejects_a_csr_for_another_device(store):
    pki.ensure_csr("a" * 32)
    with pytest.raises(pki.IdentityMismatch):
        pki.ensure_csr("b" * 32)


def test_store_certificate_rejects_garbage(store):
    pki.ensure_keypair()
    with pytest.raises(ValueError):
        pki.store_certificate("-----BEGIN CERTIFICATE----- not a certificate")
    assert not ident.CERT_PATH.exists()


def test_store_certificate_rejects_a_certificate_for_another_key(store):
    pki.ensure_keypair()
    foreign = _self_signed(ec.generate_private_key(ec.SECP256R1()))
    with pytest.raises(pki.IdentityMismatch):
        pki.store_certificate(foreign)
    assert not ident.CERT_PATH.exists()


def test_store_and_load_round_trip(store):
    key = pki.ensure_keypair()
    pki.store_certificate(_self_signed(key, cn="round-trip"))
    cert = pki.load_certificate()
    assert pki.certificate_matches_key(cert, key)
    summary = pki.certificate_summary()
    assert summary["subject_cn"] == "round-trip"
    assert summary["issuer_cn"] == "round-trip"
    assert summary["serial_number"] == cert.serial_number
    assert summary["fingerprint_sha256"] == cert.fingerprint(hashes.SHA256()).hex()
    assert summary["not_valid_after"] > summary["not_valid_before"]


def test_reprovision_replaces_the_stored_certificate(store, hostile_umask):
    """Re-issue after revocation is legitimate; write_secret's O_EXCL must not block it."""
    key = pki.ensure_keypair()
    pki.store_certificate(_self_signed(key, cn="first"))
    pki.store_certificate(_self_signed(key, cn="second"))
    assert pki.certificate_summary()["subject_cn"] == "second"
    assert stat.S_IMODE(ident.CERT_PATH.stat().st_mode) == 0o600


def test_private_key_never_leaves_device_key(store):
    key = pki.ensure_keypair()
    pki.ensure_csr(ident.ensure_device_id())
    pki.store_certificate(_self_signed(key))
    secret = ident.KEY_PATH.read_bytes()
    assert b"PRIVATE KEY" in secret
    body = [line for line in secret.splitlines()[1:-1] if line]
    assert body, "key PEM has no base64 body; the leak check would be vacuous"

    rendered = repr(pki.certificate_summary())
    for line in body:
        assert line.decode() not in rendered
    for path in store.rglob("*"):
        if path.is_file() and path != ident.KEY_PATH:
            blob = path.read_bytes()
            for line in body:
                assert line not in blob, f"private key material leaked into {path}"
