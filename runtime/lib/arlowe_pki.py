"""
Device keypair, CSR, and on-disk certificate.

Installed flat at /opt/arlowe/runtime/lib/arlowe_pki.py; import as:
    from arlowe_pki import ensure_keypair, ensure_csr

Entirely offline: nothing here talks to a broker or to AWS. arlowe_cloud submits
the CSR this module produces and hands the issued PEM back to store_certificate.

**The private key is never returned as bytes, never logged, and never written
anywhere but KEY_PATH.** Its escape is the entire threat model of this phase; keep
every new function in this module honouring that.

API floor: the image runs system python3 against Debian bookworm's
python3-cryptography 38.0.4. /opt/arlowe/venvs is empty on the built image, so the
43.x pin in runtime/lib/requirements.txt is for CI and laptops only. This module
stays inside the 38.0.4 surface: ec.generate_private_key, ec.SECP256R1,
x509.CertificateSigningRequestBuilder, x509.Name, x509.NameAttribute,
NameOID.COMMON_NAME, serialization Encoding.PEM / PrivateFormat.PKCS8 /
NoEncryption, load_pem_private_key, load_pem_x509_csr, load_pem_x509_certificate,
and hashes.SHA256. x509.verification and not_valid_after_utc /
not_valid_before_utc arrived in 42 and are unavailable here; not_valid_after and
not_valid_before are naive UTC and are what this module uses.

That floor is enforced by the python-floor-bookworm job in .github/workflows/ci.yml,
which runs this suite in a debian:bookworm container against the apt package. That
job is the authority, not a laptop: a one-shot local install of 38.0.4 would not
stop the next contributor from reaching for a 42-only API and shipping it.

Paths come from arlowe_identity and are read through the module (ident.KEY_PATH)
rather than imported by name, because they are import-time constants that tests
relocate via ARLOWE_IDENTITY_DIR. write_secret is the single writer for all of it.
"""

import arlowe_identity as ident
from arlowe_identity import write_secret
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

TIMESTAMP_FORMAT = "%Y-%m-%dT%H:%M:%SZ"


class IdentityMismatch(RuntimeError):
    """Persisted identity material does not belong to this device or its key."""


def _common_name(name: x509.Name) -> str:
    attributes = name.get_attributes_for_oid(NameOID.COMMON_NAME)
    return attributes[0].value if attributes else ""


def ensure_keypair() -> ec.EllipticCurvePrivateKey:
    """Return the device private key, generating and persisting it exactly once.

    P-256 is within AWS IoT's accepted set (RSA >= 2048, or NIST P-256/P-384/P-521)
    and is the cheapest of them on a Pi 5.

    write_secret is O_EXCL plus an explicit chmod, so the key is write-once and its
    mode is independent of the process umask. That matters: systemd's default UMask
    is 0022 and Python's default file mode is 0666 & ~umask, which would produce
    0644 and fail SC3's exact-0600 check. 07-08b's unit also sets UMask=0077; both
    belts are deliberate.
    """
    if ident.KEY_PATH.exists():
        return serialization.load_pem_private_key(ident.KEY_PATH.read_bytes(), password=None)

    key = ec.generate_private_key(ec.SECP256R1())
    write_secret(
        ident.KEY_PATH,
        key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        ),
    )
    return key


def load_csr_pem() -> str:
    """Return the persisted CSR PEM. Raises FileNotFoundError if there is none."""
    return ident.CSR_PATH.read_text()


def ensure_csr(device_id: str) -> str:
    """Return the device CSR PEM, generating and persisting it exactly once.

    The subject CN is the device-id, but it is human-facing provenance only. AWS is
    not documented to preserve the CSR subject verbatim in the issued certificate,
    and authorization binds to the IoT Thing name and the certificate id instead
    (ADR-0007). Do not build an authorization decision on this CN.

    A persisted CSR carrying a different CN is not regenerated: a CN that disagrees
    with the persisted device-id means something upstream is wrong, and silently
    replacing it would hide that from the operator.
    """
    if ident.CSR_PATH.exists():
        pem = load_csr_pem()
        existing = _common_name(x509.load_pem_x509_csr(pem.encode()).subject)
        if existing != device_id:
            raise IdentityMismatch(
                f"{ident.CSR_PATH} has subject CN {existing!r}, device-id is {device_id!r}"
            )
        return pem

    csr = (
        x509.CertificateSigningRequestBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, device_id)]))
        .sign(ensure_keypair(), hashes.SHA256())
    )
    pem = csr.public_bytes(serialization.Encoding.PEM).decode()
    write_secret(ident.CSR_PATH, pem.encode())
    return pem


def certificate_matches_key(cert: x509.Certificate, key: ec.EllipticCurvePrivateKey) -> bool:
    """True when cert was issued over key's public key."""
    return cert.public_key().public_numbers() == key.public_key().public_numbers()


def store_certificate(pem: str) -> None:
    """Persist an issued certificate at CERT_PATH, replacing any existing one.

    Both checks run before anything touches disk: a broker returning garbage, or a
    certificate issued over somebody else's public key, must not leave a corrupt or
    unusable device.crt behind.

    0600 is stricter than a certificate needs -- a certificate is public -- but SC3
    states 0600 and 07-04's build gate tests for exact equality. Do not "fix" this
    to 0644.
    """
    cert = x509.load_pem_x509_certificate(pem.encode())
    if not certificate_matches_key(cert, ensure_keypair()):
        raise IdentityMismatch("certificate public key does not match the device private key")

    # write_secret is write-once by design, so replacement has to be explicit.
    # Re-provisioning after a revocation is a legitimate operation; the key itself
    # is untouched and keeps its O_EXCL guarantee.
    ident.CERT_PATH.unlink(missing_ok=True)
    write_secret(ident.CERT_PATH, cert.public_bytes(serialization.Encoding.PEM))


def load_certificate() -> x509.Certificate:
    """Return the persisted certificate. Raises FileNotFoundError if there is none."""
    return x509.load_pem_x509_certificate(ident.CERT_PATH.read_bytes())


def certificate_summary() -> dict:
    """Return the certificate's public facts for `arlowe-identity status` and boot-check.

    Never touches the private key. not_valid_before / not_valid_after are naive UTC
    on the 38.0.4 floor and are rendered as explicit Z timestamps so callers do not
    have to know that.
    """
    cert = load_certificate()
    return {
        "subject_cn": _common_name(cert.subject),
        "issuer_cn": _common_name(cert.issuer),
        "serial_number": cert.serial_number,
        "not_valid_before": cert.not_valid_before.strftime(TIMESTAMP_FORMAT),
        "not_valid_after": cert.not_valid_after.strftime(TIMESTAMP_FORMAT),
        "fingerprint_sha256": cert.fingerprint(hashes.SHA256()).hex(),
    }
