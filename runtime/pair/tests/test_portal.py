"""
Captive portal against a real server on an ephemeral port.

Run from repo root:
    PYTHONPATH=runtime:runtime/lib python3 -m pytest runtime/pair/tests/test_portal.py -q
"""

import http.client
import json
import logging
import re
import secrets
import threading
import urllib.parse
from pathlib import Path

import pytest

from pair import portal
from pair.errors import MESSAGES, ErrorKind

BANLIST = Path(__file__).resolve().parents[3] / "scripts/sanitize/banlist.txt"
CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
PORTAL = "10.42.0.1"


def claim_code():
    raw = "".join(secrets.choice(CROCKFORD) for _ in range(20))
    return "-".join(raw[i:i + 5] for i in range(0, 20, 5))


def banned_name():
    for line in BANLIST.read_text(encoding="utf-8").splitlines():
        entry = line.strip().lower()
        if re.fullmatch(r"[a-z0-9-]+", entry):
            return "my " + entry
    pytest.skip("banlist has no hostname-shaped entry")


@pytest.fixture
def secrets_form():
    return {
        "ssid": "Home Net",
        "ssid_other": "",
        "psk": "wifi-" + secrets.token_hex(6),
        "name": "Kitchen Arlowe",
        "password": "dash-" + secrets.token_hex(6),
        "password_confirm": None,
        "claim_code": claim_code(),
    }


@pytest.fixture
def portal_server():
    state = {"status": "waiting", "error_kind": None, "ip_hint": None,
             "ap_ssid": "Arlowe-Setup-ab12",
             "networks": [{"ssid": "Home Net", "signal": 80, "secure": True},
                          {"ssid": "Cafe <Guest>", "signal": 40, "secure": False}],
             "last_form": {}, "has_previous": {}}
    calls, called = [], threading.Event()

    def on_submit(form):
        calls.append(form)
        called.set()

    srv = portal.make_server(state, on_submit, "127.0.0.1", 0)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()

    class Portal:
        def request(self, method, path, host=PORTAL, body=None, headers=None):
            conn = http.client.HTTPConnection("127.0.0.1", srv.server_address[1], timeout=5)
            hdrs = {"Host": host, **(headers or {})}
            conn.request(method, path, body=body, headers=hdrs)
            resp = conn.getresponse()
            data = resp.read().decode()
            conn.close()
            return resp, data

        def post(self, form):
            form = dict(form)
            if form.get("password_confirm") is None:
                form["password_confirm"] = form.get("password", "")
            body = urllib.parse.urlencode(form)
            return self.request("POST", "/pair", body=body, headers={
                "Content-Type": "application/x-www-form-urlencoded"})

    p = Portal()
    p.state, p.calls, p.called = state, calls, called
    yield p
    srv.shutdown()
    srv.server_close()


@pytest.mark.parametrize("host,path", [
    ("captive.apple.com", "/hotspot-detect.html"),
    ("connectivitycheck.gstatic.com", "/generate_204"),
    ("www.msftconnecttest.com", "/connecttest.txt"),
    ("detectportal.firefox.com", "/success.txt"),
])
def test_probe_redirects_to_portal(portal_server, host, path):
    resp, _ = portal_server.request("GET", path, host=host)
    assert resp.status == 302
    assert resp.getheader("Location") == "http://10.42.0.1/"
    assert resp.getheader("Connection") == "close"
    assert resp.getheader("Cache-Control") == "no-store"


def test_form_lists_networks_fields_and_handoff(portal_server):
    resp, page = portal_server.request("GET", "/", host="10.42.0.1:80")
    assert resp.status == 200
    assert resp.getheader("Cache-Control") == "no-store"
    assert "Home Net" in page and "Cafe &lt;Guest&gt;" in page
    for field in ("ssid", "ssid_other", "psk", "name", "password",
                  "password_confirm", "claim_code"):
        assert f'name="{field}"' in page
    assert ".local:3000" in page
    assert "reconnect to Arlowe-Setup-ab12 and reload this page" in page
    assert "<script" not in page


def test_valid_submit_answers_then_hands_off_once(portal_server, secrets_form):
    resp, page = portal_server.post(secrets_form)
    assert resp.status == 200
    assert "Switching networks" in page
    assert portal_server.called.wait(5)
    assert len(portal_server.calls) == 1
    form = portal_server.calls[0]
    assert form["ssid"] == "Home Net"
    assert form["psk"] == secrets_form["psk"]
    assert form["display_name"] == "Kitchen Arlowe"
    assert form["slug"] == "kitchen-arlowe"
    assert form["password"] == secrets_form["password"]
    assert form["claim_code"] == secrets_form["claim_code"].replace("-", "")


def test_typed_ssid_overrides_the_pick(portal_server, secrets_form):
    secrets_form["ssid_other"] = "Hidden Net"
    resp, _ = portal_server.post(secrets_form)
    assert resp.status == 200
    assert portal_server.called.wait(5)
    assert portal_server.calls[0]["ssid"] == "Hidden Net"


@pytest.mark.parametrize("field,value,needle", [
    ("ssid", "x" * 33, "32"),
    ("psk", "short", "8"),
    ("psk", "g" * 64, "64"),
    ("name", "", "Enter a name"),
    ("password", "short", "8 characters"),
    ("password_confirm", "does-not-match", "match"),
    ("claim_code", "ABCD-EFGH", "setup code"),
])
def test_invalid_field_is_refused_without_handoff(portal_server, secrets_form, field, value, needle):
    secrets_form[field] = value
    resp, page = portal_server.post(secrets_form)
    assert resp.status == 400
    assert needle in page
    assert f'data-error="{field}"' in page
    assert 'name="ssid_other"' in page
    assert not portal_server.called.wait(0.3)


def test_banned_name_names_the_problem_only(portal_server, secrets_form):
    secrets_form["name"] = banned_name()
    resp, page = portal_server.post(secrets_form)
    assert resp.status == 400
    assert "That name is not allowed" in page
    assert not portal_server.called.wait(0.3)


def test_oversized_body_is_413(portal_server):
    resp, _ = portal_server.request("POST", "/pair", body="a=" + "x" * 9000, headers={
        "Content-Type": "application/x-www-form-urlencoded"})
    assert resp.status == 413
    assert not portal_server.calls


def test_status_json(portal_server):
    portal_server.state.update(status="error", error_kind="claim_rejected")
    resp, body = portal_server.request("GET", "/status")
    assert resp.status == 200
    assert resp.getheader("Content-Type").startswith("application/json")
    assert json.loads(body) == {"status": "error", "error_kind": "claim_rejected",
                                "message": MESSAGES[ErrorKind.claim_rejected]}


def test_after_error_form_prefills_but_never_secrets(portal_server, secrets_form):
    portal_server.state.update(
        status="error", error_kind="wifi_rejected",
        last_form={"ssid": "Typed Net", "name": "Kitchen Arlowe"},
        has_previous={"psk": True, "password": True, "claim_code": True})
    _, page = portal_server.request("GET", "/")
    assert MESSAGES[ErrorKind.wifi_rejected] in page
    assert 'value="Typed Net"' in page and 'value="Kitchen Arlowe"' in page
    for secret in (secrets_form["psk"], secrets_form["password"], secrets_form["claim_code"]):
        assert secret not in page


def test_blank_secrets_reuse_previous_only_when_held(portal_server, secrets_form):
    blank = dict(secrets_form, psk="", password="", password_confirm="", claim_code="")
    resp, _ = portal_server.post(blank)
    assert resp.status == 400

    portal_server.state["has_previous"] = {"psk": True, "password": True, "claim_code": True}
    resp, _ = portal_server.post(blank)
    assert resp.status == 200
    assert portal_server.called.wait(5)
    form = portal_server.calls[0]
    assert form["psk"] is None and form["password"] is None and form["claim_code"] is None


def test_validate_form_is_pure():
    base = {"ssid": "Net", "psk": "a" * 64, "name": "Den", "password": "longenough",
            "password_confirm": "longenough", "claim_code": claim_code().lower()}
    assert portal.validate_form(base, {})["psk"] == "a" * 64
    assert portal.validate_form(dict(base, psk=""), {})["psk"] == ""
    with pytest.raises(portal.FormError) as exc:
        portal.validate_form(dict(base, ssid="bad\nnet"), {})
    assert exc.value.field == "ssid"


def test_no_secret_is_logged(portal_server, secrets_form, caplog, capfd):
    caplog.set_level(logging.DEBUG)
    portal_server.post(secrets_form)
    portal_server.post(dict(secrets_form, password_confirm="mismatch-" + secrets.token_hex(4)))
    portal_server.request("GET", "/?psk=" + secrets_form["psk"])
    assert portal_server.called.wait(5)
    out, err = capfd.readouterr()
    logged = caplog.text + out + err
    assert "GET" in logged or "POST" in logged
    code = secrets_form["claim_code"]
    for secret in (secrets_form["psk"], secrets_form["password"], code, code.replace("-", "")):
        assert secret not in logged
