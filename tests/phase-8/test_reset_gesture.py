"""
The Whisplay long-press factory reset (ADR-0013): hold 10 s, release, confirm within 5 s.

Run from repo root (the overlay needs the image's python3-pil and fonts-dejavu-core):
    PYTHONPATH=runtime:runtime/lib python3 -m pytest tests/phase-8/test_reset_gesture.py -q
"""

import importlib
import signal
import subprocess
import sys

import pytest

from face.reset_gesture import ARMED, HOLDING, IDLE, TRIGGERED, ResetGesture

RED = (255, 0, 0)
RESET_ARGV = ["systemctl", "start", "--no-block", "arlowe-factory-reset@button.service"]


def armed_and_released():
    g = ResetGesture()
    g.press(0.0)
    assert g.tick(10.0).led == RED
    g.release(11.0)
    return g


def test_countdown_starts_at_three_seconds_and_arms_at_ten():
    g = ResetGesture()
    g.press(0.0)
    early = g.tick(2.9)
    assert early.countdown is None and early.overlay_text is None and early.led is None
    assert g.tick(3.0).countdown == 7
    last = g.tick(9.99)
    assert last.countdown == 1 and g.state == HOLDING and last.led is None
    armed = g.tick(10.0)
    assert g.state == ARMED and armed.led == RED and not armed.trigger
    assert armed.overlay_text == "Release, then press to confirm"


def test_confirm_inside_the_window_triggers_exactly_once():
    g = armed_and_released()
    assert not g.tick(15.0).trigger
    g.press(15.9)
    assert g.tick(15.9).trigger and g.state == TRIGGERED
    assert not g.tick(16.0).trigger
    g.release(16.1)
    assert not g.tick(16.2).trigger


def test_no_confirm_within_five_seconds_cancels():
    g = armed_and_released()
    intent = g.tick(16.01)
    assert g.state == IDLE and not intent.trigger
    assert intent.overlay_text is None and intent.led is None


def test_a_late_confirm_press_starts_a_new_hold_instead_of_resetting():
    g = armed_and_released()
    g.press(16.5)
    assert not g.tick(16.5).trigger and g.state == HOLDING


def test_releasing_before_ten_seconds_cancels_and_clears_the_overlay():
    g = ResetGesture()
    g.press(0.0)
    assert g.tick(9.0).overlay_text is not None
    g.release(9.5)
    intent = g.tick(9.5)
    assert g.state == IDLE and not intent.trigger
    assert intent.overlay_text is None and intent.countdown is None and intent.led is None
    g.press(10.0)
    assert not g.tick(12.0).trigger


def test_short_press_never_resets():
    g = ResetGesture()
    g.press(0.0)
    g.release(0.2)
    for t in (0.2, 5.0, 10.0, 20.0):
        intent = g.tick(t)
        assert not intent.trigger and intent.overlay_text is None
    assert g.state == IDLE


def test_a_release_that_arrives_after_ten_seconds_without_a_tick_still_arms():
    g = ResetGesture()
    g.press(0.0)
    g.tick(9.0)
    g.release(10.2)
    g.press(12.0)
    assert g.tick(12.0).trigger


def test_presses_after_trigger_do_nothing():
    g = armed_and_released()
    g.press(12.0)
    assert g.tick(12.0).trigger
    for t in (13.0, 30.0):
        g.release(t)
        g.press(t + 0.5)
        intent = g.tick(t + 20)
        assert not intent.trigger and g.state == TRIGGERED
        assert intent.led == RED


@pytest.fixture
def face_mod(tmp_path, monkeypatch):
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
    for name in ("WhisPlay", "face.face"):
        monkeypatch.delitem(sys.modules, name, raising=False)
    saved = {s: signal.getsignal(s) for s in (signal.SIGTERM, signal.SIGINT)}
    try:
        yield importlib.import_module("face.face")
    finally:
        for s, h in saved.items():
            signal.signal(s, h)
        sys.modules.pop("WhisPlay", None)
        if str(tmp_path) in sys.path:
            sys.path.remove(str(tmp_path))


class Clock:
    def __init__(self):
        self.now = 100.0

    def __call__(self):
        return self.now


def recorder(runs):
    def run(argv, **kw):
        runs.append(argv)
        return subprocess.CompletedProcess(argv, 0)
    return run


def callback(board, name):
    (cb,) = [args[0] for n, args in board.calls if n == name]
    return cb


def test_face_hold_release_confirm_starts_the_button_reset_once(face_mod):
    clock, runs = Clock(), []
    face = face_mod.ArloweeFace(clock=clock, run=recorder(runs))
    board = face.board
    press, release = callback(board, "on_button_press"), callback(board, "on_button_release")
    idle_frame = face.render_frame()

    # The GPIO thread passes the channel; the callbacks only enqueue.
    press(11)
    for t in (100.0, 102.0, 104.0):
        clock.now = t
        face.poll_button()
    assert face.render_frame() != idle_frame
    clock.now = 110.0
    face.poll_button()
    assert board.calls[-1] == ("set_rgb", RED)
    clock.now = 111.0
    release(11)
    face.poll_button()
    clock.now = 113.0
    press(11)
    assert runs == []
    face.poll_button()
    clock.now = 114.0
    release(11)
    press(11)
    face.poll_button()
    assert runs == [RESET_ARGV]


def test_face_cancel_restores_the_state_colour_and_frame(face_mod):
    clock, runs = Clock(), []
    face = face_mod.ArloweeFace(clock=clock, run=recorder(runs))
    face.set_state(face_mod.State.HAPPY)
    board = face.board
    press, release = callback(board, "on_button_press"), callback(board, "on_button_release")

    press(11)
    clock.now = 110.0
    face.poll_button()
    face.set_state(face_mod.State.THINKING)
    assert board.calls[-1] == ("set_rgb", RED)
    release(11)
    clock.now = 116.0
    face.poll_button()
    assert board.calls[-1] == ("set_rgb", (150, 100, 255))
    assert face.overlay_text is None and runs == []
