"""Tests for the in-memory IoT stand-in the local broker runs on.

Every key, CSR and certificate is generated in-process or into tmp_path; no PEM is
tracked (07-04's build gate). Needs cryptography and botocore, like test_broker.py.
"""

import ipaddress
import ssl
import stat
import subprocess
import sys
from pathlib import Path

import pytest
from botocore.exceptions import ClientError
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

PKI_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PKI_DIR))
import stub_iot  # noqa: E402

DEVICE_ID = "a1b2c3d4e5f60718293a4b5c6d7e8f90"


def make_csr(common_name=DEVICE_ID):
    key = ec.generate_private_key(ec.SECP256R1())
    csr = (
        x509.CertificateSigningRequestBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, common_name)]))
        .sign(key, hashes.SHA256())
    )
    return csr.public_bytes(serialization.Encoding.PEM).decode(), key


def public_der(public_key):
    return public_key.public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
    )


def signed_by(cert, ca_cert):
    # verify_directly_issued_by needs cryptography 40; the device pins 38.0.4.
    ca_cert.public_key().verify(
        cert.signature, cert.tbs_certificate_bytes, ec.ECDSA(cert.signature_hash_algorithm)
    )
    return cert.issuer == ca_cert.subject


def issue(iot):
    csr_pem, key = make_csr()
    issued = iot.create_certificate_from_csr(certificateSigningRequest=csr_pem, setAsActive=True)
    return issued, key


def test_issued_certificate_verifies_against_stub_ca_and_carries_csr_key(tmp_path):
    iot = stub_iot.StubIoT(tmp_path / "ca")
    issued, key = issue(iot)

    assert {"certificateArn", "certificateId", "certificatePem"} <= issued.keys()
    assert issued["certificateArn"].endswith("cert/" + issued["certificateId"])
    cert = x509.load_pem_x509_certificate(issued["certificatePem"].encode())
    ca_cert = x509.load_pem_x509_certificate((tmp_path / "ca" / "ca.pem").read_bytes())
    assert signed_by(cert, ca_cert)
    assert public_der(cert.public_key()) == public_der(key.public_key())
    assert issued["certificateId"] == cert.fingerprint(hashes.SHA256()).hex()


def test_describe_reports_active_then_revoked(tmp_path):
    iot = stub_iot.StubIoT(tmp_path / "ca")
    issued, _ = issue(iot)
    cert_id = issued["certificateId"]

    desc = iot.describe_certificate(certificateId=cert_id)["certificateDescription"]
    assert desc["status"] == "ACTIVE"
    assert desc["certificatePem"] == issued["certificatePem"]

    iot.update_certificate(certificateId=cert_id, newStatus="REVOKED")
    desc = iot.describe_certificate(certificateId=cert_id)["certificateDescription"]
    assert desc["status"] == "REVOKED"


def test_list_principal_things_returns_attached_thing(tmp_path):
    iot = stub_iot.StubIoT(tmp_path / "ca")
    issued, _ = issue(iot)
    arn = issued["certificateArn"]

    iot.create_thing(thingName=DEVICE_ID)
    iot.attach_thing_principal(thingName=DEVICE_ID, principal=arn)
    iot.attach_policy(policyName="arlowe-staging-device-policy", target=arn)

    assert iot.list_principal_things(principal=arn)["things"] == [DEVICE_ID]


def test_fail_issuance_raises_internal_failure(tmp_path):
    iot = stub_iot.StubIoT(tmp_path / "ca", fail_issuance=True)
    with pytest.raises(ClientError) as excinfo:
        issue(iot)
    assert excinfo.value.response["Error"]["Code"] == "InternalFailure"


def test_restarted_stub_signs_with_same_ca(tmp_path):
    first, _ = issue(stub_iot.StubIoT(tmp_path / "ca"))
    second, _ = issue(stub_iot.StubIoT(tmp_path / "ca"))

    ca_cert = x509.load_pem_x509_certificate((tmp_path / "ca" / "ca.pem").read_bytes())
    for issued in (first, second):
        cert = x509.load_pem_x509_certificate(issued["certificatePem"].encode())
        assert signed_by(cert, ca_cert)


def test_tls_subcommand_writes_pair_for_san(tmp_path):
    out = tmp_path / "tls"
    subprocess.run(
        [sys.executable, str(PKI_DIR / "stub_iot.py"), "tls", "--san", "192.0.2.10",
         "--out", str(out)],
        check=True,
    )

    cert = x509.load_pem_x509_certificate((out / "broker-cert.pem").read_bytes())
    ca_cert = x509.load_pem_x509_certificate((out / "ca.pem").read_bytes())
    san = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
    assert ipaddress.ip_address("192.0.2.10") in san.get_values_for_type(x509.IPAddress)
    assert signed_by(cert, ca_cert)
    assert stat.S_IMODE((out / "broker-key.pem").stat().st_mode) == 0o600

    server = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server.load_cert_chain(out / "broker-cert.pem", out / "broker-key.pem")
    ssl.create_default_context(cafile=str(out / "ca.pem"))
