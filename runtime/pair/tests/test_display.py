"""
Whisplay pairing screens, the setup QR and the shared RGB565 conversion.

Run from repo root (needs the image's python3-pil, python3-qrcode, fonts-dejavu-core):
    PYTHONPATH=runtime:runtime/lib python3 -m pytest runtime/pair/tests/test_display.py -q
"""

import hashlib
import importlib
import signal
import sys

import PIL
import pytest
from PIL import Image, ImageDraw

from pair.errors import MESSAGES, ErrorKind

SSID, PSK = "Arlowe-Setup-3f9a", "ABCDEFGH2345"

# sha256 of face.render_frame() for a fresh idle ArloweeFace, captured from the
# pre-refactor inline conversion loop under bookworm's Pillow. Drawing output is
# only stable within one Pillow release, so other versions skip rather than lie.
FACE_GOLDEN_PILLOW = "9.4.0"
FACE_GOLDEN_SHA256 = "519bd87eaef3d55f54867f6ff589da771b9efe3abbfa42ad736017cbb5e4976c"


class FakeBoard:
    def __init__(self):
        self.calls = []

    def __getattr__(self, name):
        return lambda *args: self.calls.append((name, args))

    def named(self, name):
        return [args for n, args in self.calls if n == name]


@pytest.fixture
def fake_driver(tmp_path, monkeypatch):
    (tmp_path / "WhisPlay.py").write_text(
        "class WhisPlayBoard:\n"
        "    instances = []\n"
        "    def __init__(self):\n"
        "        self.calls = []\n"
        "        WhisPlayBoard.instances.append(self)\n"
        "    def __getattr__(self, name):\n"
        "        return lambda *a: self.calls.append((name, a))\n"
    )
    monkeypatch.setenv("ARLOWE_WHISPLAY_DRIVER_PATH", str(tmp_path))
    monkeypatch.delitem(sys.modules, "WhisPlay", raising=False)
    yield tmp_path
    sys.modules.pop("WhisPlay", None)
    if str(tmp_path) in sys.path:
        sys.path.remove(str(tmp_path))


@pytest.fixture
def display():
    return importlib.import_module("pair.display")


def test_wifi_qr_payload(display):
    assert display.wifi_qr_payload(SSID, PSK) == "WIFI:T:WPA;S:Arlowe-Setup-3f9a;P:ABCDEFGH2345;;"


def test_waiting_screen_carries_the_scannable_qr(display):
    import qrcode

    img = display.render(display.Screen.waiting(SSID, PSK))
    assert img.size == (280, 240) and img.mode == "RGB"

    matrix = display.qr_matrix(display.wifi_qr_payload(SSID, PSK))
    qr = qrcode.QRCode(error_correction=display.QR_ERROR_CORRECTION, border=0)
    qr.add_data(display.wifi_qr_payload(SSID, PSK))
    qr.make(fit=True)
    assert matrix == qr.get_matrix()

    n = len(matrix)
    x0, y0, m = display.qr_geometry(n)
    assert m >= 4
    b = display.QR_BORDER * m
    assert x0 - b >= 0 and y0 - b >= 0
    assert x0 + n * m + b <= 280 and y0 + n * m + b <= 240
    dark, light = (0, 0, 0), (255, 255, 255)
    for r in range(n):
        for c in range(n):
            px = img.getpixel((x0 + c * m + m // 2, y0 + r * m + m // 2))
            assert px == (dark if matrix[r][c] else light), (r, c)
    for i in range(-display.QR_BORDER, n + display.QR_BORDER):
        for r, c in ((-display.QR_BORDER, i), (n + display.QR_BORDER - 1, i),
                     (i, -display.QR_BORDER), (i, n + display.QR_BORDER - 1)):
            assert img.getpixel((x0 + c * m + m // 2, y0 + r * m + m // 2)) == light


def test_waiting_screen_shows_ssid_and_password_as_text(display):
    lines = display.lines(display.Screen.waiting(SSID, PSK))
    assert any(SSID in line for line in lines)
    assert any(PSK in line for line in lines)

    a = display.render(display.Screen.waiting(SSID, PSK))
    b = display.render(display.Screen.waiting(SSID, "ZZZZZZZZZZZZ"))
    n = len(display.qr_matrix(display.wifi_qr_payload(SSID, PSK)))
    x0, y0, m = display.qr_geometry(n)
    below_qr = (0, y0 + (n + display.QR_BORDER) * m, 280, 240)
    assert a.crop(below_qr).tobytes() != b.crop(below_qr).tobytes()


@pytest.mark.parametrize("make", [
    lambda S: S.connecting(),
    lambda S: S.provisioning(),
    lambda S: S.paired("http://arlowe.local", "192.168.1.42"),
    lambda S: S.idle(),
] + [(lambda k: lambda S: S.error(k))(k) for k in ErrorKind])
def test_every_screen_renders_to_the_canvas(display, make):
    img = display.render(make(display.Screen))
    assert img.size == (280, 240) and img.mode == "RGB"


def test_error_screen_renders_the_shared_string(display):
    assert display.Screen.waiting(SSID, PSK).failure is None
    for kind in ErrorKind:
        assert MESSAGES[kind] in " ".join(display.lines(display.Screen.error(kind)))


def test_paired_screen_shows_url_and_ip(display):
    lines = display.lines(display.Screen.paired("http://arlowe.local", "192.168.1.42"))
    assert any("http://arlowe.local" in line for line in lines)
    assert any("192.168.1.42" in line for line in lines)


def test_idle_screen_says_press_to_start(display):
    assert "Press the button to start setup" in " ".join(display.lines(display.Screen.idle()))


def test_longest_message_wraps_within_the_width(display):
    longest = max(MESSAGES.values(), key=len)
    font = display.font(display.BODY_SIZE)
    wrapped = display.wrap(longest, font, display.TEXT_WIDTH)
    assert len(wrapped) >= 1 and " ".join(wrapped) == longest
    draw = ImageDraw.Draw(Image.new("RGB", (280, 240)))
    for line in wrapped:
        left, _, right, _ = draw.textbbox((0, 0), line, font=font)
        assert right - left <= display.TEXT_WIDTH
    assert display.TEXT_WIDTH <= 280


def test_to_rgb565_packs_red_at_its_rotated_position():
    from arlowe_display import DISP_HEIGHT, DISP_WIDTH, to_rgb565

    assert (DISP_WIDTH, DISP_HEIGHT) == (240, 280)
    img = Image.new("RGB", (280, 240), (0, 0, 0))
    x, y = 10, 3
    img.putpixel((x, y), (255, 0, 0))
    data = to_rgb565(img)
    assert len(data) == 240 * 280 * 2
    # rotate(90) is counter-clockwise: canvas (x, y) lands at (y, 279 - x).
    off = ((279 - x) * 240 + y) * 2
    assert data[off:off + 2] == b"\xf8\x00"
    assert data.count(0) == len(data) - 1


def test_to_rgb565_matches_the_reference_packing():
    from arlowe_display import to_rgb565

    img = Image.new("RGB", (280, 240))
    img.putdata([((i * 7) & 255, (i * 13) & 255, (i * 29) & 255) for i in range(280 * 240)])
    rot = img.rotate(90, expand=True)
    ref = bytearray()
    for yy in range(280):
        for xx in range(240):
            r, g, b = rot.getpixel((xx, yy))
            v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
            ref += bytes([v >> 8, v & 0xFF])
    assert to_rgb565(img) == bytes(ref)


@pytest.mark.skipif(PIL.__version__ != FACE_GOLDEN_PILLOW,
                    reason=f"golden captured under Pillow {FACE_GOLDEN_PILLOW}")
def test_face_render_frame_is_unchanged(fake_driver):
    saved = {s: signal.getsignal(s) for s in (signal.SIGTERM, signal.SIGINT)}
    try:
        face_mod = importlib.import_module("face.face")
        face = face_mod.ArloweeFace()
    finally:
        for s, h in saved.items():
            signal.signal(s, h)
    assert hashlib.sha256(face.render_frame()).hexdigest() == FACE_GOLDEN_SHA256


@pytest.mark.parametrize("make,led", [
    (lambda S: S.waiting(SSID, PSK), "blue"),
    (lambda S: S.error(ErrorKind.wifi_rejected), "red"),
    (lambda S: S.paired("http://arlowe.local", "192.168.1.42"), "green"),
])
def test_show_draws_once_and_sets_the_led(display, make, led):
    board = FakeBoard()
    d = display.Display(board=board)
    d.show(make(display.Screen))
    draws = board.named("draw_image")
    assert len(draws) == 1
    x, y, w, h, pixels = draws[0]
    assert (x, y, w, h) == (0, 0, 240, 280) and len(pixels) == 240 * 280 * 2
    r, g, b = board.named("set_rgb")[-1]
    colour = {"blue": b, "red": r, "green": g}[led]
    assert colour > 0 and colour == max(r, g, b) and sorted((r, g, b))[1] == 0


def test_display_loads_the_driver_lazily_and_releases_it(display, fake_driver):
    d = display.Display()
    import WhisPlay
    board = WhisPlay.WhisPlayBoard.instances[-1]
    pressed = []
    d.on_button(lambda *a: pressed.append(a))
    (callback,) = [a[0] for n, a in board.calls if n == "on_button_press"]
    callback()
    assert pressed
    d.close()
    names = [n for n, _ in board.calls]
    assert names[-1] == "cleanup"
    assert ("set_backlight", (0,)) in board.calls and ("set_rgb", (0, 0, 0)) in board.calls


def test_show_takes_the_flow_contract(display):
    from pair.flow import State

    board = FakeBoard()
    d = display.Display(board=board, ssid=SSID, psk=PSK)
    for screen in [*(s.value for s in State if s is not State.ERROR), *ErrorKind]:
        d.show(screen)
    assert len(board.named("draw_image")) == len(State) - 1 + len(ErrorKind)
    shown = display.render(display.Screen.waiting(SSID, PSK))
    d.show("waiting")
    assert board.named("draw_image")[-1][4] == list(display.to_rgb565(shown))
