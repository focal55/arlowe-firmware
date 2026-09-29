#!/usr/bin/env python3
"""Claim-code CSR broker for the staging PKI. Dev host only.

Stands in for the owner-authenticated backend that signs a device's CSR using AWS
IoT Core's native issuance (`iot:CreateCertificateFromCsr`, Amazon root CA). AWS
Private CA is ruled out by ADR-0007 and no Private CA resource is touched here.

The device presents its box card's claim code as an opaque bearer token (ADR-0007,
ADR-0012). The broker redeems it against the store at $ARLOWE_BROKER_CLAIM_CODES:
an unused code, or one already bound to the same device_id, gets a certificate and
binds only once issuance has succeeded. Every refusal is the same 401.

`--stub-iot` swaps the AWS client for scripts/pki/stub_iot.py so pairing's
certificate step runs with no AWS account; the AWS path never imports it.

Nothing under scripts/pki/ ships in the firmware image.
"""

import argparse
import json
import logging
import os
import re
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from botocore.exceptions import ClientError
from cryptography import x509
from cryptography.x509.oid import NameOID

import claim_codes

LOG = logging.getLogger("arlowe.broker")

ENDPOINT_PATH = "/v1/certificates"
MAX_BODY_BYTES = 16384
DEVICE_ID_RE = re.compile(r"[0-9a-f]{32}\Z")

CLAIM_CODES_ENV = "ARLOWE_BROKER_CLAIM_CODES"
# ARLOWE_PKI_* are the names frozen by scripts/pki/.staging-env (plan 07-05a).
REQUIRED_ENV = (
    CLAIM_CODES_ENV,
    "ARLOWE_PKI_POLICY",
    "ARLOWE_PKI_ROLE_ALIAS",
    "ARLOWE_PKI_CREDENTIALS_ENDPOINT",
)
# The stub has no account, so there is no .staging-env to source. These reach the
# device in the 200 body; .invalid keeps a stub-paired unit from dialing anything real.
STUB_PKI_DEFAULTS = {
    "ARLOWE_PKI_POLICY": "arlowe-stub-device-policy",
    "ARLOWE_PKI_ROLE_ALIAS": "arlowe-stub-role-alias",
    "ARLOWE_PKI_CREDENTIALS_ENDPOINT": "credentials.stub-iot.invalid",
}
UNAUTHORIZED = (401, {"error": "unauthorized"})


def load_config(env=None, stub=False):
    """Return the broker settings, or raise SystemExit naming the missing variable.

    Called at startup rather than per-request so a misconfigured broker refuses to
    boot instead of serving half-populated 200s that a device would cache.
    """
    env = os.environ if env is None else env
    config = {}
    for name in REQUIRED_ENV:
        value = (env.get(name) or "").strip() or (STUB_PKI_DEFAULTS.get(name, "") if stub else "")
        if not value:
            raise SystemExit("broker.py: %s is unset or empty" % name)
        config[name] = value
    if not os.path.isfile(config[CLAIM_CODES_ENV]):
        raise SystemExit("broker.py: %s names no file (claim_codes.py mint creates it)"
                         % CLAIM_CODES_ENV)
    return config


def presented_code_hash(auth_header):
    """Store key for the bearer value, or None when it cannot be a claim code."""
    scheme, _, presented = (auth_header or "").partition(" ")
    if scheme.lower() != "bearer":
        return None
    try:
        return claim_codes.code_hash(presented.strip())
    except ValueError:
        return None


def _csr_common_name(csr):
    attrs = csr.subject.get_attributes_for_oid(NameOID.COMMON_NAME)
    return attrs[0].value if attrs else ""


def handle_certificate_request(auth_header, body, iot, config):
    """Core of POST /v1/certificates. Returns (status_code, response_dict).

    `iot` is an injected boto3 IoT client (or StubIoT) so every response code is
    reachable in tests without an AWS account.
    """
    key = presented_code_hash(auth_header)
    if key is None:
        LOG.warning("POST %s -> 401 unauthorized", ENDPOINT_PATH)
        return UNAUTHORIZED

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

    # The lock spans check, issuance and bind: two devices racing one unused code
    # cannot both be issued, and a failed issuance never persists the binding.
    with claim_codes.ClaimStore(config[CLAIM_CODES_ENV]).transaction() as entries:
        after = claim_codes.redeem(entries.get(key), device_id)
        if after is None:
            LOG.warning("POST %s device=%s -> 401 unauthorized", ENDPOINT_PATH, device_id)
            return UNAUTHORIZED
        status, response = _issue(iot, config, csr_pem, device_id)
        if status == 200:
            entries[key] = after
        return status, response


def _issue(iot, config, csr_pem, device_id):
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
        description="Claim-code CSR broker for the staging PKI (dev host only).",
        epilog="Required environment: %s.\nSelf-signed TLS pair and the POST %s contract: "
               "see scripts/pki/README.md." % (", ".join(REQUIRED_ENV), ENDPOINT_PATH),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8443)
    parser.add_argument("--certfile", default="scripts/pki/broker-cert.pem")
    parser.add_argument("--keyfile", default="scripts/pki/broker-key.pem")
    parser.add_argument("--stub-iot", action="store_true",
                        help="issue from a local throwaway CA instead of AWS IoT")
    parser.add_argument("--stub-ca-dir", help="stub CA directory; created on first use")
    parser.add_argument("--stub-fail", choices=["issuance"],
                        help="make every stub issuance fail, so requests answer 502")
    args = parser.parse_args(argv)
    if args.stub_iot and not args.stub_ca_dir:
        parser.error("--stub-iot requires --stub-ca-dir")
    if (args.stub_ca_dir or args.stub_fail) and not args.stub_iot:
        parser.error("--stub-ca-dir and --stub-fail require --stub-iot")
    return args


def make_iot_client(args):
    if args.stub_iot:
        import stub_iot

        return stub_iot.StubIoT(args.stub_ca_dir, fail_issuance=args.stub_fail == "issuance")
    import boto3

    return boto3.client("iot")


def main(argv=None):
    args = parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    config = load_config(stub=args.stub_iot)
    for path in (args.certfile, args.keyfile):
        if not os.path.exists(path):
            raise SystemExit("broker.py: TLS material not found: %s" % path)

    handler = type("ConfiguredBrokerHandler", (BrokerHandler,),
                   {"iot": make_iot_client(args), "config": config})
    httpd = ThreadingHTTPServer((args.host, args.port), handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.certfile, args.keyfile)
    httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
    LOG.info("broker listening on https://%s:%d%s%s", args.host, args.port, ENDPOINT_PATH,
             " (stub IoT)" if args.stub_iot else "")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        httpd.server_close()


if __name__ == "__main__":
    main()
