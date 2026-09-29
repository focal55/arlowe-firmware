"""Captive setup portal: the owner's only input surface (ADR-0011).

Serves the setup form on the setup AP and redirects every other Host to it, so
phone and laptop captive-portal probes open the form. The portal owns no pairing
logic. It reads `state`, a mapping the flow keeps current:

    status, error_kind   flow position and the ErrorKind of the last failure
    networks             cached scan: [{"ssid", "signal", "secure"}]
    last_form            {"ssid", "name"} of the last submission, never secrets
    has_previous         {"psk", "password", "claim_code"}: the flow holds a value
    ip_hint, ap_ssid     shown in the handoff text

and hands a validated form to `on_submit(form)` on a new thread, after the
response is flushed: the phone must get its answer before the AP drops.

Nothing from a request body, and no query string, is ever logged.
"""

import html
import json
import logging
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from arlowe_hostname import HostnameRejected, slugify, validate_display_name
from pair.errors import MESSAGES, ErrorKind

log = logging.getLogger("pair.portal")

MAX_BODY = 8192
CLAIM_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
CLAIM_LENGTH = 20
_CLAIM_ALIASES = str.maketrans({"I": "1", "L": "1", "O": "0", "-": None, " ": None})
_HEX = frozenset("0123456789abcdefABCDEF")


class FormError(ValueError):
    def __init__(self, field, message):
        self.field = field
        super().__init__(message)


def _secret(fields, previous, name):
    """Return the field's value, or None when blank and the flow holds one."""
    value = fields.get(name, "")
    if value == "" and previous.get(name):
        return None
    return value


def validate_form(fields, previous):
    """Validate a submitted form; return the parsed dict or raise FormError.

    Pure. A blank secret comes back as None, meaning "reuse the held value".
    A blank PSK with none held means an open network and comes back as "".
    """
    ssid = fields.get("ssid_other", "").strip() or fields.get("ssid", "")
    if not ssid:
        raise FormError("ssid", "Choose a Wi-Fi network or type its name.")
    if len(ssid.encode("utf-8")) > 32:
        raise FormError("ssid", "Wi-Fi network names are at most 32 bytes.")
    if any(ord(c) < 0x20 or ord(c) == 0x7F for c in ssid):
        raise FormError("ssid", "That Wi-Fi network name has an invalid character.")

    psk = _secret(fields, previous, "psk")
    if psk:
        printable = 8 <= len(psk) <= 63 and all(0x20 <= ord(c) <= 0x7E for c in psk)
        if not (printable or (len(psk) == 64 and set(psk) <= _HEX)):
            raise FormError("psk", "Wi-Fi passwords are 8 to 63 characters, or 64 hex digits.")

    try:
        display_name, slug = validate_display_name(fields.get("name", ""))
    except HostnameRejected as exc:
        raise FormError("name", str(exc)) from None

    password = _secret(fields, previous, "password")
    confirm = fields.get("password_confirm", "")
    if password is None:
        if confirm:
            raise FormError("password_confirm", "The two dashboard passwords do not match.")
    elif len(password) < 8:
        raise FormError("password", "Use at least 8 characters for the dashboard password.")
    elif password != confirm:
        raise FormError("password_confirm", "The two dashboard passwords do not match.")

    code = _secret(fields, previous, "claim_code")
    if code is not None:
        code = code.strip().upper().translate(_CLAIM_ALIASES)
        if len(code) != CLAIM_LENGTH or any(c not in CLAIM_ALPHABET for c in code):
            raise FormError("claim_code", "Enter the 20-character setup code.")

    return {"ssid": ssid, "psk": psk, "display_name": display_name, "slug": slug,
            "password": password, "claim_code": code}


_CSS = ("body{font-family:system-ui,sans-serif;max-width:32em;margin:1em auto;padding:0 1em}"
        "label{display:block;margin-top:.8em;font-weight:600}"
        "input,select{width:100%;padding:.5em;font-size:1em;box-sizing:border-box}"
        "button{margin-top:1.2em;padding:.7em;width:100%;font-size:1.1em}"
        ".err{background:#fdd;padding:.6em;border-radius:4px}.note{color:#444}")


def _page(title, body):
    return (f'<!doctype html><html><head><meta charset="utf-8">'
            f'<meta name="viewport" content="width=device-width,initial-scale=1">'
            f"<title>{title}</title><style>{_CSS}</style></head>"
            f"<body><h1>{title}</h1>{body}</body></html>")


def _where(state, name):
    e = html.escape
    slug = slugify(name) if name else ""
    url = f"http://{e(slug)}.local:3000" if slug else "http://&lt;name&gt;.local:3000"
    text = f"Your Arlowe will be at <b>{url}</b>"
    if not slug:
        text += (", where &lt;name&gt; is the name you choose below in lowercase, with"
                 " spaces as hyphens (Kitchen Arlowe becomes kitchen-arlowe)")
    ip = state.get("ip_hint")
    text += f", or http://{e(ip)}:3000." if ip else ". Its screen also shows its IP address."
    ap = e(state.get("ap_ssid") or "the Arlowe-Setup network")
    return (f'<p class="note">{text}</p><p class="note">If anything goes wrong, reconnect'
            f" to {ap} and reload this page.</p>")


def render_form(state, values=None, error=None):
    e = html.escape
    values = values if values is not None else (state.get("last_form") or {})
    held = state.get("has_previous") or {}
    ssid, name = values.get("ssid", ""), values.get("name", "")
    parts = []
    if error:
        parts.append(f'<p class="err" data-error="{e(error.field)}">{e(str(error))}</p>')
    elif state.get("error_kind"):
        parts.append(f'<p class="err">{e(MESSAGES[ErrorKind(state["error_kind"])])}</p>')

    networks = state.get("networks") or []
    known = any(n["ssid"] == ssid for n in networks)
    opts = ['<option value="">Other (type it below)</option>']
    for n in networks:
        sel = " selected" if n["ssid"] == ssid else ""
        lock = "" if n.get("secure") else " (open)"
        opts.append(f'<option value="{e(n["ssid"])}"{sel}>{e(n["ssid"])}{lock}</option>')
    other = "" if known else ssid

    def secret(field, label, kind="password"):
        hint = " (leave blank to keep the last one)" if held.get(field) else ""
        return (f'<label for="{field}">{label}{hint}</label>'
                f'<input id="{field}" name="{field}" type="{kind}" autocomplete="off">')

    parts.append(
        '<form method="post" action="/pair">'
        f'<label for="ssid">Wi-Fi network</label><select id="ssid" name="ssid">{"".join(opts)}</select>'
        '<label for="ssid_other">Or type a network name</label>'
        f'<input id="ssid_other" name="ssid_other" value="{e(other)}" maxlength="64">'
        + secret("psk", "Wi-Fi password (blank for an open network)") +
        f'<label for="name">Name this Arlowe</label>'
        f'<input id="name" name="name" value="{e(name)}" maxlength="32" required>'
        + secret("password", "Dashboard password (8 or more characters)")
        + secret("password_confirm", "Dashboard password again")
        + secret("claim_code", "Setup code", kind="text")
        + _where(state, name) + '<button type="submit">Set up my Arlowe</button></form>')
    return _page("Set up your Arlowe", "".join(parts))


class _Handler(BaseHTTPRequestHandler):
    timeout = 15
    server_version = "arlowe-pair"
    sys_version = ""

    def log_message(self, format, *args):
        pass

    def log_request(self, code="-", size="-"):
        path = urllib.parse.urlsplit(self.path or "").path[:80]
        log.info("%s %s %s", self.command, path, code)

    def log_error(self, format, *args):
        log.warning("request rejected (%s)", args[0] if args else "?")

    def _send(self, code, body, ctype="text/html; charset=utf-8", headers=()):
        data = body.encode("utf-8")
        self.send_response(code)
        for key, value in headers:
            self.send_header(key, value)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
        self.wfile.flush()
        self.close_connection = True

    def _for_portal(self):
        host = (self.headers.get("Host") or "").strip().lower()
        if host.rsplit(":", 1)[-1].isdigit():
            host = host.rsplit(":", 1)[0]
        if host == self.server.portal_host:
            return True
        self._send(302, "", headers=[("Location", self.server.portal_url)])
        return False

    def do_GET(self):
        if not self._for_portal():
            return
        path = urllib.parse.urlsplit(self.path).path
        state = self.server.state
        if path == "/":
            self._send(200, render_form(state))
        elif path == "/status":
            kind = state.get("error_kind")
            self._send(200, json.dumps({
                "status": state.get("status"), "error_kind": kind,
                "message": MESSAGES[ErrorKind(kind)] if kind else None}),
                ctype="application/json")
        else:
            self._send(302, "", headers=[("Location", self.server.portal_url)])

    def do_POST(self):
        if not self._for_portal():
            return
        if urllib.parse.urlsplit(self.path).path != "/pair":
            self._send(302, "", headers=[("Location", self.server.portal_url)])
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if length > MAX_BODY:
            self.rfile.read(min(length, 8 * MAX_BODY))
            self._send(413, _page("Too much data", "<p>Reload the page and try again.</p>"))
            return
        try:
            if length < 0:
                raise ValueError
            raw = urllib.parse.parse_qs(self.rfile.read(length).decode("utf-8"),
                                        keep_blank_values=True, max_num_fields=32)
        except ValueError:
            self._send(400, _page("Bad request", "<p>Reload the page and try again.</p>"))
            return
        fields = {k: v[0] for k, v in raw.items()}
        state = self.server.state
        try:
            form = validate_form(fields, state.get("has_previous") or {})
        except FormError as exc:
            values = {"ssid": fields.get("ssid_other", "").strip() or fields.get("ssid", ""),
                      "name": fields.get("name", "")}
            self._send(400, render_form(state, values, exc))
            return
        slug = html.escape(form["slug"])
        self._send(200, _page("Switching networks…", (
            f"<p>Your Arlowe is leaving this setup network to join "
            f"<b>{html.escape(form['ssid'])}</b>. In about a minute, open "
            f"<b>http://{slug}.local:3000</b> from your home network.</p>"
            + _where(state, form["display_name"]))))
        threading.Thread(target=self.server.on_submit, args=(form,),
                         name="pair-submit", daemon=True).start()


def make_server(state, on_submit, host, port, portal_host="10.42.0.1"):
    """Bind the portal; the caller runs serve_forever(). Bind 10.42.0.1, never 0.0.0.0."""
    srv = ThreadingHTTPServer((host, port), _Handler)
    srv.state, srv.on_submit = state, on_submit
    srv.portal_host, srv.portal_url = portal_host, f"http://{portal_host}/"
    return srv
