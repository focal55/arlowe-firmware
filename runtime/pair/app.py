"""The pairing daemon (ADR-0011): NetMan, the Whisplay, the portal, the flow and
the commit wired into one process.

run() owns the main thread: it raises the setup network, runs the 30-minute idle
timeout off the injected clock, and after a successful pairing performs the
handoff (paired screen, hold, release the Whisplay, start the six, return 0).
Submissions run on the portal's threads, the button on the driver's.
"""
import logging
import threading
import types

from pair.display import Screen
from pair.errors import ErrorKind
from pair.flow import State
from pair.netman import NetManError, session_credentials

log = logging.getLogger("arlowe.pair.app")

IDLE_S = 30 * 60
POLL_S = 0.5
MISSING_IDENTITY = "Device identity missing"


class _FlowDisplay:
    """The flow's view of the Whisplay. The home IP exists once the join is up, and
    the paired screen needs the URL and IP only the daemon has, so it draws that."""

    def __init__(self, app):
        self._app = app

    def show(self, screen):
        if screen == State.PROVISIONING.value:
            self._app.learn_ip()
        if screen != State.PAIRED.value:
            self._app.display.show(screen)


class PairApp:
    def __init__(self, net, display, portal_factory, flow_factory, committer, clock,
                 broker_source, device_id_reader, bind_addr, hold_s,
                 poll_s=POLL_S, idle_s=IDLE_S):
        self.net, self.display, self.committer, self.clock = net, display, committer, clock
        self._portal_factory, self._flow_factory = portal_factory, flow_factory
        self._broker_source, self._read_device_id = broker_source, device_id_reader
        self._bind_addr, self.hold_s, self.poll_s, self.idle_s = bind_addr, hold_s, poll_s, idle_s
        self.state = {"networks": [], "ap_ssid": None, "ip_hint": None}
        self.flow = self.session = self._server = self._slug = None
        self._ap, self._idle_since = False, 0.0
        self._lock = threading.Lock()
        self._wake, self._stop = threading.Event(), threading.Event()
        self._button, self._paired = threading.Event(), threading.Event()

    def stop(self):
        self._stop.set()
        self._wake.set()

    def _on_button(self, *_):
        self._button.set()
        self._wake.set()

    def _on_paired(self, provisioned):
        self._paired.set()
        self._wake.set()

    def run(self):
        self.display.on_button(self._on_button)
        self._sweep_wifi_profiles()
        try:
            device_id = self._read_device_id().strip()
        except OSError as exc:
            log.error("device identity unreadable: %s", type(exc).__name__)
            device_id = ""
        if device_id:
            self._new_session(device_id)
        else:
            log.error("no device identity; pairing cannot start")
            self.display.show(Screen.error(ErrorKind.setup_failed, detail=MISSING_IDENTITY))
        while not (self._stop.is_set() or self._paired.is_set()):
            self._wake.wait(self.poll_s)
            self._wake.clear()
            if self._button.is_set():
                self._button.clear()
                if device_id and not self._ap and not self._paired.is_set():
                    self._new_session(device_id)
            self._check_idle()
        if self._paired.is_set():
            return self._handoff()
        self._shutdown()
        return 0

    def _sweep_wifi_profiles(self):
        # Every Wi-Fi profile here is stale: the unit only runs while unpaired, and
        # an unpaired unit has no saved Wi-Fi profile (ADR-0011's invariant).
        try:
            for uuid_ in self.net.wifi_profiles():
                self.net.delete_profile(uuid_)
        except NetManError as exc:
            log.error("stale profile sweep failed: %s", exc)

    def _new_session(self, device_id):
        ssid, psk = session_credentials(device_id)
        self.session = types.SimpleNamespace(ssid=ssid, psk=psk)
        self.display.ssid, self.display.psk = ssid, psk
        try:
            self.net.radio_on()
            try:
                self.state["networks"] = self.net.scan()
            except NetManError as exc:
                log.error("scan failed; the owner can type the network: %s", exc)
            self.net.ap_up(ssid, psk)
        except NetManError as exc:
            log.error("setup network did not come up: %s", exc)
            self.display.show("idle")
            return
        self.state["ap_ssid"] = ssid
        self.flow = self._flow_factory(
            net=self.net, display=_FlowDisplay(self), commit=self.committer,
            broker=self._broker_source, session=self.session,
            on_paired=self._on_paired, view=self.state)
        with self._lock:
            self._ap, self._idle_since = True, self.clock()
        if self._server is None:
            # The bind address exists only while the AP is up; the socket survives
            # the address going away and coming back with the next session.
            self._server = self._portal_factory(self.state, self._submit, *self._bind_addr)
            threading.Thread(target=self._server.serve_forever, daemon=True).start()
        log.info("setup network up; waiting for the owner")
        self.display.show("waiting")

    def _submit(self, form):
        with self._lock:
            if not self._ap:
                return False
            flow, self._idle_since = self.flow, self.clock()
            if flow.state in (State.WAITING, State.ERROR):
                self._slug = form["slug"]
        try:
            return flow.submit(form)
        finally:
            with self._lock:
                self._idle_since = self.clock()

    def _check_idle(self):
        with self._lock:
            if not self._ap or self.flow.state not in (State.WAITING, State.ERROR):
                return
            if self.clock() - self._idle_since < self.idle_s:
                return
            self._ap = False
        log.info("no submission for %d s; setup network down", self.idle_s)
        self._ap_down()
        self.display.show("idle")

    def _ap_down(self):
        try:
            self.net.ap_down()
        except NetManError as exc:
            log.error("setup network down failed: %s", exc)

    def learn_ip(self):
        try:
            self.state["ip_hint"] = self.net.ipv4_address() or self.state["ip_hint"]
        except NetManError as exc:
            log.warning("IP lookup failed: %s", exc)
        return self.state["ip_hint"] or ""

    def _stop_portal(self):
        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()

    def _handoff(self):
        # config.yml is committed, so Restart=on-failure would not rerun this
        # daemon: whatever fails here, the six must still be started.
        try:
            self.display.url = f"http://{self._slug}.local:3000"
            self.display.ip = self.learn_ip()
            self._button.clear()
            self.display.show("paired")
            end = self.clock() + self.hold_s
            while (self.clock() < end and not self._button.is_set()
                   and not self._stop.is_set()):
                self._wake.wait(self.poll_s)
                self._wake.clear()
            self._stop_portal()
            self.display.close()
        finally:
            self.committer.start_runtime()
        log.info("paired; handed over to the runtime units")
        return 0

    def _shutdown(self):
        self._stop_portal()
        self._ap_down()
        self.display.close()


build_app = PairApp
