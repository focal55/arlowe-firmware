"""Tests for POST /v1/certificates/revoke, the device-initiated revoke (08-06 contract).

Certificates are issued through StubIoT from in-process keys; no key- or
certificate-shaped fixture is tracked.
"""

import base64
import datetime
import json
import sys
from pathlib import Path

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "runtime" / "lib"))
import arlowe_identity  # noqa: E402
import arlowe_pki  # noqa: E402
import broker  # noqa: E402
import claim_codes  # noqa: E402
import stub_iot  # noqa: E402

DEVICE_ID = "a1b2c3d4e5f60718293a4b5c6d7e8f90"
OTHER_DEVICE_ID = "0f9e8d7c6b5a49382716f5e4d3c2b1a0"
NOW = datetime.datetime(2026, 9, 29, 12, 0, 0, tzinfo=datetime.timezone.utc)
UNAUTHORIZED = (401, {"error": "unauthorized"})


def csr_pem(key, device_id=DEVICE_ID):
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, device_id)])
    csr = x509.CertificateSigningRequestBuilder().subject_name(name).sign(key, hashes.SHA256())
    return csr.public_bytes(serialization.Encoding.PEM).decode()


def sign_with(key):
    def sign(fields):
        canonical = json.dumps(fields, sort_keys=True, separators=(",", ":")).encode()
        return base64.b64encode(key.sign(canonical, ec.ECDSA(hashes.SHA256()))).decode()
    return sign


def revoke_body(certificate_id, sign, device_id=DEVICE_ID, issued_at=NOW):
    fields = {"certificate_id": certificate_id, "device_id": device_id,
              "issued_at": issued_at.strftime("%Y-%m-%dT%H:%M:%SZ")}
    return json.dumps(dict(fields, signature=sign(fields))).encode()


@pytest.fixture
def unit(tmp_path):
    """A paired unit: a bound claim code and an ACTIVE stub certificate."""
    iot = stub_iot.StubIoT(tmp_path / "ca")
    store = claim_codes.ClaimStore(tmp_path / "claim-codes.json")
    code = store.mint("unit under test")
    config = dict(broker.STUB_PKI_DEFAULTS, ARLOWE_BROKER_CLAIM_CODES=str(store.path))
    key = ec.generate_private_key(ec.SECP256R1())

    def issue(device_key):
        body = json.dumps({"device_id": DEVICE_ID, "csr": csr_pem(device_key)}).encode()
        status, issued = broker.handle_certificate_request("Bearer " + code, body, iot, config)
        assert status == 200
        return issued["certificate_id"]

    return {"iot": iot, "store": store, "code": code, "key": key,
            "certificate_id": issue(key), "issue": issue}


def revoke(unit, body, now=NOW):
    return broker.handle_revoke_request(body, unit["iot"], unit["store"], now)


def cert_status(unit):
    desc = unit["iot"].describe_certificate(certificateId=unit["certificate_id"])
    return desc["certificateDescription"]["status"]


def code_state(unit):
    return unit["store"].load()[claim_codes.code_hash(unit["code"])]["state"]


def assert_nothing_revoked(unit):
    assert cert_status(unit) == "ACTIVE"
    assert code_state(unit) == "bound"


def test_signed_revoke_revokes_and_releases_the_code(unit):
    body = revoke_body(unit["certificate_id"], sign_with(unit["key"]))
    assert revoke(unit, body) == (200, {"revoked": True,
                                        "certificate_id": unit["certificate_id"]})
    assert cert_status(unit) == "REVOKED"
    assert code_state(unit) == "unused"


def test_repeat_revoke_is_200_and_stays_revoked(unit):
    body = revoke_body(unit["certificate_id"], sign_with(unit["key"]))
    assert revoke(unit, body)[0] == 200
    assert revoke(unit, body)[0] == 200
    assert cert_status(unit) == "REVOKED"
    assert code_state(unit) == "unused"


def test_signature_by_another_key_is_401(unit):
    other = ec.generate_private_key(ec.SECP256R1())
    assert revoke(unit, revoke_body(unit["certificate_id"], sign_with(other))) == UNAUTHORIZED
    assert_nothing_revoked(unit)


@pytest.mark.parametrize("offset", [-301, 301])
def test_stale_or_future_timestamp_is_401(unit, offset):
    issued_at = NOW + datetime.timedelta(seconds=offset)
    body = revoke_body(unit["certificate_id"], sign_with(unit["key"]), issued_at=issued_at)
    assert revoke(unit, body) == UNAUTHORIZED
    assert_nothing_revoked(unit)


def test_device_not_attached_to_the_certificate_is_401(unit):
    body = revoke_body(unit["certificate_id"], sign_with(unit["key"]), device_id=OTHER_DEVICE_ID)
    assert revoke(unit, body) == UNAUTHORIZED
    assert_nothing_revoked(unit)


def test_unknown_certificate_is_401(unit):
    assert revoke(unit, revoke_body("f" * 64, sign_with(unit["key"]))) == UNAUTHORIZED
    assert_nothing_revoked(unit)


@pytest.mark.parametrize("raw", [
    b"not json",
    b"[]",
    b'{"certificate_id": "ab", "device_id": "a1b2c3d4e5f60718293a4b5c6d7e8f90",'
    b' "issued_at": "2026-09-29T12:00:00Z"}',
    b'{"certificate_id": "ab", "device_id": "a1b2c3d4e5f60718293a4b5c6d7e8f90",'
    b' "issued_at": "yesterday", "signature": "x"}',
])
def test_missing_field_or_non_json_is_400(unit, raw):
    status, _ = revoke(unit, raw)
    assert status == 400
    assert_nothing_revoked(unit)


def test_device_signer_from_arlowe_pki_is_accepted(unit, tmp_path, monkeypatch):
    monkeypatch.setattr(arlowe_identity, "KEY_PATH", tmp_path / "identity" / "device.key")
    device_key = arlowe_pki.ensure_keypair()
    unit["certificate_id"] = unit["issue"](device_key)
    body = revoke_body(unit["certificate_id"], arlowe_pki.sign_payload)
    assert revoke(unit, body)[0] == 200
    assert cert_status(unit) == "REVOKED"
    assert code_state(unit) == "unused"
