#!/usr/bin/env python3
"""In-memory stand-in for the boto3 IoT client, plus a TLS pair generator. Dev host only.

StubIoT implements the subset of the IoT client surface broker.py calls, with the
same method names, keyword arguments and response keys, so the local broker runs
without an AWS account. It signs real CSRs with a throwaway CA kept in `ca_dir`;
certificate, thing and policy state is in memory and lost on restart.

`stub_iot.py tls --san <ip-or-name> --out DIR` writes a broker TLS pair and the
ca.pem a device trusts through ARLOWE_BROKER_CA_BUNDLE.

The AWS path never imports this module. Nothing under scripts/pki/ ships in the image.
"""

import argparse
import datetime
import ipaddress
import os
import threading
from pathlib import Path

from botocore.exceptions import ClientError
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

ARN_PREFIX = "arn:aws:iot:us-east-1:000000000000:"


def _client_error(code, operation):
    return ClientError({"Error": {"Code": code, "Message": "stub_iot"}}, operation)


def _write(path, data, mode=0o644):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    os.fchmod(fd, mode)
    with os.fdopen(fd, "wb") as fh:
        fh.write(data)


def _pem(cert):
    return cert.public_bytes(serialization.Encoding.PEM)


def _new_ca(common_name):
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, common_name)])
    cert = (
        _builder(name, name, key.public_key(), days=3650)
        .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
        .sign(key, hashes.SHA256())
    )
    return key, cert


def _builder(subject, issuer, public_key, days):
    now = datetime.datetime.now(datetime.timezone.utc)
    return (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(public_key)
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(minutes=5))
        .not_valid_after(now + datetime.timedelta(days=days))
    )


def _leaf(ca_cert, subject, public_key, days, usage):
    return (
        _builder(subject, ca_cert.subject, public_key, days)
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .add_extension(x509.ExtendedKeyUsage([usage]), critical=False)
    )


class StubIoT:
    def __init__(self, ca_dir, fail_issuance=False):
        self.fail_issuance = fail_issuance
        self._lock = threading.Lock()
        self._certs = {}
        self._things = set()
        self._ca_key, self._ca_cert = self._load_or_create_ca(Path(ca_dir))

    @staticmethod
    def _load_or_create_ca(ca_dir):
        key_path, cert_path = ca_dir / "ca-key.pem", ca_dir / "ca.pem"
        if key_path.exists() and cert_path.exists():
            key = serialization.load_pem_private_key(key_path.read_bytes(), password=None)
            return key, x509.load_pem_x509_certificate(cert_path.read_bytes())
        ca_dir.mkdir(parents=True, exist_ok=True)
        key, cert = _new_ca("arlowe stub IoT CA")
        _write(key_path, key.private_bytes(serialization.Encoding.PEM,
                                           serialization.PrivateFormat.PKCS8,
                                           serialization.NoEncryption()), 0o600)
        _write(cert_path, _pem(cert))
        return key, cert

    def _cert(self, certificate_id, operation):
        try:
            return self._certs[certificate_id]
        except KeyError:
            raise _client_error("ResourceNotFoundException", operation) from None

    def create_certificate_from_csr(self, certificateSigningRequest, setAsActive=False):
        if self.fail_issuance:
            raise _client_error("InternalFailure", "CreateCertificateFromCsr")
        try:
            csr = x509.load_pem_x509_csr(certificateSigningRequest.encode("utf-8"))
        except ValueError:
            raise _client_error("InvalidRequestException", "CreateCertificateFromCsr") from None
        cert = _leaf(self._ca_cert, csr.subject, csr.public_key(), 365,
                     ExtendedKeyUsageOID.CLIENT_AUTH).sign(self._ca_key, hashes.SHA256())
        certificate_id = cert.fingerprint(hashes.SHA256()).hex()
        record = {
            "certificateArn": ARN_PREFIX + "cert/" + certificate_id,
            "certificateId": certificate_id,
            "certificatePem": _pem(cert).decode("ascii"),
            "status": "ACTIVE" if setAsActive else "INACTIVE",
            "things": [],
            "policies": [],
        }
        with self._lock:
            self._certs[certificate_id] = record
        return {k: record[k] for k in ("certificateArn", "certificateId", "certificatePem")}

    def create_thing(self, thingName):
        # Real IoT is idempotent for an identical create_thing, so no AlreadyExists here.
        with self._lock:
            self._things.add(thingName)
        return {"thingName": thingName, "thingArn": ARN_PREFIX + "thing/" + thingName}

    def attach_thing_principal(self, thingName, principal):
        with self._lock:
            if thingName not in self._things:
                raise _client_error("ResourceNotFoundException", "AttachThingPrincipal")
            things = self._cert(principal.rsplit("/", 1)[-1], "AttachThingPrincipal")["things"]
            if thingName not in things:
                things.append(thingName)
        return {}

    def attach_policy(self, policyName, target):
        with self._lock:
            policies = self._cert(target.rsplit("/", 1)[-1], "AttachPolicy")["policies"]
            if policyName not in policies:
                policies.append(policyName)
        return {}

    def describe_certificate(self, certificateId):
        with self._lock:
            record = dict(self._cert(certificateId, "DescribeCertificate"))
        return {"certificateDescription": {
            k: record[k] for k in ("certificateArn", "certificateId", "certificatePem", "status")
        }}

    def list_principal_things(self, principal):
        with self._lock:
            things = list(self._cert(principal.rsplit("/", 1)[-1], "ListPrincipalThings")["things"])
        return {"things": things}

    def update_certificate(self, certificateId, newStatus):
        with self._lock:
            self._cert(certificateId, "UpdateCertificate")["status"] = newStatus


def write_tls_pair(sans, out_dir):
    """Write broker-cert.pem, broker-key.pem (0600) and ca.pem into out_dir.

    The signing CA's key is discarded, so ca.pem can vouch for this one pair only.
    """
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    ca_key, ca_cert = _new_ca("arlowe local broker CA")
    key = ec.generate_private_key(ec.SECP256R1())
    names = []
    for san in sans:
        try:
            names.append(x509.IPAddress(ipaddress.ip_address(san)))
        except ValueError:
            names.append(x509.DNSName(san))
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, sans[0])])
    cert = (
        _leaf(ca_cert, subject, key.public_key(), 90, ExtendedKeyUsageOID.SERVER_AUTH)
        .add_extension(x509.SubjectAlternativeName(names), critical=False)
        .sign(ca_key, hashes.SHA256())
    )
    _write(out_dir / "broker-key.pem", key.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption()), 0o600)
    _write(out_dir / "broker-cert.pem", _pem(cert))
    _write(out_dir / "ca.pem", _pem(ca_cert))


def main(argv=None):
    parser = argparse.ArgumentParser(prog="stub_iot.py", description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    tls = sub.add_parser("tls", help="write a local broker TLS pair and its ca.pem")
    tls.add_argument("--san", action="append", required=True,
                     help="IP address or DNS name the device dials; repeatable")
    tls.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    write_tls_pair(args.san, args.out)


if __name__ == "__main__":
    main()
