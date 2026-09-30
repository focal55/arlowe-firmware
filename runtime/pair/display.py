"""Whisplay screens for pairing (ADR-0011).

The pairing daemon owns the panel until config.yml exists, then releases it to
arlowe-face. Screens are drawn on the same 280x240 canvas as the face and go
through the same RGB565 conversion.
"""
import dataclasses
import functools
import os
import sys
from typing import Optional

import qrcode
from PIL import Image, ImageDraw, ImageFont

from arlowe_display import DISP_HEIGHT, DISP_WIDTH, HEIGHT, WIDTH, to_rgb565
from pair.errors import MESSAGES, ErrorKind

DEFAULT_FONT_PATH = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
DEFAULT_DRIVER_PATH = "/opt/arlowe/third_party/whisplay-driver"

# The panel's corners are rounded; keep text clear of them.
PAD = 15
TEXT_WIDTH = WIDTH - 2 * PAD
TITLE_SIZE, BODY_SIZE, MIN_SIZE = 24, 18, 12
LINE_GAP = 6

# The payload is at most 47 bytes, which version 3 at level L (29 modules) holds.
# A lit panel has no print damage for a higher level to recover from, and the
# smaller code gets bigger modules. The 2-module quiet zone leaves room for text.
QR_ERROR_CORRECTION = qrcode.constants.ERROR_CORRECT_L
QR_BORDER = 2
QR_BOX = 170
QR_ORIGIN = 10
MIN_MODULE_PX = 4

BG, FG, ACCENT, ALERT = (17, 17, 17), (255, 255, 255), (80, 180, 255), (255, 110, 110)
DARK, LIGHT = (0, 0, 0), (255, 255, 255)

MESSAGE_IDLE = "Press the button to start setup"

BLUE = (0, 0, 255)
LED = {"waiting": BLUE, "connecting": BLUE, "provisioning": BLUE, "committing": BLUE,
       "paired": (0, 255, 0), "idle": (0, 0, 40), "error": (255, 0, 0)}


@dataclasses.dataclass(frozen=True)
class Screen:
    kind: str
    ssid: str = ""
    psk: str = ""
    url: str = ""
    ip: str = ""
    failure: Optional[ErrorKind] = None
    detail: str = ""

    @classmethod
    def waiting(cls, ssid, psk):
        return cls("waiting", ssid=ssid, psk=psk)

    @classmethod
    def connecting(cls):
        return cls("connecting")

    @classmethod
    def provisioning(cls):
        return cls("provisioning")

    @classmethod
    def paired(cls, url, ip):
        return cls("paired", url=url, ip=ip)

    @classmethod
    def idle(cls):
        return cls("idle")

    @classmethod
    def error(cls, kind, detail=""):
        return cls("error", failure=ErrorKind(kind), detail=detail)


def wifi_qr_payload(ssid, psk):
    # ADR-0011: neither the SSID nor the PSK alphabet contains \ ; , : " so
    # nothing needs escaping.
    return f"WIFI:T:WPA;S:{ssid};P:{psk};;"


def qr_matrix(payload):
    qr = qrcode.QRCode(error_correction=QR_ERROR_CORRECTION, border=0)
    qr.add_data(payload)
    qr.make(fit=True)
    return qr.get_matrix()


def qr_geometry(n):
    """Top-left of the first module and the module size for an n-module code."""
    m = QR_BOX // (n + 2 * QR_BORDER)
    if m < MIN_MODULE_PX:
        raise ValueError(f"a {n}-module QR does not fit at {MIN_MODULE_PX} px per module")
    return QR_ORIGIN + QR_BORDER * m, QR_ORIGIN + QR_BORDER * m, m


@functools.lru_cache(maxsize=None)
def _font(path, size):
    return ImageFont.truetype(path, size)


def font(size):
    return _font(os.environ.get("ARLOWE_FONT_PATH", DEFAULT_FONT_PATH), size)


def _width(text, f):
    left, _, right, _ = f.getbbox(text)
    return right - left


def wrap(text, f, max_width):
    lines = []
    for word in text.split():
        candidate = f"{lines[-1]} {word}" if lines else word
        if lines and _width(candidate, f) <= max_width:
            lines[-1] = candidate
            continue
        # A URL or hostname has no spaces to break at; split it by character.
        while _width(word, f) > max_width:
            cut = max(i for i in range(1, len(word) + 1) if _width(word[:i], f) <= max_width)
            lines.append(word[:cut])
            word = word[cut:]
        lines.append(word)
    return lines


def _fit(text, max_width, size):
    while size > MIN_SIZE and _width(text, font(size)) > max_width:
        size -= 1
    return font(size)


def lines(screen):
    """The title, then the body lines, before wrapping."""
    if screen.kind == "waiting":
        return ["Scan to connect", f"Wi-Fi  {screen.ssid}", f"Password  {screen.psk}"]
    if screen.kind == "connecting":
        return ["Connecting", "Joining your Wi-Fi network"]
    if screen.kind == "provisioning":
        return ["Setting up", "Registering this Arlowe"]
    if screen.kind == "committing":
        return ["Setting up", "Saving your settings"]
    if screen.kind == "paired":
        return ["Paired", "Open", screen.url, "or", screen.ip] if screen.url else ["Paired"]
    if screen.kind == "idle":
        return ["Arlowe", MESSAGE_IDLE]
    if screen.kind == "error":
        return ["Setup error", MESSAGES[screen.failure], *filter(None, [screen.detail])]
    raise ValueError(f"unknown screen kind {screen.kind!r}")


def _draw_centered(draw, rows, top, bottom, left=PAD, width=TEXT_WIDTH):
    heights = [f.getbbox(t)[3] for t, f, _ in rows]
    y = top + (bottom - top - sum(heights) - LINE_GAP * (len(rows) - 1)) // 2
    for (text, f, colour), h in zip(rows, heights):
        draw.text((left + (width - _width(text, f)) // 2, y), text, font=f, fill=colour)
        y += h + LINE_GAP


def _render_waiting(draw, screen):
    title, *body = lines(screen)
    matrix = qr_matrix(wifi_qr_payload(screen.ssid, screen.psk))
    n = len(matrix)
    x0, y0, m = qr_geometry(n)
    box = (n + 2 * QR_BORDER) * m
    draw.rectangle([QR_ORIGIN, QR_ORIGIN, QR_ORIGIN + box - 1, QR_ORIGIN + box - 1], fill=LIGHT)
    for r, row in enumerate(matrix):
        for c, dark in enumerate(row):
            if dark:
                x, y = x0 + c * m, y0 + r * m
                draw.rectangle([x, y, x + m - 1, y + m - 1], fill=DARK)
    right = QR_ORIGIN + box + LINE_GAP
    col = WIDTH - PAD - right
    f = font(BODY_SIZE)
    _draw_centered(draw, [(t, f, ACCENT) for t in wrap(title, f, col)],
                   QR_ORIGIN, QR_ORIGIN + box, left=right, width=col)
    _draw_centered(draw, [(t, _fit(t, TEXT_WIDTH, BODY_SIZE), FG) for t in body],
                   QR_ORIGIN + box, HEIGHT - PAD // 2)


def _render_text(draw, screen):
    title, *body = lines(screen)
    rows = [(t, font(TITLE_SIZE), ACCENT) for t in wrap(title, font(TITLE_SIZE), TEXT_WIDTH)]
    colour = ALERT if screen.kind == "error" else FG
    for text in body:
        rows += [(t, font(BODY_SIZE), colour) for t in wrap(text, font(BODY_SIZE), TEXT_WIDTH)]
    _draw_centered(draw, rows, PAD, HEIGHT - PAD)


def render(screen):
    img = Image.new("RGB", (WIDTH, HEIGHT), BG)
    draw = ImageDraw.Draw(img)
    (_render_waiting if screen.kind == "waiting" else _render_text)(draw, screen)
    return img


def _load_board():
    path = os.environ.get("ARLOWE_WHISPLAY_DRIVER_PATH", DEFAULT_DRIVER_PATH)
    if path not in sys.path:
        sys.path.insert(0, path)
    from WhisPlay import WhisPlayBoard
    return WhisPlayBoard()


class Display:
    """The Whisplay while pairing owns it. Construction claims every board pin.

    show() also takes pair.flow's contract, a state name or an ErrorKind, and
    fills in the session's ssid/psk and the paired url/ip held here.
    """

    def __init__(self, board=None, ssid="", psk="", url="", ip=""):
        self.board = board if board is not None else _load_board()
        self.ssid, self.psk, self.url, self.ip = ssid, psk, url, ip
        self.board.set_backlight(100)

    def _screen(self, screen):
        if isinstance(screen, Screen):
            return screen
        if isinstance(screen, ErrorKind):
            return Screen.error(screen)
        return Screen(screen, ssid=self.ssid, psk=self.psk, url=self.url, ip=self.ip)

    def show(self, screen):
        screen = self._screen(screen)
        self.board.draw_image(0, 0, DISP_WIDTH, DISP_HEIGHT, list(to_rgb565(render(screen))))
        self.board.set_rgb(*LED[screen.kind])

    def on_button(self, callback):
        self.board.on_button_press(callback)

    def close(self):
        self.board.set_rgb(0, 0, 0)
        self.board.set_backlight(0)
        self.board.cleanup()
