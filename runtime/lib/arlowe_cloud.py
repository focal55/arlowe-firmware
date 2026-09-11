"""
Certificate-authenticated cloud client: CSR submission and credential exchange.

Installed flat at /opt/arlowe/runtime/lib/arlowe_cloud.py; import as:
    from arlowe_cloud import fetch_credentials

Standard library plus `requests` only -- no AWS SDK and no IoT MQTT client on the
device. The brokered design (ADR-0007) needs one HTTPS POST to pair and one HTTPS
GET per poll; the bookworm floor is python3-requests 2.28.1.

SigV4 signing is deliberately absent, not forgotten: Phase 9 (OTA) and Phase 10
(support mode) sign their own downstream calls with a real SDK. Phase 7 needs no
signed call to prove revocation, because the credentials exchange below IS the
authenticated call and is where AWS checks certificate status.

Paths come through arlowe_identity (ident.CERT_PATH), not by-name import, so tests
relocate the whole store with ARLOWE_IDENTITY_DIR.
"""

import logging
import os
import time
from datetime import datetime, timezone
from urllib.parse import urlparse

import requests

import arlowe_identity as ident
from arlowe_config import load
from arlowe_identity import read_metadata

LOG = logging.getLogger("arlowe.cloud")

BROKER_PATH = "/v1/certificates"
TIMEOUT = (5, 30)
EXPIRY_MARGIN_SECONDS = 60
POLL_INTERVAL_FLOOR = 900
BROKER_FIELDS = ("certificate_pem", "certificate_id", "certificate_arn",
                 "thing_name", "credentials_endpoint", "role_alias")
CREDENTIAL_FIELDS = ("accessKeyId", "secretAccessKey", "sessionToken", "expiration")

# In-memory only, module level: (monotonic_deadline, credentials). Never written to
# disk. 07-09's revocation probe warms this in-process, revokes, then reads it again,
# which only works if the cache outlives the call.
_credential_cache = None


class CloudError(Exception):
    """Base for every failure of a cloud call."""


class NotProvisioned(CloudError):
    """The device has no certificate, key, or resolved endpoint yet."""


class CertificateRevoked(CloudError):
    """The credentials provider refused the device certificate (HTTP 403)."""


class CloudUnavailable(CloudError):
    """Transport failure, timeout, or a 5xx from the broker or AWS."""


class ProvisioningRejected(CloudError):
    """The broker refused the CSR or answered with a half-populated body.

    Carries .status and .reason so a caller can tell a retryable request bug
    (malformed_request) from a real identity fault (csr_subject_mismatch).
    """

    def __init__(self, reason, status=None):
        super().__init__("broker rejected the CSR: %s (status %s)" % (reason, status))
        self.reason = reason
        self.status = status


def _now():
    """Monotonic clock, indirected so tests can advance it."""
    return time.monotonic()


def _ca_bundle(variable):
    """Return the requests verify= argument: an override path, or system trust.

    ARLOWE_*_CA_BUNDLE is staging-only, for a self-signed broker or endpoint. The
    image vendors no root CA: Debian's ca-certificates already carries Amazon Root
    CA 1, and a *.pem under /opt/arlowe trips 07-04's build gate.
    """
    return os.environ.get(variable) or True


def _identity_config():
    return load().get("identity") or {}


def clear_credential_cache():
    """Drop the cached credentials. For tests and for forced re-authentication."""
    global _credential_cache
    _credential_cache = None


def resolve_endpoints():
    """Return (credentials_endpoint, role_alias), config overriding provisioning.

    Per-field precedence: the config identity.* override when non-empty, else what
    `arlowe-identity provision` recorded in identity.json; NotProvisioned if neither.
    Neither is ever a tracked literal -- the endpoint is account-identifying.
    identity.json is read through read_metadata(), never opened directly, so its
    shape has one owner; its ValueError on corrupt JSON propagates deliberately,
    because a provisioned device with an unreadable identity.json is a fault, not a
    factory state.
    """
    config = _identity_config()
    endpoint = (config.get("credentials_endpoint") or "").strip()
    alias = (config.get("role_alias") or "").strip()
    if not endpoint or not alias:
        metadata = read_metadata()
        endpoint = endpoint or (metadata.get("credentials_endpoint") or "").strip()
        alias = alias or (metadata.get("role_alias") or "").strip()
    if not endpoint or not alias:
        raise NotProvisioned("no credentials endpoint or role alias in config or "
                             "identity.json; run arlowe-identity provision")
    return endpoint, alias


def _cache_ttl(expiration, poll_interval):
    """Seconds a credential set may be reused: min(lifetime - margin, poll_interval).

    The cap is load-bearing. Revocation stops new exchanges but does not retroactively
    invalidate an already-issued STS token, so the honest bound is
    max(poll_interval, remaining_credential_lifetime). The role alias is provisioned
    with credentialDurationSeconds=900 (07-05a) and poll_interval_seconds has a schema
    floor of 900, so capping at the poll interval collapses that to one polling
    interval -- the number SC4 tests against. Never raise this cap. An unparseable
    expiration yields 0, because not caching is always safe.
    """
    try:
        expires_at = datetime.fromisoformat(expiration.replace("Z", "+00:00"))
    except (AttributeError, ValueError):
        LOG.warning("credential expiration is unparseable; caching disabled")
        return 0
    remaining = (expires_at - datetime.now(timezone.utc)).total_seconds()
    return int(max(0, min(remaining - EXPIRY_MARGIN_SECONDS, poll_interval)))


def fetch_credentials(force_refresh=False):
    """Exchange the device certificate for short-lived cloud credentials.

    GET https://{endpoint}/role-aliases/{alias}/credentials over mutual TLS: the
    client certificate is the authentication, and x-amzn-iot-thingname must name the
    Thing it is attached to or AWS answers 403. Returns the four CREDENTIAL_FIELDS.
    Raises NotProvisioned before any network call when the store is incomplete,
    CertificateRevoked on 403 and nothing else, CloudUnavailable on 5xx or transport
    failure. The poller is a short-lived process per poll, so the in-process cache
    gives near-zero cross-poll reuse, by design.
    """
    global _credential_cache
    if not force_refresh and _credential_cache is not None:
        deadline, cached = _credential_cache
        if _now() < deadline:
            return cached

    missing = [p for p in (ident.CERT_PATH, ident.KEY_PATH, ident.DEVICE_ID_PATH)
               if not p.exists()]
    if missing:
        raise NotProvisioned("identity store is incomplete (%s); run arlowe-identity provision"
                             % ", ".join(p.name for p in missing))

    endpoint, alias = resolve_endpoints()
    device_id = ident.DEVICE_ID_PATH.read_text().strip()
    try:
        response = requests.get(
            "https://%s/role-aliases/%s/credentials" % (endpoint, alias),
            cert=(str(ident.CERT_PATH), str(ident.KEY_PATH)),
            headers={"x-amzn-iot-thingname": device_id},
            verify=_ca_bundle("ARLOWE_CLOUD_CA_BUNDLE"),
            timeout=TIMEOUT,
        )
    except requests.RequestException as exc:
        raise CloudUnavailable("credentials exchange failed: %s" % exc) from exc

    if response.status_code == 403:
        # AWS distinguishes a revoked/inactive certificate from a thing-name mismatch
        # in the body, and a field diagnosis needs to see which one it was.
        raise CertificateRevoked("credentials provider refused the device certificate: %s"
                                 % response.text)
    if response.status_code != 200:
        raise CloudUnavailable("credentials provider returned %s" % response.status_code)

    try:
        body = response.json()["credentials"]
        credentials = {field: body[field] for field in CREDENTIAL_FIELDS}
    except (AttributeError, KeyError, TypeError, ValueError) as exc:
        raise CloudUnavailable("credentials provider returned an unusable body: %s" % exc) from exc

    ttl = _cache_ttl(credentials["expiration"],
                     int(_identity_config().get("poll_interval_seconds") or POLL_INTERVAL_FLOOR))
    _credential_cache = (_now() + ttl, credentials)
    LOG.info("credentials exchanged for thing=%s, cached for %ss", device_id, ttl)
    return credentials


def request_certificate(broker_url, owner_token, device_id, csr_pem):
    """Submit the CSR to the owner-token broker and return the issuance dict.

    One HTTPS POST implementing the contract frozen in plan 07-05b; returns all six
    BROKER_FIELDS. A half-populated 200 raises ProvisioningRejected rather than
    returning: a device that looks provisioned but cannot talk to anything is worse
    than one that failed loudly. The owner token is never logged.
    """
    if urlparse(broker_url).scheme != "https":
        # This call carries an owner bearer token; plaintext is not negotiable.
        raise ProvisioningRejected("broker URL must be https://, got %r" % broker_url)

    url = broker_url.rstrip("/") + BROKER_PATH
    host = urlparse(url).netloc
    try:
        response = requests.post(
            url,
            json={"device_id": device_id, "csr": csr_pem},
            headers={"Authorization": "Bearer " + owner_token},
            verify=_ca_bundle("ARLOWE_BROKER_CA_BUNDLE"),
            timeout=TIMEOUT,
        )
    except requests.RequestException as exc:
        raise CloudUnavailable("broker %s unreachable: %s" % (host, exc)) from exc

    LOG.info("POST %s%s device=%s -> %s", host, BROKER_PATH, device_id, response.status_code)
    if response.status_code >= 500:
        raise CloudUnavailable("broker %s returned %s" % (host, response.status_code))

    try:
        body = response.json()
    except ValueError as exc:
        raise ProvisioningRejected("unparseable broker response: %s" % exc,
                                   status=response.status_code) from exc

    if response.status_code != 200:
        raise ProvisioningRejected(body.get("error", "unknown"), status=response.status_code)
    absent = [field for field in BROKER_FIELDS if not body.get(field)]
    if absent:
        raise ProvisioningRejected("response is missing " + ", ".join(absent), status=200)
    return {field: body[field] for field in BROKER_FIELDS}
