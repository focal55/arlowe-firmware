"""
Unit tests for arlowe_cloud.

Run from repo root:
    PYTHONPATH=runtime/lib python3 -m pytest runtime/lib/tests/test_arlowe_cloud.py -q

Fully offline: requests.get/post are patched in every test that would otherwise
leave the process. Key material is generated at runtime into a tmp_path store --
committing a .key/.crt/.pem fixture under runtime/ would land it in the image,
because pi-gen/stage-arlowe/01-runtime rsyncs all of runtime/ with no excludes and
07-04's build gate scans that path.
"""

import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

import pytest
import requests
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.x509.oid import NameOID

sys.path.insert(0, str(Path(__file__).parent.parent))

import arlowe_cloud as cloud
import arlowe_identity as ident
import arlowe_pki as pki

DEVICE_ID = "abcdef0123456789abcdef0123456789"
ENDPOINT = "creds-host.example.invalid"
ALIAS = "arlowe-test-alias"
SECRET_KEY = "test-secret-access-key"
OWNER_TOKEN = "test-owner-token"
BROKER_URL = "https://broker.example.invalid"
POLL_INTERVAL = 900

STORE_FILES = {
    "DEVICE_ID_PATH": "device-id",
    "ENTROPY_PATH": "device-entropy",
    "KEY_PATH": "device.key",
    "CSR_PATH": "device.csr",
    "CERT_PATH": "device.crt",
    "METADATA_PATH": "identity.json",
}


class FakeResponse:
    def __init__(self, status_code, payload=None, text=None):
        self.status_code = status_code
        self._payload = payload
        if text is None:
            text = json.dumps(payload) if payload is not None else ""
        self.text = text

    def json(self):
        if self._payload is None:
            raise ValueError("response body is not JSON")
        return self._payload


def _patch(target, failure):
    """Patch requests.<target> with a response or an exception side effect."""
    if isinstance(failure, Exception):
        return mock.patch.object(requests, target, side_effect=failure)
    return mock.patch.object(requests, target, return_value=failure)


@pytest.fixture
def store(monkeypatch, tmp_path):
    """Relocate the identity store and reset the module-level credential cache."""
    store_dir = tmp_path / "identity"
    store_dir.mkdir(parents=True)
    monkeypatch.setenv("ARLOWE_IDENTITY_DIR", str(store_dir))
    monkeypatch.setattr(ident, "IDENTITY_DIR", store_dir)
    for attr, name in STORE_FILES.items():
        monkeypatch.setattr(ident, attr, store_dir / name)
    cloud.clear_credential_cache()
    yield store_dir
    cloud.clear_credential_cache()


@pytest.fixture
def config(monkeypatch):
    identity = {
        "provisioning_url": "",
        "credentials_endpoint": "",
        "role_alias": "",
        "poll_interval_seconds": POLL_INTERVAL,
    }
    monkeypatch.setattr(cloud, "load", lambda: {"identity": identity})
    return identity


@pytest.fixture
def provisioned(store, config):
    """A store holding a device id, a key, a self-signed cert and provisioned endpoints."""
    key = pki.ensure_keypair()
    ident.write_secret(ident.DEVICE_ID_PATH, DEVICE_ID.encode())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, DEVICE_ID)])
    now = datetime.now(timezone.utc).replace(tzinfo=None)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(days=1))
        .not_valid_after(now + timedelta(days=1))
        .sign(key, hashes.SHA256())
    )
    pki.store_certificate(cert.public_bytes(serialization.Encoding.PEM).decode())
    ident.update_metadata(device_id=DEVICE_ID, credentials_endpoint=ENDPOINT, role_alias=ALIAS)
    return store


def credentials_payload(lifetime_seconds=POLL_INTERVAL):
    expiry = datetime.now(timezone.utc) + timedelta(seconds=lifetime_seconds)
    return {
        "credentials": {
            "accessKeyId": "test-access-key-id",
            "secretAccessKey": SECRET_KEY,
            "sessionToken": "test-session-token",
            "expiration": expiry.strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
    }


def broker_payload(**overrides):
    payload = {field: "test-" + field for field in cloud.BROKER_FIELDS}
    payload.update(overrides)
    return payload


def test_missing_certificate_raises_before_any_network_call(store, config):
    with mock.patch.object(requests, "get") as get:
        with pytest.raises(cloud.NotProvisioned):
            cloud.fetch_credentials()
    get.assert_not_called()


def test_fetch_credentials_happy_path(provisioned, config):
    with _patch("get", FakeResponse(200, credentials_payload())) as get:
        creds = cloud.fetch_credentials()

    assert set(creds) == {"accessKeyId", "secretAccessKey", "sessionToken", "expiration"}
    assert creds["secretAccessKey"] == SECRET_KEY
    kwargs = get.call_args[1]
    assert get.call_args[0][0] == "https://%s/role-aliases/%s/credentials" % (ENDPOINT, ALIAS)
    assert kwargs["cert"] == (str(ident.CERT_PATH), str(ident.KEY_PATH))
    assert kwargs["headers"]["x-amzn-iot-thingname"] == DEVICE_ID
    assert kwargs["verify"] is True


def test_403_is_certificate_revoked_and_not_cloud_unavailable(provisioned, config):
    with _patch("get", FakeResponse(403, text="certificate is inactive")):
        with pytest.raises(cloud.CertificateRevoked) as excinfo:
            cloud.fetch_credentials()

    assert "inactive" in str(excinfo.value)
    assert not isinstance(excinfo.value, cloud.CloudUnavailable)


@pytest.mark.parametrize(
    "failure",
    [FakeResponse(500, text="internal error"), requests.ConnectionError("no route to host")],
)
def test_5xx_and_transport_failures_are_cloud_unavailable(provisioned, config, failure):
    with _patch("get", failure):
        with pytest.raises(cloud.CloudUnavailable) as excinfo:
            cloud.fetch_credentials()

    assert not isinstance(excinfo.value, cloud.CertificateRevoked)


def test_cache_serves_the_second_call_and_force_refresh_bypasses_it(provisioned, config):
    with _patch("get", FakeResponse(200, credentials_payload())) as get:
        first = cloud.fetch_credentials()
        assert cloud.fetch_credentials() == first
        assert get.call_count == 1
        cloud.fetch_credentials(force_refresh=True)
        assert get.call_count == 2


def test_an_elapsed_cache_entry_triggers_a_second_exchange(provisioned, config, monkeypatch):
    clock = [1000.0]
    monkeypatch.setattr(cloud, "_now", lambda: clock[0])
    with _patch("get", FakeResponse(200, credentials_payload())) as get:
        cloud.fetch_credentials()
        clock[0] += POLL_INTERVAL + 1
        cloud.fetch_credentials()

    assert get.call_count == 2


def test_cache_ttl_is_capped_at_the_poll_interval(provisioned, config, monkeypatch):
    """Trap 3's regression test: a 12-hour credential may not outlive one poll."""
    clock = [1000.0]
    monkeypatch.setattr(cloud, "_now", lambda: clock[0])
    long_lived = credentials_payload(lifetime_seconds=12 * 3600)
    with _patch("get", FakeResponse(200, long_lived)):
        cloud.fetch_credentials()

    expires_at, _ = cloud._credential_cache
    assert expires_at - clock[0] == POLL_INTERVAL

    far_future = long_lived["credentials"]["expiration"]
    assert cloud._cache_ttl(far_future, POLL_INTERVAL) == POLL_INTERVAL
    assert cloud._cache_ttl(far_future, 86400) <= 12 * 3600 - 60

    soon = credentials_payload(lifetime_seconds=300)["credentials"]["expiration"]
    assert cloud._cache_ttl(soon, POLL_INTERVAL) <= 240


def test_credentials_are_never_written_to_disk(provisioned, config):
    with _patch("get", FakeResponse(200, credentials_payload())):
        cloud.fetch_credentials()

    for path in provisioned.rglob("*"):
        if path.is_file():
            assert SECRET_KEY not in path.read_text(errors="replace")


def test_resolve_endpoints_prefers_config_over_identity_json(provisioned, config):
    config["credentials_endpoint"] = "override-host.example.invalid"
    config["role_alias"] = "override-alias"
    assert cloud.resolve_endpoints() == ("override-host.example.invalid", "override-alias")


def test_resolve_endpoints_falls_back_to_identity_json(provisioned, config):
    assert cloud.resolve_endpoints() == (ENDPOINT, ALIAS)


def test_resolve_endpoints_raises_not_provisioned_when_both_are_empty(store, config):
    with pytest.raises(cloud.NotProvisioned):
        cloud.resolve_endpoints()


def test_request_certificate_rejects_a_plaintext_url():
    with mock.patch.object(requests, "post") as post:
        with pytest.raises(cloud.ProvisioningRejected):
            cloud.request_certificate("http://broker.example.invalid", OWNER_TOKEN, DEVICE_ID, "csr")
    post.assert_not_called()


def test_request_certificate_returns_the_full_issuance_without_logging_the_token(caplog):
    caplog.set_level("DEBUG")
    with _patch("post", FakeResponse(200, broker_payload())) as post:
        issued = cloud.request_certificate(BROKER_URL, OWNER_TOKEN, DEVICE_ID, "csr-pem")

    assert set(issued) == set(cloud.BROKER_FIELDS)
    assert post.call_args[0][0] == BROKER_URL + "/v1/certificates"
    kwargs = post.call_args[1]
    assert kwargs["json"] == {"device_id": DEVICE_ID, "csr": "csr-pem"}
    assert kwargs["headers"]["Authorization"] == "Bearer " + OWNER_TOKEN
    assert OWNER_TOKEN not in caplog.text


def test_request_certificate_rejects_a_half_populated_response():
    payload = broker_payload()
    del payload["role_alias"]
    with _patch("post", FakeResponse(200, payload)):
        with pytest.raises(cloud.ProvisioningRejected, match="role_alias"):
            cloud.request_certificate(BROKER_URL, OWNER_TOKEN, DEVICE_ID, "csr")


@pytest.mark.parametrize(
    "status,reason",
    [
        (401, "unauthorized"),
        (400, "malformed_request"),
        (400, "invalid_device_id"),
        (400, "unparseable_csr"),
        (400, "csr_subject_mismatch"),
        (404, "not_found"),
    ],
)
def test_broker_rejection_reasons_stay_distinguishable(status, reason):
    with _patch("post", FakeResponse(status, {"error": reason})):
        with pytest.raises(cloud.ProvisioningRejected) as excinfo:
            cloud.request_certificate(BROKER_URL, OWNER_TOKEN, DEVICE_ID, "csr")

    assert excinfo.value.status == status
    assert excinfo.value.reason == reason


@pytest.mark.parametrize(
    "failure",
    [
        FakeResponse(503, {"error": "unavailable"}),
        FakeResponse(502, {"error": "issuance_failed", "detail": "ThrottlingException"}),
        requests.Timeout("read timed out"),
    ],
)
def test_broker_5xx_and_transport_failures_are_cloud_unavailable(failure):
    with _patch("post", failure):
        with pytest.raises(cloud.CloudUnavailable):
            cloud.request_certificate(BROKER_URL, OWNER_TOKEN, DEVICE_ID, "csr")


def test_staging_ca_bundle_overrides_apply_to_both_calls(provisioned, config, monkeypatch, tmp_path):
    bundle = tmp_path / "staging-ca-bundle"
    bundle.write_text("")
    monkeypatch.setenv("ARLOWE_BROKER_CA_BUNDLE", str(bundle))
    monkeypatch.setenv("ARLOWE_CLOUD_CA_BUNDLE", str(bundle))

    with _patch("post", FakeResponse(200, broker_payload())) as post:
        cloud.request_certificate(BROKER_URL, OWNER_TOKEN, DEVICE_ID, "csr")
    with _patch("get", FakeResponse(200, credentials_payload())) as get:
        cloud.fetch_credentials()

    assert post.call_args[1]["verify"] == str(bundle)
    assert get.call_args[1]["verify"] == str(bundle)
