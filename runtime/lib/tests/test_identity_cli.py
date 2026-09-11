"""
Subcommand tests for the arlowe-identity CLI.

Run from repo root:
    PYTHONPATH=runtime/lib python3 -m pytest runtime/lib/tests/test_identity_cli.py -q

Lives in the runtime/lib suite so CI's python-test and python-floor-bookworm jobs
both run it; the bookworm job is the authority on the cryptography 38.0.4 floor.

Fully offline: arlowe_cloud's two network functions are patched in every test that
would otherwise leave the process. Key and certificate material is generated at
runtime into a tmp_path store, never committed -- pi-gen's 01-runtime stage rsyncs
all of runtime/ into /opt/arlowe/runtime/, which is exactly the tree plan 07-04's
build gate scans for identity material.
"""

import importlib.util
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.x509.oid import NameOID

sys.path.insert(0, str(Path(__file__).parent.parent))

import arlowe_cloud as cloud
import arlowe_config
import arlowe_identity as ident
import arlowe_pki as pki

# Resolved from this file, never from the cwd: CI runs pytest from the repo root
# and a developer may not, and a cwd-relative path would make the suite pass or
# fail depending on where it was invoked from.
CLI_PATH = Path(__file__).resolve().parents[3] / "runtime/cli/identity"
FIXTURE_ROOT = Path(__file__).parent / "fixtures" / "identity" / "all_three"

# A hard assert, not a skip. A silently-skipped CLI suite is indistinguishable
# from a passing one.
assert CLI_PATH.is_file(), "arlowe-identity CLI not found at %s" % CLI_PATH

STORE_FILES = {"DEVICE_ID_PATH": "device-id", "ENTROPY_PATH": "device-entropy",
               "KEY_PATH": "device.key", "CSR_PATH": "device.csr",
               "CERT_PATH": "device.crt", "METADATA_PATH": "identity.json"}
PROVISIONED_FIELDS = ("certificate_id", "certificate_arn", "thing_name",
                      "credentials_endpoint", "role_alias", "provisioned_at")
DERIVATION_FIELDS = ("device_id", "serial_source", "derived_at")
BROKER_URL = "https://broker.example.invalid"
OWNER_TOKEN = "test-owner-bearer-token"
SECRET_KEY = "test-secret-access-key"
SESSION_TOKEN = "test-session-token"
EXPIRATION = "2099-01-01T00:00:00Z"


def _load_cli():
    """Import the extensionless CLI file as a module."""
    spec = importlib.util.spec_from_file_location("arlowe_identity_cli", CLI_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


cli = _load_cli()


@pytest.fixture
def store(monkeypatch, tmp_path):
    """Relocate the identity store and the serial sources onto tmp_path."""
    store_dir = tmp_path / "identity"
    store_dir.mkdir(parents=True)
    monkeypatch.setenv("ARLOWE_IDENTITY_DIR", str(store_dir))
    monkeypatch.setattr(ident, "IDENTITY_DIR", store_dir)
    for attr, name in STORE_FILES.items():
        monkeypatch.setattr(ident, attr, store_dir / name)
    monkeypatch.setattr(ident, "SERIAL_ROOT", FIXTURE_ROOT)
    monkeypatch.setattr(ident, "SERIAL_SOURCES", ident._build_sources(FIXTURE_ROOT))
    cloud.clear_credential_cache()
    yield store_dir
    cloud.clear_credential_cache()


@pytest.fixture
def config(monkeypatch, tmp_path):
    """A merged config with an empty provisioning_url and a relocated overlay path."""
    merged = {"device": {"hostname": "arlowe-" + ident.HOSTNAME_PLACEHOLDER},
              "identity": {"provisioning_url": "", "credentials_endpoint": "",
                           "role_alias": "", "poll_interval_seconds": 900}}
    monkeypatch.setattr(cli, "load", lambda: merged)
    monkeypatch.setattr(cloud, "load", lambda: merged)
    monkeypatch.setattr(arlowe_config, "OVERLAY", tmp_path / "etc" / "arlowe" / "config.yml")
    return merged


def run(capsys, *argv):
    """Drive main(argv) in-process; return (exit_code, all captured output)."""
    code = cli.main(list(argv))
    captured = capsys.readouterr()
    return code, captured.out + captured.err


def mode_of(path):
    return path.stat().st_mode & 0o777


def issued_certificate_pem():
    """A certificate over the device key, as the broker would return it."""
    key = pki.ensure_keypair()
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "arlowe-test-ca")])
    now = datetime.now(timezone.utc).replace(tzinfo=None)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
            .public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - timedelta(days=1))
            .not_valid_after(now + timedelta(days=1))
            .sign(key, hashes.SHA256()))
    return cert.public_bytes(serialization.Encoding.PEM).decode()


def issuance():
    payload = {field: "test-" + field for field in cloud.BROKER_FIELDS}
    payload["certificate_pem"] = issued_certificate_pem()
    return payload


def credentials():
    return {"accessKeyId": "AKIATESTACCESSKEYID", "secretAccessKey": SECRET_KEY,
            "sessionToken": SESSION_TOKEN, "expiration": EXPIRATION}


def provision(capsys, *extra):
    with mock.patch.object(cloud, "request_certificate", return_value=issuance()) as post:
        code, output = run(capsys, "provision", "--ca-broker-url", BROKER_URL, *extra)
    return code, output, post


def test_init_is_idempotent(store, config, capsys):
    first_code, first = run(capsys, "init", "--json")
    second_code, second = run(capsys, "init", "--json")
    assert (first_code, second_code) == (0, 0)
    assert json.loads(first)["device_id"] == json.loads(second)["device_id"]
    assert len(json.loads(first)["device_id"]) == 32


def test_init_resolves_a_hostname_free_of_founder_literals(store, config, capsys):
    code, output = run(capsys, "init", "--json")
    hostname = json.loads(output)["hostname"]
    assert code == 0
    assert hostname.startswith("arlowe-d")
    assert "arlowe-1" not in hostname


def test_init_without_an_identity_dir_exits_5_and_creates_nothing(monkeypatch, tmp_path, capsys):
    """An absent store means the owner_state partition did not mount.

    Creating it would write identity material to the underlying slot rootfs, where
    the next A/B flip discards it. 07-08b's unit carries no Condition* guard
    precisely because this failure is loud.
    """
    absent = tmp_path / "not-mounted" / "identity"
    monkeypatch.setattr(ident, "IDENTITY_DIR", absent)
    for attr, name in STORE_FILES.items():
        monkeypatch.setattr(ident, attr, absent / name)
    code, output = run(capsys, "init")
    assert code == 5
    assert str(absent) in output
    assert not absent.exists()


def test_status_on_an_unprovisioned_device_exits_0(store, config, capsys):
    run(capsys, "init")
    code, output = run(capsys, "status", "--json")
    payload = json.loads(output)
    assert code == 0
    assert payload["cert_present"] is False
    assert payload["key_present"] is True and payload["csr_present"] is True
    assert payload["certificate"] is None
    assert payload["modes"]["device.key"] == "600"


def test_provision_stores_the_certificate_and_merges_metadata(store, config, capsys):
    """The O_EXCL regression test.

    identity.json already exists by the time provision merges its results, because
    step 1's ensure_device_id created it. A naive write_secret would raise
    FileExistsError and a naive unlink-then-rewrite would silently drop the
    derivation fields; only update_metadata preserves them.
    """
    code, output, post = provision(capsys)
    metadata = json.loads((store / "identity.json").read_text())

    assert code == 0
    assert (store / "device.crt").exists()
    assert all(metadata.get(field) for field in PROVISIONED_FIELDS)
    assert all(metadata.get(field) for field in DERIVATION_FIELDS)
    assert metadata["device_id"] == (store / "device-id").read_text().strip()
    assert mode_of(store / "identity.json") == 0o600
    assert post.call_args[0][0] == BROKER_URL
    assert not arlowe_config.OVERLAY.exists()
    assert "BEGIN" not in output


@pytest.mark.parametrize("error,expected", [
    (cloud.ProvisioningRejected("csr_subject_mismatch", status=409), 3),
    (cloud.CloudUnavailable("broker unreachable"), 4),
])
def test_provision_maps_cloud_errors_to_distinct_exit_codes(store, config, capsys,
                                                            error, expected):
    with mock.patch.object(cloud, "request_certificate", side_effect=error):
        code, _ = run(capsys, "provision", "--ca-broker-url", BROKER_URL,
                      "--owner-token", OWNER_TOKEN)
    assert code == expected


def test_provision_without_a_broker_url_exits_2(store, config, capsys):
    code, output = run(capsys, "provision", "--owner-token", OWNER_TOKEN)
    assert code == 2
    assert "--ca-broker-url" in output


def test_provision_without_any_token_exits_2(store, config, monkeypatch, capsys):
    monkeypatch.delenv("ARLOWE_OWNER_TOKEN", raising=False)
    code, output = run(capsys, "provision", "--ca-broker-url", BROKER_URL)
    assert code == 2
    assert "ARLOWE_OWNER_TOKEN" in output


@pytest.mark.parametrize("source", ["file", "env"])
def test_provision_accepts_the_token_from_a_file_or_the_environment(store, config, monkeypatch,
                                                                    tmp_path, capsys, source):
    """Neither form puts the token on an argv line, where ps would expose it."""
    extra = ()
    if source == "file":
        token_file = tmp_path / "owner-token"
        token_file.write_text(OWNER_TOKEN + "\n")
        extra = ("--owner-token-file", str(token_file))
    else:
        monkeypatch.setenv("ARLOWE_OWNER_TOKEN", OWNER_TOKEN)

    code, output, post = provision(capsys, *extra)
    assert code == 0
    assert post.call_args[0][1] == OWNER_TOKEN
    assert OWNER_TOKEN not in output


@pytest.mark.parametrize("error,expected", [
    (cloud.CertificateRevoked("credentials provider refused the certificate"), 6),
    (cloud.CloudUnavailable("connection reset"), 4),
    (cloud.NotProvisioned("identity store is incomplete"), 5),
])
def test_check_cloud_exit_codes_are_distinguishable(store, config, capsys, error, expected):
    """Exit 6 is the SC4 signal and must mean revoked, never merely failed."""
    with mock.patch.object(cloud, "fetch_credentials", side_effect=error):
        code, _ = run(capsys, "check-cloud")
    assert code == expected


def test_check_cloud_emits_expiration_and_no_secret(store, config, capsys):
    with mock.patch.object(cloud, "fetch_credentials", return_value=credentials()) as fetch:
        code, output = run(capsys, "check-cloud", "--json")
    payload = json.loads(output)

    assert code == 0
    assert payload["expiration"] == EXPIRATION
    assert SECRET_KEY not in output and SESSION_TOKEN not in output
    assert payload["access_key_id_prefix"] in credentials()["accessKeyId"]
    assert credentials()["accessKeyId"] not in output
    assert fetch.call_args[1]["force_refresh"] is True


def test_check_cloud_human_output_hides_the_secret(store, config, capsys):
    with mock.patch.object(cloud, "fetch_credentials", return_value=credentials()):
        code, output = run(capsys, "check-cloud")
    assert code == 0
    assert SECRET_KEY not in output and SESSION_TOKEN not in output
    assert EXPIRATION in output


def test_reset_without_force_deletes_nothing(store, config, capsys):
    run(capsys, "init")
    before = sorted(p.name for p in store.iterdir())
    code, output = run(capsys, "reset")
    assert code != 0
    assert "--force" in output
    assert sorted(p.name for p in store.iterdir()) == before


def test_reset_force_empties_the_store_and_keeps_it_at_0700(store, config, capsys):
    provision(capsys)
    assert list(store.iterdir())
    code, _ = run(capsys, "reset", "--force")
    assert code == 0
    assert list(store.iterdir()) == []
    assert mode_of(store) == 0o700
