"""The pairing state machine: optimistic handoff (ADR-0011, research Pattern 3).

WAITING -> CONNECTING -> PROVISIONING -> COMMITTING -> PAIRED, or ERROR with an
ErrorKind from any step after the submission. Every collaborator is injected:
`net` (NetMan), `display.show(screen)` where screen is a state name or an
ErrorKind, `identity(broker_url, ca_path, claim_code) -> (exit, json)`,
`commit(form, provisioned)`, `broker() -> (url, ca_path | None) | None`,
`ntp_synced()`, `on_paired(provisioned)` and the session's ssid/psk.

On any failure after the AP drops, every saved Wi-Fi profile is deleted (an
unpaired unit has none), the AP returns with the same session password, and the
submitted form stays in memory so the owner re-enters only the failing field.
PAIRED is terminal here: the daemon (08-23) owns the paired hold, releasing the
display and starting the runtime units. Nothing secret is ever logged.
"""
import enum
import json
import logging
import os
import subprocess
import threading
import time

from pair.errors import MESSAGES, ErrorKind, JoinError
from pair.netman import NetManError

log = logging.getLogger("arlowe.pair.flow")

HANDOFF_DELAY_S = 2  # let the portal's answer reach the phone before the AP drops
NTP_WAIT_S = 30
NTP_POLL_S = 1
IDENTITY_BIN = "arlowe-identity"
PROVISION_TIMEOUT_S = 60
STATUS_TIMEOUT_S = 15
SECRET_FIELDS = ("psk", "password", "claim_code")
RESULT_FIELDS = ("device_id", "certificate_id", "certificate_arn", "thing_name",
                 "credentials_endpoint", "role_alias", "provisioned_at")


class State(str, enum.Enum):
    WAITING = "waiting"
    CONNECTING = "connecting"
    PROVISIONING = "provisioning"
    COMMITTING = "committing"
    PAIRED = "paired"
    ERROR = "error"


class _Failed(Exception):
    def __init__(self, kind):
        self.kind = ErrorKind(kind)
        super().__init__(self.kind.value)


def classify_identity_failure(code, body):
    """Map a failed `arlowe-identity provision --json` run to an ErrorKind (N6)."""
    status = body.get("http_status")
    if code == 4 and status is None:
        return ErrorKind.server_unreachable
    if code == 3 and status == 401:
        return ErrorKind.claim_rejected
    return ErrorKind.cert_failed


def _call_identity(argv, env, timeout):
    try:
        res = subprocess.run(argv, env=env, capture_output=True, timeout=timeout,
                             check=False)
    except subprocess.TimeoutExpired:
        log.warning("arlowe-identity %s timed out after %ds", argv[1], timeout)
        return 4, {"http_status": None}
    except OSError as exc:
        log.error("arlowe-identity %s could not run: %s", argv[1], type(exc).__name__)
        return 5, {}
    try:
        body = json.loads(res.stdout)
    except ValueError:
        body = {}
    log.info("arlowe-identity %s: exit %d", argv[1], res.returncode)
    return res.returncode, body if isinstance(body, dict) else {}


def run_identity(broker_url, ca_bundle_path, claim_code, binary=IDENTITY_BIN,
                 timeout=PROVISION_TIMEOUT_S):
    """Provision through the CLI, the claim code in the environment only.

    A certificate already in the store (a retry after setup_failed) is returned
    as the result instead of requesting a second one.
    """
    env = {k: v for k, v in os.environ.items()
           if k not in ("ARLOWE_OWNER_TOKEN", "ARLOWE_BROKER_CA_BUNDLE")}
    code, status = _call_identity([binary, "status", "--json"], env, STATUS_TIMEOUT_S)
    if code == 0 and status.get("provisioned"):
        log.info("certificate already stored; not requesting another")
        return 0, {k: status.get(k) for k in RESULT_FIELDS}
    env["ARLOWE_OWNER_TOKEN"] = claim_code
    if ca_bundle_path:
        env["ARLOWE_BROKER_CA_BUNDLE"] = ca_bundle_path
    return _call_identity([binary, "provision", "--json", "--ca-broker-url", broker_url],
                          env, timeout)


class PairingFlow:
    def __init__(self, net, display, commit, broker, ntp_synced, session,
                 identity=run_identity, on_paired=lambda provisioned: None,
                 clock=time.monotonic, sleep=time.sleep):
        self._net, self._display, self._commit = net, display, commit
        self._broker, self._ntp_synced, self._session = broker, ntp_synced, session
        self._identity, self._on_paired = identity, on_paired
        self._clock, self._sleep = clock, sleep
        self._lock = threading.Lock()
        self.state = State.WAITING
        self._error = None
        self._held = None

    def status(self):
        """A snapshot for the portal: no secret, only whether one is held."""
        with self._lock:
            held = self._held or {}
            return {"status": self.state.value,
                    "error_kind": self._error.value if self._error else None,
                    "message": MESSAGES[self._error] if self._error else None,
                    "last_form": {k: v for k, v in held.items() if k not in SECRET_FIELDS},
                    "has_previous": {k: bool(held.get(k)) for k in SECRET_FIELDS}}

    def submit(self, form):
        """Run one pairing attempt on the caller's thread; False if one is running."""
        with self._lock:
            if self.state not in (State.WAITING, State.ERROR):
                log.warning("submission refused: pairing is %s", self.state.value)
                return False
            form = self._with_held(dict(form))
            self._held, self._error, self.state = form, None, State.CONNECTING
        try:
            self._pair(form)
        except _Failed as exc:
            self._recover(exc.kind)
        except Exception as exc:
            log.error("pairing step crashed: %s", type(exc).__name__)
            self._recover(ErrorKind.setup_failed)
        return True

    def _with_held(self, form):
        held = self._held or {}
        for key in ("password", "claim_code"):
            if not form.get(key) and held.get(key):
                form[key] = held[key]
        # A blank PSK for a different network means an open network, not "reuse".
        if not form.get("psk") and held.get("psk") and held.get("ssid") == form.get("ssid"):
            form["psk"] = held["psk"]
        return form

    def _enter(self, state):
        with self._lock:
            self.state = state
        log.info("pairing: %s", state.value)
        self._display.show(state.value)

    def _pair(self, form):
        broker = self._broker()
        if broker is None:
            self._set_error(ErrorKind.not_configured)
            return
        url, ca_path = broker
        self._enter(State.CONNECTING)
        self._sleep(HANDOFF_DELAY_S)
        try:
            self._net.ap_down()
            self._net.join(form["ssid"], form.get("psk", ""))
        except JoinError as exc:
            raise _Failed(exc.kind)
        except NetManError as exc:
            log.error("join failed: %s", exc)
            raise _Failed(ErrorKind.wifi_failed)

        self._enter(State.PROVISIONING)
        self._wait_for_ntp()
        code, body = self._identity(url, ca_path, form["claim_code"])
        if code != 0 or not body.get("certificate_id"):
            raise _Failed(classify_identity_failure(code, body))
        provisioned = {**body, "broker_url": url}

        self._enter(State.COMMITTING)
        try:
            self._commit(form, provisioned)
        except Exception as exc:
            log.error("commit failed: %s", type(exc).__name__)
            raise _Failed(ErrorKind.setup_failed)

        with self._lock:
            self.state, self._held = State.PAIRED, None
        log.info("pairing: paired")
        self._display.show(State.PAIRED.value)
        self._on_paired(provisioned)

    def _wait_for_ntp(self):
        """A factory clock can predate the broker certificate's notBefore."""
        deadline = self._clock() + NTP_WAIT_S
        while not self._ntp_synced():
            if self._clock() >= deadline:
                log.warning("clock not NTP-synchronized after %ds; continuing", NTP_WAIT_S)
                return
            self._sleep(NTP_POLL_S)

    def _recover(self, kind):
        """Delete every saved Wi-Fi profile and bring the setup AP back."""
        try:
            for uuid_ in self._net.wifi_profiles():
                self._net.delete_profile(uuid_)
        except NetManError as exc:
            log.error("deleting saved profiles failed: %s", exc)
        try:
            self._net.ap_up(self._session.ssid, self._session.psk)
        except NetManError as exc:
            log.error("restoring the setup AP failed: %s", exc)
        self._set_error(kind)

    def _set_error(self, kind):
        with self._lock:
            self.state, self._error = State.ERROR, kind
        log.warning("pairing failed: %s", kind.value)
        self._display.show(kind)
