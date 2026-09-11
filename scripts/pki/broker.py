#!/usr/bin/env python3
"""Owner-token CSR broker for the Phase 7 staging PKI. Dev host only.

Stands in for the owner-authenticated backend that signs a device's CSR using AWS
IoT Core's native issuance (`iot:CreateCertificateFromCsr`, Amazon root CA). AWS
Private CA is ruled out by ADR-0007 and no Private CA resource is touched here.

The token check is deliberately dumb, and that is the settled decision. This broker
compares the presented bearer token against $ARLOWE_BROKER_TOKEN and does not know
or care who issued it. A hand-minted token for a single unit and a token from a
future account system must both work here unchanged -- the owner-account question
belongs to Phase 8. Do not add a user table, an account lookup, or a token-minting
endpoint to this file.

Nothing under scripts/pki/ ships in the firmware image.
"""

import argparse
import hmac
import json
import logging
import os
import re
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from botocore.exceptions import ClientError
from cryptography import x509
from cryptography.x509.oid import NameOID

LOG = logging.getLogger("arlowe.broker")

ENDPOINT_PATH = "/v1/certificates"
MAX_BODY_BYTES = 16384
DEVICE_ID_RE = re.compile(r"[0-9a-f]{32}\Z")

# ARLOWE_PKI_* are the names frozen by scripts/pki/.staging-env (plan 07-05a).
REQUIRED_ENV = (
    "ARLOWE_BROKER_TOKEN",
    "ARLOWE_PKI_POLICY",
    "ARLOWE_PKI_ROLE_ALIAS",
    "ARLOWE_PKI_CREDENTIALS_ENDPOINT",
)


def load_config(env=None):
    """Return the broker settings, or raise SystemExit naming the missing variable.

    Called at startup rather than per-request so a misconfigured broker refuses to
    boot instead of serving half-populated 200s that a device would cache.
    """
    env = os.environ if env is None else env
    config = {}
    for name in REQUIRED_ENV:
        value = (env.get(name) or "").strip()
        if not value:
            raise SystemExit("broker.py: %s is unset or empty" % name)
        config[name] = value
    return config


def authorized(auth_header, expected_token):
    scheme, _, presented = (auth_header or "").partition(" ")
    presented = presented.strip()
    if scheme.lower() != "bearer" or not presented:
        return False
    return hmac.compare_digest(presented, expected_token)


def _csr_common_name(csr):
    attrs = csr.subject.get_attributes_for_oid(NameOID.COMMON_NAME)
    return attrs[0].value if attrs else ""


def handle_certificate_request(auth_header, body, iot, config):
    """Core of POST /v1/certificates. Returns (status_code, response_dict).

    `iot` is an injected boto3 IoT client so every response code is reachable in
    tests without an AWS account.
    """
    if not authorized(auth_header, config["ARLOWE_BROKER_TOKEN"]):
        LOG.warning("POST %s -> 401 unauthorized", ENDPOINT_PATH)
        return 401, {"error": "unauthorized"}

    try:
        payload = json.loads(body.decode("utf-8"))
        device_id = payload["device_id"]
        csr_pem = payload["csr"]
    except (UnicodeDecodeError, ValueError, TypeError, KeyError):
        LOG.warning("POST %s -> 400 malformed_request", ENDPOINT_PATH)
        return 400, {"error": "malformed_request"}

    if not isinstance(device_id, str) or not DEVICE_ID_RE.match(device_id):
        LOG.warning("POST %s -> 400 invalid_device_id", ENDPOINT_PATH)
        return 400, {"error": "invalid_device_id"}

    try:
        csr = x509.load_pem_x509_csr(csr_pem.encode("utf-8"))
    except (AttributeError, UnicodeEncodeError, ValueError):
        LOG.warning("POST %s device=%s -> 400 unparseable_csr", ENDPOINT_PATH, device_id)
        return 400, {"error": "unparseable_csr"}

    # The CN binding is what makes the issued certificate traceable to the derived
    # device id: the requester cannot ask for a cert under an identity it did not
    # name in the body, and the body is what the Thing gets named after.
    if _csr_common_name(csr) != device_id:
        LOG.warning("POST %s device=%s -> 400 csr_subject_mismatch", ENDPOINT_PATH, device_id)
        return 400, {"error": "csr_subject_mismatch"}

    try:
        issued = iot.create_certificate_from_csr(
            certificateSigningRequest=csr_pem, setAsActive=True
        )
        certificate_arn = issued["certificateArn"]
        certificate_id = issued["certificateId"]
        # Authorization binds to the Thing name and the certificate id, never to the
        # CSR subject: AWS does not document carrying the CSR CN through to the
        # issued certificate verbatim, so no policy may depend on reading it back.
        try:
            iot.create_thing(thingName=device_id)
        except ClientError as exc:
            if exc.response.get("Error", {}).get("Code") != "ResourceAlreadyExistsException":
                raise
        iot.attach_thing_principal(thingName=device_id, principal=certificate_arn)
        iot.attach_policy(policyName=config["ARLOWE_PKI_POLICY"], target=certificate_arn)
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "Unknown")
        LOG.error("POST %s device=%s -> 502 issuance_failed aws_code=%s",
                  ENDPOINT_PATH, device_id, code)
        return 502, {"error": "issuance_failed", "detail": code}

    LOG.info("POST %s device=%s -> 200 certificate_id=%s",
             ENDPOINT_PATH, device_id, certificate_id)
    return 200, {
        "certificate_pem": issued["certificatePem"],
        "certificate_id": certificate_id,
        "certificate_arn": certificate_arn,
        "thing_name": device_id,
        "credentials_endpoint": config["ARLOWE_PKI_CREDENTIALS_ENDPOINT"],
        "role_alias": config["ARLOWE_PKI_ROLE_ALIAS"],
    }


class BrokerHandler(BaseHTTPRequestHandler):
    """Thin HTTP shell. All decisions live in handle_certificate_request."""

    server_version = "arlowe-broker"
    sys_version = ""
    iot = None
    config = None

    def do_POST(self):
        if self.path != ENDPOINT_PATH:
            self._respond(404, {"error": "not_found"})
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if length < 0 or length > MAX_BODY_BYTES:
            self._respond(400, {"error": "malformed_request"})
            return
        status, payload = handle_certificate_request(
            self.headers.get("Authorization"), self.rfile.read(length), self.iot, self.config
        )
        self._respond(status, payload)

    def _respond(self, status, payload):
        encoded = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, fmt, *args):
        # Default BaseHTTPRequestHandler logging goes straight to stderr, bypassing
        # the module logger and its formatting. The request line carries no token.
        LOG.info("%s %s", self.address_string(), fmt % args)


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        prog="broker.py",
        description="Owner-token CSR broker for the Phase 7 staging PKI (dev host only).",
        epilog=(
            "Generate a self-signed staging TLS pair (both paths are gitignored):\n"
            "  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \\\n"
            "    -days 30 -subj '/CN=localhost' \\\n"
            "    -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \\\n"
            "    -keyout scripts/pki/broker-key.pem -out scripts/pki/broker-cert.pem\n\n"
            "Required environment: " + ", ".join(REQUIRED_ENV)
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8443)
    parser.add_argument("--certfile", default="scripts/pki/broker-cert.pem")
    parser.add_argument("--keyfile", default="scripts/pki/broker-key.pem")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    config = load_config()
    for path in (args.certfile, args.keyfile):
        if not os.path.exists(path):
            raise SystemExit("broker.py: TLS material not found: %s" % path)

    import boto3

    handler = type("ConfiguredBrokerHandler", (BrokerHandler,),
                   {"iot": boto3.client("iot"), "config": config})
    httpd = ThreadingHTTPServer((args.host, args.port), handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.certfile, args.keyfile)
    httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
    LOG.info("broker listening on https://%s:%d%s", args.host, args.port, ENDPOINT_PATH)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        httpd.server_close()


if __name__ == "__main__":
    main()
