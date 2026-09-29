"""Tests for the frozen POST /v1/certificates contract.

Every CSR is generated in-process. No key-, CSR- or certificate-shaped fixture is
committed: plan 07-04's build gate and 07-06's tracked-file check both treat one as
a violation, and scripts/pki/*.pem is gitignored for the same reason.

These are NOT part of the runtime/lib suite -- they need botocore, which the image
never installs. Phase 8 CI's pki-broker job runs them; scripts/pki/README.md has the
local invocation.
"""

import json
import logging
import sys
from pathlib import Path
from unittest.mock import MagicMock

import pytest
from botocore.exceptions import ClientError
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import broker  # noqa: E402
import claim_codes  # noqa: E402

DEVICE_ID = "a1b2c3d4e5f60718293a4b5c6d7e8f90"
OTHER_DEVICE_ID = "0f9e8d7c6b5a49382716f5e4d3c2b1a0"
UNKNOWN_CODE = "ZZZZZ-ZZZZZ-ZZZZZ-ZZZZZ"
PKI = {
    "ARLOWE_PKI_POLICY": "arlowe-staging-device-policy",
    "ARLOWE_PKI_ROLE_ALIAS": "arlowe-staging-role-alias",
    # Deliberately not a real endpoint: the account-specific host prefix must never
    # appear in a tracked file.
    "ARLOWE_PKI_CREDENTIALS_ENDPOINT": "broker-test.invalid",
}
UNAUTHORIZED = (401, {"error": "unauthorized"})


def config(store):
    return dict(PKI, ARLOWE_BROKER_CLAIM_CODES=str(store.path))


def make_csr(common_name):
    key = ec.generate_private_key(ec.SECP256R1())
    csr = (
        x509.CertificateSigningRequestBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, common_name)]))
        .sign(key, hashes.SHA256())
    )
    return csr.public_bytes(serialization.Encoding.PEM).decode()


def request_body(device_id=DEVICE_ID, csr=None):
    csr = make_csr(device_id) if csr is None else csr
    return json.dumps({"device_id": device_id, "csr": csr}).encode()


@pytest.fixture
def claim_store(tmp_path):
    store = claim_codes.ClaimStore(tmp_path / "claim-codes.json")
    return store, store.mint("unit under test")


def state_of(store, code):
    return store.load()[claim_codes.code_hash(code)]


def call(iot, claim_store, auth=None, payload=None, device_id=DEVICE_ID):
    store, code = claim_store
    auth = "Bearer " + code if auth is None else auth
    body = request_body(device_id) if payload is None else payload
    return broker.handle_certificate_request(auth, body, iot, config(store))


@pytest.fixture
def iot():
    client = MagicMock()
    client.create_certificate_from_csr.return_value = {
        "certificateArn": "arn:aws:iot:us-east-1:ACCOUNT:cert/deadbeef",
        "certificateId": "deadbeef",
        "certificatePem": "-----BEGIN CERTIFICATE-----\nstub\n-----END CERTIFICATE-----\n",
    }
    return client


@pytest.mark.parametrize(
    "auth", ["", "Bearer ", "Bearer wrong-token", "Bearer " + UNKNOWN_CODE, "{code}",
             "Basic {code}"]
)
def test_bad_claim_code_is_401(iot, claim_store, auth):
    assert call(iot, claim_store, auth=auth.format(code=claim_store[1])) == UNAUTHORIZED
    iot.create_certificate_from_csr.assert_not_called()
    assert state_of(*claim_store)["state"] == "unused"


def test_missing_authorization_header_is_401(iot, claim_store):
    store, _ = claim_store
    result = broker.handle_certificate_request(None, request_body(), iot, config(store))
    assert result == UNAUTHORIZED


@pytest.mark.parametrize(
    "raw,error",
    [
        (b"not json at all", "malformed_request"),
        (b'{"csr": "x"}', "malformed_request"),
        (b'{"device_id": "not-hex", "csr": "x"}', "invalid_device_id"),
        (b'{"device_id": null, "csr": "x"}', "invalid_device_id"),
    ],
)
def test_malformed_body_is_400(iot, claim_store, raw, error):
    assert call(iot, claim_store, payload=raw) == (400, {"error": error})
    iot.create_certificate_from_csr.assert_not_called()


def test_unparseable_csr_is_400(iot, claim_store):
    payload = request_body(csr="-----BEGIN CERTIFICATE REQUEST-----\nnope\n")
    assert call(iot, claim_store, payload=payload) == (400, {"error": "unparseable_csr"})
    iot.create_certificate_from_csr.assert_not_called()


def test_csr_cn_mismatch_is_400(iot, claim_store):
    payload = request_body(csr=make_csr("f" * 32))
    assert call(iot, claim_store, payload=payload) == (400, {"error": "csr_subject_mismatch"})
    iot.create_certificate_from_csr.assert_not_called()


def test_happy_path_returns_the_six_frozen_fields(iot, claim_store):
    status, body = call(iot, claim_store)
    assert status == 200
    assert set(body) == {
        "certificate_pem", "certificate_id", "certificate_arn",
        "thing_name", "credentials_endpoint", "role_alias",
    }
    assert body["thing_name"] == DEVICE_ID
    assert body["certificate_id"] == "deadbeef"
    assert body["credentials_endpoint"] == PKI["ARLOWE_PKI_CREDENTIALS_ENDPOINT"]
    assert body["role_alias"] == PKI["ARLOWE_PKI_ROLE_ALIAS"]
    assert iot.create_certificate_from_csr.call_args.kwargs["setAsActive"] is True
    # Authorization binds to the Thing name and certificate arn, not the CSR subject.
    iot.create_thing.assert_called_once_with(thingName=DEVICE_ID)
    iot.attach_thing_principal.assert_called_once_with(
        thingName=DEVICE_ID, principal=body["certificate_arn"]
    )
    iot.attach_policy.assert_called_once_with(
        policyName=PKI["ARLOWE_PKI_POLICY"], target=body["certificate_arn"]
    )


def test_already_registered_thing_still_returns_200(iot, claim_store):
    iot.create_thing.side_effect = ClientError(
        {"Error": {"Code": "ResourceAlreadyExistsException"}}, "CreateThing"
    )
    assert call(iot, claim_store)[0] == 200
    iot.attach_policy.assert_called_once()


@pytest.mark.parametrize(
    "method,code",
    [
        ("create_certificate_from_csr", "ThrottlingException"),
        ("create_thing", "InvalidRequestException"),
        ("attach_policy", "ResourceNotFoundException"),
    ],
)
def test_aws_failure_is_502_carrying_the_error_code(iot, claim_store, method, code):
    getattr(iot, method).side_effect = ClientError({"Error": {"Code": code}}, method)
    assert call(iot, claim_store) == (502, {"error": "issuance_failed", "detail": code})
    assert state_of(*claim_store)["state"] == "unused"


def test_unused_code_binds_to_the_device_on_success(iot, claim_store):
    assert call(iot, claim_store)[0] == 200
    entry = state_of(*claim_store)
    assert (entry["state"], entry["device_id"]) == ("bound", DEVICE_ID)


def test_normalizes_the_presented_code(iot, claim_store):
    _, code = claim_store
    assert call(iot, claim_store, auth="Bearer " + code.lower().replace("-", ""))[0] == 200


def test_same_device_redeems_again(iot, claim_store):
    assert call(iot, claim_store)[0] == 200
    assert call(iot, claim_store)[0] == 200
    entry = state_of(*claim_store)
    assert (entry["state"], entry["device_id"]) == ("bound", DEVICE_ID)


def test_bound_elsewhere_unknown_and_revoked_are_the_same_401(iot, claim_store):
    store, code = claim_store
    assert call(iot, claim_store)[0] == 200
    iot.reset_mock()

    elsewhere = call(iot, claim_store, device_id=OTHER_DEVICE_ID)
    unknown = call(iot, claim_store, auth="Bearer " + UNKNOWN_CODE)
    store.revoke(code)
    revoked = call(iot, claim_store)

    assert elsewhere == unknown == revoked == UNAUTHORIZED
    iot.create_certificate_from_csr.assert_not_called()


def test_load_config_requires_the_claim_store(tmp_path):
    with pytest.raises(SystemExit, match="ARLOWE_BROKER_CLAIM_CODES"):
        broker.load_config(dict(PKI))
    missing = dict(PKI, ARLOWE_BROKER_CLAIM_CODES=str(tmp_path / "absent.json"))
    with pytest.raises(SystemExit, match="ARLOWE_BROKER_CLAIM_CODES"):
        broker.load_config(missing)


def test_load_config_names_the_missing_variable(claim_store):
    partial = {k: v for k, v in config(claim_store[0]).items() if k != "ARLOWE_PKI_ROLE_ALIAS"}
    with pytest.raises(SystemExit, match="ARLOWE_PKI_ROLE_ALIAS"):
        broker.load_config(partial)


def test_stub_mode_defaults_the_pki_values(claim_store):
    store, _ = claim_store
    loaded = broker.load_config({"ARLOWE_BROKER_CLAIM_CODES": str(store.path)}, stub=True)
    assert all(loaded[name] for name in PKI)


def stub_client(monkeypatch, ca_dir, *extra):
    # A None entry makes `import boto3` raise, proving stub mode never reaches for it.
    monkeypatch.setitem(sys.modules, "boto3", None)
    args = broker.parse_args(["--stub-iot", "--stub-ca-dir", str(ca_dir), *extra])
    return broker.make_iot_client(args)


def test_stub_mode_issues_a_certificate_signed_by_the_stub_ca(monkeypatch, tmp_path, claim_store):
    iot = stub_client(monkeypatch, tmp_path / "ca")
    assert type(iot).__name__ == "StubIoT"

    status, body = call(iot, claim_store)
    assert status == 200
    cert = x509.load_pem_x509_certificate(body["certificate_pem"].encode())
    ca_cert = x509.load_pem_x509_certificate((tmp_path / "ca" / "ca.pem").read_bytes())
    # verify_directly_issued_by needs cryptography 40; the device pins 38.0.4.
    ca_cert.public_key().verify(
        cert.signature, cert.tbs_certificate_bytes, ec.ECDSA(cert.signature_hash_algorithm)
    )
    assert cert.issuer == ca_cert.subject


def test_stub_fail_issuance_is_502_and_leaves_the_code_unused(monkeypatch, tmp_path, claim_store):
    iot = stub_client(monkeypatch, tmp_path / "ca", "--stub-fail", "issuance")
    assert call(iot, claim_store) == (502, {"error": "issuance_failed", "detail": "InternalFailure"})
    assert state_of(*claim_store)["state"] == "unused"


def test_claim_code_never_reaches_the_log(iot, claim_store, caplog):
    _, code = claim_store
    caplog.set_level(logging.DEBUG, logger="arlowe.broker")
    call(iot, claim_store)
    call(iot, claim_store, device_id=OTHER_DEVICE_ID)
    call(iot, claim_store, auth="Bearer " + code + "-but-wrong")
    assert caplog.records
    for form in (code, claim_codes.normalize(code), claim_codes.code_hash(code)):
        assert form not in caplog.text
