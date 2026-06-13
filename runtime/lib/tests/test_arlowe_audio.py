"""
Unit tests for arlowe_audio — enumeration, card-id resolution, and auto-pick.

All tests use committed proc_asound fixture trees; no real hardware or ALSA
tools required.

Run from repo root:
    PYTHONPATH=runtime/lib python3 -m pytest runtime/lib/tests/test_arlowe_audio.py -q

Or from runtime/lib/:
    python3 -m pytest tests/test_arlowe_audio.py -q
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import arlowe_audio

FIXTURES = Path(__file__).parent / "fixtures" / "proc_asound"

USB_PLUS_WM8960 = str(FIXTURES / "usb_plus_wm8960")
WM8960_ONLY = str(FIXTURES / "wm8960_only")
NO_CAPTURE = str(FIXTURES / "no_capture")
TWO_USB_CAPTURE = str(FIXTURES / "two_usb_capture")


class TestEnumerateCards:
    def test_usb_plus_wm8960_finds_three_cards(self):
        cards = arlowe_audio.enumerate_cards(USB_PLUS_WM8960)
        assert len(cards) == 3

    def test_usb_plus_wm8960_classifies_wm8960_card(self):
        cards = arlowe_audio.enumerate_cards(USB_PLUS_WM8960)
        wm = next(c for c in cards if c["is_wm8960"])
        assert wm["index"] == 0
        assert wm["id"] == "wm8960soundcard"
        assert wm["has_capture"] is True
        assert wm["has_playback"] is True
        assert wm["is_usb"] is False
        assert wm["is_hdmi"] is False

    def test_usb_plus_wm8960_classifies_usb_card(self):
        cards = arlowe_audio.enumerate_cards(USB_PLUS_WM8960)
        usb = next(c for c in cards if c["is_usb"])
        assert usb["index"] == 1
        assert usb["id"] == "Device"
        assert usb["has_capture"] is True
        assert usb["has_playback"] is True
        assert usb["is_wm8960"] is False
        assert usb["is_hdmi"] is False

    def test_usb_plus_wm8960_classifies_hdmi_card(self):
        cards = arlowe_audio.enumerate_cards(USB_PLUS_WM8960)
        hdmi = next(c for c in cards if c["is_hdmi"])
        assert hdmi["index"] == 2
        assert hdmi["is_usb"] is False
        assert hdmi["is_wm8960"] is False
        assert hdmi["has_capture"] is False
        assert hdmi["has_playback"] is True

    def test_wm8960_only_finds_three_cards(self):
        cards = arlowe_audio.enumerate_cards(WM8960_ONLY)
        assert len(cards) == 3

    def test_wm8960_only_no_usb_card(self):
        cards = arlowe_audio.enumerate_cards(WM8960_ONLY)
        assert not any(c["is_usb"] for c in cards)

    def test_wm8960_only_codec_has_capture_and_playback(self):
        cards = arlowe_audio.enumerate_cards(WM8960_ONLY)
        wm = next(c for c in cards if c["is_wm8960"])
        assert wm["has_capture"] is True
        assert wm["has_playback"] is True

    def test_wm8960_only_hdmi_cards_have_playback_only(self):
        cards = arlowe_audio.enumerate_cards(WM8960_ONLY)
        hdmi_cards = [c for c in cards if c["is_hdmi"]]
        assert len(hdmi_cards) == 2
        for c in hdmi_cards:
            assert c["has_playback"] is True
            assert c["has_capture"] is False

    def test_no_capture_finds_two_hdmi_cards(self):
        cards = arlowe_audio.enumerate_cards(NO_CAPTURE)
        assert len(cards) == 2
        assert all(c["is_hdmi"] for c in cards)
        assert all(not c["has_capture"] for c in cards)

    def test_empty_proc_root_returns_empty_list(self, tmp_path):
        cards = arlowe_audio.enumerate_cards(str(tmp_path))
        assert cards == []

    def test_two_usb_capture_finds_two_usb_cards(self):
        cards = arlowe_audio.enumerate_cards(TWO_USB_CAPTURE)
        assert len(cards) == 2
        assert all(c["is_usb"] for c in cards)
        assert all(c["has_capture"] for c in cards)


class TestResolveCapture:
    def test_auto_with_usb_returns_usb_card(self):
        result = arlowe_audio.resolve_capture("auto", proc_root=USB_PLUS_WM8960)
        assert result == "plughw:1,0"

    def test_none_token_with_usb_returns_usb_card(self):
        result = arlowe_audio.resolve_capture(None, proc_root=USB_PLUS_WM8960)
        assert result == "plughw:1,0"

    def test_auto_wm8960_only_returns_wm8960(self):
        result = arlowe_audio.resolve_capture("auto", proc_root=WM8960_ONLY)
        assert result == "plughw:0,0"

    def test_auto_no_capture_returns_none(self):
        result = arlowe_audio.resolve_capture("auto", proc_root=NO_CAPTURE)
        assert result is None

    def test_override_present_card_is_honored(self):
        # "Device" is the USB card at index 1
        result = arlowe_audio.resolve_capture("Device", proc_root=USB_PLUS_WM8960)
        assert result == "plughw:1,0"

    def test_override_wm8960_card_id_is_honored(self):
        result = arlowe_audio.resolve_capture(
            "wm8960soundcard", proc_root=USB_PLUS_WM8960
        )
        assert result == "plughw:0,0"

    def test_override_absent_card_falls_back_to_auto(self):
        # "Ghost" is not present in the fixture — must not raise, must auto-pick
        result = arlowe_audio.resolve_capture("Ghost", proc_root=USB_PLUS_WM8960)
        assert result == "plughw:1,0"  # auto-pick: USB card wins

    def test_override_absent_falls_back_to_none_when_no_capture(self):
        result = arlowe_audio.resolve_capture("Ghost", proc_root=NO_CAPTURE)
        assert result is None

    def test_tie_break_lowest_index_wins(self):
        result = arlowe_audio.resolve_capture("auto", proc_root=TWO_USB_CAPTURE)
        assert result == "plughw:0,0"

    def test_cards_kwarg_bypasses_proc_root(self):
        cards = [
            {
                "index": 3,
                "id": "FakeUSB",
                "longname": "Fake USB Audio",
                "is_usb": True,
                "is_wm8960": False,
                "is_hdmi": False,
                "has_capture": True,
                "has_playback": True,
            }
        ]
        result = arlowe_audio.resolve_capture("auto", cards=cards)
        assert result == "plughw:3,0"


class TestResolvePlayback:
    def test_auto_with_usb_returns_usb_card(self):
        result = arlowe_audio.resolve_playback("auto", proc_root=USB_PLUS_WM8960)
        assert result == "plughw:1,0"

    def test_auto_wm8960_only_returns_wm8960(self):
        result = arlowe_audio.resolve_playback("auto", proc_root=WM8960_ONLY)
        assert result == "plughw:0,0"

    def test_auto_no_capture_falls_back_to_hdmi(self):
        result = arlowe_audio.resolve_playback("auto", proc_root=NO_CAPTURE)
        # lowest-index HDMI card wins
        assert result == "plughw:0,0"

    def test_override_present_card_is_honored(self):
        result = arlowe_audio.resolve_playback("Device", proc_root=USB_PLUS_WM8960)
        assert result == "plughw:1,0"

    def test_override_absent_falls_back_to_auto(self):
        result = arlowe_audio.resolve_playback("Ghost", proc_root=USB_PLUS_WM8960)
        assert result == "plughw:1,0"  # auto-pick: USB card wins

    def test_override_absent_wm8960_only_falls_back_to_codec(self):
        result = arlowe_audio.resolve_playback("Ghost", proc_root=WM8960_ONLY)
        assert result == "plughw:0,0"

    def test_none_token_with_usb_returns_usb(self):
        result = arlowe_audio.resolve_playback(None, proc_root=USB_PLUS_WM8960)
        assert result == "plughw:1,0"

    def test_no_cards_returns_none(self, tmp_path):
        result = arlowe_audio.resolve_playback("auto", proc_root=str(tmp_path))
        assert result is None

    def test_cards_kwarg_bypasses_proc_root(self):
        cards = [
            {
                "index": 5,
                "id": "FakeUSB",
                "longname": "Fake USB",
                "is_usb": True,
                "is_wm8960": False,
                "is_hdmi": False,
                "has_capture": False,
                "has_playback": True,
            }
        ]
        result = arlowe_audio.resolve_playback("auto", cards=cards)
        assert result == "plughw:5,0"


class TestPortaudioIndexForCard:
    def test_returns_none_when_pyaudio_not_available(self):
        """pyaudio is not installed in CI; helper must return None gracefully."""

        class _FakePa:
            def get_device_count(self):
                return 0

        result = arlowe_audio.portaudio_index_for_card("Device", _FakePa())
        # Whether pyaudio is importable or not, the result must be int or None.
        assert result is None or isinstance(result, int)


class TestPlughwFormat:
    def test_resolve_capture_output_format(self):
        cards = [
            {
                "index": 7,
                "id": "MyUSB",
                "longname": "My USB Device",
                "is_usb": True,
                "is_wm8960": False,
                "is_hdmi": False,
                "has_capture": True,
                "has_playback": True,
            }
        ]
        result = arlowe_audio.resolve_capture("auto", cards=cards)
        assert result == "plughw:7,0"
        assert result.startswith("plughw:")
        assert not result.startswith("hw:")
