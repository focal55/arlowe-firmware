"""Tests for the frozen POST /v1/certificates contract.

Every CSR is generated in-process. No key-, CSR- or certificate-shaped fixture is
committed: plan 07-04's build gate and 07-06's tracked-file check both treat one as
a violation, and scripts/pki/*.pem is gitignored for the same reason.

These are NOT part of the runtime/lib suite CI runs -- they need boto3, which the
image never installs. See scripts/pki/README.md for the local invocation.
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

TOKEN = "owner-token-under-test"
DEVICE_ID = "a1b2c3d4e5f60718293a4b5c6d7e8f90"
CONFIG = {
    "ARLOWE_BROKER_TOKEN": TOKEN,
    "ARLOWE_PKI_POLICY": "arlowe-staging-device-policy",
    "ARLOWE_PKI_ROLE_ALIAS": "arlowe-staging-role-alias",
    # Deliberately not a real endpoint: the account-specific host prefix must never
    # appear in a tracked file.
    "ARLOWE_PKI_CREDENTIALS_ENDPOINT": "broker-test.invalid",
}


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


def call(iot, auth="Bearer " + TOKEN, payload=None):
    body = request_body() if payload is None else payload
    return broker.handle_certificate_request(auth, body, iot, CONFIG)


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
    "auth", [None, "", "Bearer ", "Bearer wrong-token", TOKEN, "Basic " + TOKEN]
)
def test_bad_token_is_401(iot, auth):
    assert call(iot, auth=auth) == (401, {"error": "unauthorized"})
    iot.create_certificate_from_csr.assert_not_called()


@pytest.mark.parametrize(
    "raw,error",
    [
        (b"not json at all", "malformed_request"),
        (b'{"csr": "x"}', "malformed_request"),
        (b'{"device_id": "not-hex", "csr": "x"}', "invalid_device_id"),
        (b'{"device_id": null, "csr": "x"}', "invalid_device_id"),
    ],
)
def test_malformed_body_is_400(iot, raw, error):
    assert call(iot, payload=raw) == (400, {"error": error})
    iot.create_certificate_from_csr.assert_not_called()


def test_unparseable_csr_is_400(iot):
    payload = request_body(csr="-----BEGIN CERTIFICATE REQUEST-----\nnope\n")
    assert call(iot, payload=payload) == (400, {"error": "unparseable_csr"})
    iot.create_certificate_from_csr.assert_not_called()


def test_csr_cn_mismatch_is_400(iot):
    payload = request_body(csr=make_csr("f" * 32))
    assert call(iot, payload=payload) == (400, {"error": "csr_subject_mismatch"})
    iot.create_certificate_from_csr.assert_not_called()


def test_happy_path_returns_the_six_frozen_fields(iot):
    status, body = call(iot)
    assert status == 200
    assert set(body) == {
        "certificate_pem", "certificate_id", "certificate_arn",
        "thing_name", "credentials_endpoint", "role_alias",
    }
    assert body["thing_name"] == DEVICE_ID
    assert body["certificate_id"] == "deadbeef"
    assert body["credentials_endpoint"] == CONFIG["ARLOWE_PKI_CREDENTIALS_ENDPOINT"]
    assert body["role_alias"] == CONFIG["ARLOWE_PKI_ROLE_ALIAS"]
    assert iot.create_certificate_from_csr.call_args.kwargs["setAsActive"] is True
    # Authorization binds to the Thing name and certificate arn, not the CSR subject.
    iot.create_thing.assert_called_once_with(thingName=DEVICE_ID)
    iot.attach_thing_principal.assert_called_once_with(
        thingName=DEVICE_ID, principal=body["certificate_arn"]
    )
    iot.attach_policy.assert_called_once_with(
        policyName=CONFIG["ARLOWE_PKI_POLICY"], target=body["certificate_arn"]
    )


def test_already_registered_thing_still_returns_200(iot):
    iot.create_thing.side_effect = ClientError(
        {"Error": {"Code": "ResourceAlreadyExistsException"}}, "CreateThing"
    )
    assert call(iot)[0] == 200
    iot.attach_policy.assert_called_once()


@pytest.mark.parametrize(
    "method,code",
    [
        ("create_certificate_from_csr", "ThrottlingException"),
        ("create_thing", "InvalidRequestException"),
        ("attach_policy", "ResourceNotFoundException"),
    ],
)
def test_aws_failure_is_502_carrying_the_error_code(iot, method, code):
    getattr(iot, method).side_effect = ClientError({"Error": {"Code": code}}, method)
    assert call(iot) == (502, {"error": "issuance_failed", "detail": code})


def test_token_never_reaches_the_log(iot, caplog):
    caplog.set_level(logging.DEBUG, logger="arlowe.broker")
    call(iot)
    call(iot, auth="Bearer " + TOKEN + "-but-wrong")
    assert caplog.records
    assert TOKEN not in caplog.text


def test_load_config_names_the_missing_variable():
    partial = {k: v for k, v in CONFIG.items() if k != "ARLOWE_PKI_ROLE_ALIAS"}
    with pytest.raises(SystemExit, match="ARLOWE_PKI_ROLE_ALIAS"):
        broker.load_config(partial)
