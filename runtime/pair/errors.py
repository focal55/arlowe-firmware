"""Pairing failure kinds and their owner-facing strings (ADR-0011).

The one copy the display, portal, flow and join import, so the Whisplay and the
portal cannot disagree about what went wrong.
"""
import enum


class ErrorKind(str, enum.Enum):
    wifi_rejected = "wifi_rejected"
    wifi_not_found = "wifi_not_found"
    wifi_failed = "wifi_failed"
    server_unreachable = "server_unreachable"
    claim_rejected = "claim_rejected"
    cert_failed = "cert_failed"
    not_configured = "not_configured"
    setup_failed = "setup_failed"


MESSAGES = {
    ErrorKind.wifi_rejected: "Wi-Fi password not accepted",
    ErrorKind.wifi_not_found: "Wi-Fi network not found",
    ErrorKind.wifi_failed: "Couldn't join Wi-Fi",
    ErrorKind.server_unreachable: "Can't reach Arlowe servers",
    ErrorKind.claim_rejected: "Setup code not accepted",
    ErrorKind.cert_failed: "Couldn't get device certificate",
    ErrorKind.not_configured: "No setup server configured",
    ErrorKind.setup_failed: "Couldn't finish setup",
}


class JoinError(Exception):
    def __init__(self, kind):
        self.kind = ErrorKind(kind)
        super().__init__(self.kind.value)
