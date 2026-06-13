"""
Unit tests for arlowe_audio selfcheck sentinel logic.

All tests use injected capture_runner/playback_runner fakes — no real
arecord, aplay, or sox invoked.  No real hardware required.

Run from repo root:
    PYTHONPATH=runtime/lib python3 -m pytest runtime/lib/tests/test_arlowe_audio_selfcheck.py -q

Or from runtime/lib/:
    python3 -m pytest tests/test_arlowe_audio_selfcheck.py -q
"""

import json
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import arlowe_audio

FIXTURES = Path(__file__).parent / "fixtures" / "proc_asound"
USB_PLUS_WM8960 = str(FIXTURES / "usb_plus_wm8960")


# ---------------------------------------------------------------------------
# Helpers: fake runners
# ---------------------------------------------------------------------------

def _make_silent_pcm(n_samples: int = 8000) -> bytes:
    """Return all-zero S16_LE PCM bytes (silent)."""
    return struct.pack(f"<{n_samples}h", *([0] * n_samples))


def _make_nonsilent_pcm(n_samples: int = 8000, amplitude: int = 2000) -> bytes:
    """Return S16_LE PCM bytes with a detectable RMS well above the floor."""
    import math
    samples = [int(amplitude * math.sin(2 * math.pi * 440 * i / 16000)) for i in range(n_samples)]
    return struct.pack(f"<{n_samples}h", *samples)


def _capture_ok(device: str) -> bytes:
    return _make_nonsilent_pcm()


def _capture_silent(device: str) -> bytes:
    return _make_silent_pcm()


def _capture_raises(device: str) -> bytes:
    raise RuntimeError("arecord: no such device")


def _playback_ok(device: str) -> None:
    return None


def _playback_raises(device: str) -> None:
    raise RuntimeError("aplay: device busy")


# ---------------------------------------------------------------------------
# Tests: basic happy path
# ---------------------------------------------------------------------------

class TestSelfcheckBothOk:
    def test_returns_dict_with_check_audio(self):
        status = arlowe_audio.selfcheck(
            state_dir=None,
            retries=1,
            capture_runner=_capture_ok,
            playback_runner=_playback_ok,
            proc_root=USB_PLUS_WM8960,
        )
        assert status["check"] == "audio"

    def test_capture_ok_true(self):
        status = arlowe_audio.selfcheck(
            state_dir=None,
            retries=1,
            capture_runner=_capture_ok,
            playback_runner=_playback_ok,
            proc_root=USB_PLUS_WM8960,
        )
        assert status["capture"]["ok"] is True

    def test_playback_ok_true(self):
        status = arlowe_audio.selfcheck(
            state_dir=None,
            retries=1,
            capture_runner=_capture_ok,
            playback_runner=_playback_ok,
            proc_root=USB_PLUS_WM8960,
        )
        assert status["playback"]["ok"] is True

    def test_ts_is_iso8601(self):
        status = arlowe_audio.selfcheck(
            state_dir=None,
            retries=1,
            capture_runner=_capture_ok,
            playback_runner=_playback_ok,
            proc_root=USB_PLUS_WM8960,
        )
        ts = status["ts"]
        assert "T" in ts
        assert ts.endswith("Z")

    def test_capture_device_is_resolved(self):
        status = arlowe_audio.selfcheck(
            state_dir=None,
            retries=1,
            capture_runner=_capture_ok,
            playback_runner=_playback_ok,
            proc_root=USB_PLUS_WM8960,
        )
        # USB_PLUS_WM8960 fixture has USB at index 1 -> plughw:1,0
        assert status["capture"]["device"] == "plughw:1,0"

    def test_playback_device_is_resolved(self):
        status = arlowe_audio.selfcheck(
            state_dir=None,
            retries=1,
            capture_runner=_capture_ok,
            playback_runner=_playback_ok,
            proc_root=USB_PLUS_WM8960,
        )
        assert status["playback"]["device"] == "plughw:1,0"


# ---------------------------------------------------------------------------
# Tests: capture failure path
# ---------------------------------------------------------------------------

class TestSelfcheckCaptureSilent:
    def test_capture_ok_false_on_silent_buffer(self):
        status = arlowe_audio.selfcheck(
            state_dir=None,
            retries=1,
            capture_runner=_capture_silent,
            playback_runner=_playback_ok,
            proc_root=USB_PLUS_WM8960,
        )
        assert status["capture"]["ok"] is False

    def test_capture_error_mentions_rms(self):
        status = arlowe_audio.selfcheck(
            state_dir=None,
            retries=1,
            capture_runner=_capture_silent,
            playback_runner=_playback_ok,
            proc_root=USB_PLUS_WM8960,
        )
        assert "RMS" in status["capture"].get("error", "")

    def test_playback_still_ok_when_capture_silent(self):
        status = arlowe_audio.selfcheck(
            state_dir=None,
            retries=1,
            capture_runner=_capture_silent,
            playback_runner=_playback_ok,
            proc_root=USB_PLUS_WM8960,
        )
        assert status["playback"]["ok"] is True


class TestSelfcheckCaptureRaises:
    def test_capture_ok_false_on_exception(self):
        status = arlowe_audio.selfcheck(
            state_dir=None,
            retries=1,
            capture_runner=_capture_raises,
            playback_runner=_playback_ok,
            proc_root=USB_PLUS_WM8960,
        )
        assert status["capture"]["ok"] is False

    def test_capture_error_populated(self):
        status = arlowe_audio.selfcheck(
            state_dir=None,
            retries=1,
            capture_runner=_capture_raises,
            playback_runner=_playback_ok,
            proc_root=USB_PLUS_WM8960,
        )
        assert status["capture"].get("error") is not None


# ---------------------------------------------------------------------------
# Tests: playback failure path
# ---------------------------------------------------------------------------

class TestSelfcheckPlaybackRaises:
    def test_playback_ok_false_on_exception(self):
        status = arlowe_audio.selfcheck(
            state_dir=None,
            retries=1,
            capture_runner=_capture_ok,
            playback_runner=_playback_raises,
            proc_root=USB_PLUS_WM8960,
        )
        assert status["playback"]["ok"] is False

    def test_playback_error_populated(self):
        status = arlowe_audio.selfcheck(
            state_dir=None,
            retries=1,
            capture_runner=_capture_ok,
            playback_runner=_playback_raises,
            proc_root=USB_PLUS_WM8960,
        )
        assert status["playback"].get("error") is not None

    def test_capture_still_ok_when_playback_fails(self):
        status = arlowe_audio.selfcheck(
            state_dir=None,
            retries=1,
            capture_runner=_capture_ok,
            playback_runner=_playback_raises,
            proc_root=USB_PLUS_WM8960,
        )
        assert status["capture"]["ok"] is True


# ---------------------------------------------------------------------------
# Tests: retry behavior
# ---------------------------------------------------------------------------

class TestSelfcheckRetry:
    def test_capture_retried_n_times_before_failure(self):
        call_count = []

        def counting_silent(device):
            call_count.append(1)
            return _make_silent_pcm()

        arlowe_audio.selfcheck(
            state_dir=None,
            retries=3,
            capture_runner=counting_silent,
            playback_runner=_playback_ok,
            proc_root=USB_PLUS_WM8960,
        )
        assert len(call_count) == 3

    def test_playback_retried_n_times_before_failure(self):
        call_count = []

        def counting_raises(device):
            call_count.append(1)
            raise RuntimeError("busy")

        arlowe_audio.selfcheck(
            state_dir=None,
            retries=3,
            capture_runner=_capture_ok,
            playback_runner=counting_raises,
            proc_root=USB_PLUS_WM8960,
        )
        assert len(call_count) == 3

    def test_capture_succeeds_on_second_attempt(self):
        attempts = []

        def flaky_capture(device):
            attempts.append(1)
            if len(attempts) == 1:
                return _make_silent_pcm()
            return _make_nonsilent_pcm()

        status = arlowe_audio.selfcheck(
            state_dir=None,
            retries=3,
            capture_runner=flaky_capture,
            playback_runner=_playback_ok,
            proc_root=USB_PLUS_WM8960,
        )
        assert status["capture"]["ok"] is True
        assert len(attempts) == 2

    def test_playback_succeeds_on_second_attempt(self):
        attempts = []

        def flaky_playback(device):
            attempts.append(1)
            if len(attempts) == 1:
                raise RuntimeError("busy")

        status = arlowe_audio.selfcheck(
            state_dir=None,
            retries=3,
            capture_runner=_capture_ok,
            playback_runner=flaky_playback,
            proc_root=USB_PLUS_WM8960,
        )
        assert status["playback"]["ok"] is True
        assert len(attempts) == 2


# ---------------------------------------------------------------------------
# Tests: JSON status file persistence
# ---------------------------------------------------------------------------

class TestSelfcheckPersistence:
    def test_json_written_to_state_dir(self, tmp_path):
        arlowe_audio.selfcheck(
            state_dir=str(tmp_path),
            retries=1,
            capture_runner=_capture_ok,
            playback_runner=_playback_ok,
            proc_root=USB_PLUS_WM8960,
        )
        target = tmp_path / "audio-selfcheck.json"
        assert target.exists()

    def test_json_has_required_keys(self, tmp_path):
        arlowe_audio.selfcheck(
            state_dir=str(tmp_path),
            retries=1,
            capture_runner=_capture_ok,
            playback_runner=_playback_ok,
            proc_root=USB_PLUS_WM8960,
        )
        data = json.loads((tmp_path / "audio-selfcheck.json").read_text())
        assert data["check"] == "audio"
        assert "capture" in data
        assert "playback" in data
        assert "ts" in data

    def test_json_capture_has_device_and_ok(self, tmp_path):
        arlowe_audio.selfcheck(
            state_dir=str(tmp_path),
            retries=1,
            capture_runner=_capture_ok,
            playback_runner=_playback_ok,
            proc_root=USB_PLUS_WM8960,
        )
        data = json.loads((tmp_path / "audio-selfcheck.json").read_text())
        assert "device" in data["capture"]
        assert "ok" in data["capture"]

    def test_json_playback_has_device_and_ok(self, tmp_path):
        arlowe_audio.selfcheck(
            state_dir=str(tmp_path),
            retries=1,
            capture_runner=_capture_ok,
            playback_runner=_playback_ok,
            proc_root=USB_PLUS_WM8960,
        )
        data = json.loads((tmp_path / "audio-selfcheck.json").read_text())
        assert "device" in data["playback"]
        assert "ok" in data["playback"]

    def test_json_overwritten_on_second_run(self, tmp_path):
        arlowe_audio.selfcheck(
            state_dir=str(tmp_path),
            retries=1,
            capture_runner=_capture_ok,
            playback_runner=_playback_ok,
            proc_root=USB_PLUS_WM8960,
        )
        first_mtime = (tmp_path / "audio-selfcheck.json").stat().st_mtime

        import time
        time.sleep(0.01)

        arlowe_audio.selfcheck(
            state_dir=str(tmp_path),
            retries=1,
            capture_runner=_capture_ok,
            playback_runner=_playback_ok,
            proc_root=USB_PLUS_WM8960,
        )
        second_mtime = (tmp_path / "audio-selfcheck.json").stat().st_mtime
        assert second_mtime >= first_mtime

    def test_state_dir_none_does_not_crash(self):
        status = arlowe_audio.selfcheck(
            state_dir=None,
            retries=1,
            capture_runner=_capture_ok,
            playback_runner=_playback_ok,
            proc_root=USB_PLUS_WM8960,
        )
        assert status["check"] == "audio"

    def test_unwritable_state_dir_does_not_crash(self, tmp_path):
        bad_dir = tmp_path / "no_access"
        bad_dir.mkdir()
        bad_dir.chmod(0o000)
        try:
            status = arlowe_audio.selfcheck(
                state_dir=str(bad_dir),
                retries=1,
                capture_runner=_capture_ok,
                playback_runner=_playback_ok,
                proc_root=USB_PLUS_WM8960,
            )
            assert status["check"] == "audio"
        finally:
            bad_dir.chmod(0o755)


# ---------------------------------------------------------------------------
# Tests: no devices — graceful degraded path
# ---------------------------------------------------------------------------

class TestSelfcheckNoDevices:
    def test_no_capture_device_reports_fail(self, tmp_path):
        """When proc_root has no capture devices, capture ok=False, no crash."""
        no_capture_root = str(FIXTURES / "no_capture")
        status = arlowe_audio.selfcheck(
            state_dir=None,
            retries=1,
            capture_runner=_capture_ok,
            playback_runner=_playback_ok,
            proc_root=no_capture_root,
        )
        assert status["capture"]["ok"] is False
        assert status["capture"]["device"] is None

    def test_no_capture_device_error_populated(self, tmp_path):
        no_capture_root = str(FIXTURES / "no_capture")
        status = arlowe_audio.selfcheck(
            state_dir=None,
            retries=1,
            capture_runner=_capture_ok,
            playback_runner=_playback_ok,
            proc_root=no_capture_root,
        )
        assert "no capture device" in status["capture"].get("error", "")


# ---------------------------------------------------------------------------
# Tests: internal helpers
# ---------------------------------------------------------------------------

class TestRmsFromPcm:
    def test_silent_pcm_returns_zero(self):
        rms = arlowe_audio._rms_from_pcm(_make_silent_pcm())
        assert rms == 0.0

    def test_nonsilent_pcm_returns_above_floor(self):
        rms = arlowe_audio._rms_from_pcm(_make_nonsilent_pcm(amplitude=2000))
        assert rms >= arlowe_audio._CAPTURE_RMS_FLOOR

    def test_empty_bytes_returns_zero(self):
        rms = arlowe_audio._rms_from_pcm(b"")
        assert rms == 0.0

    def test_wav_header_is_stripped(self):
        # Construct minimal WAV: 'data' marker + 4-byte size + PCM.
        pcm = _make_nonsilent_pcm(amplitude=2000)
        import struct as st
        wav = b"RIFF\x00\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00"
        wav += st.pack("<I", 16000) + st.pack("<I", 32000)
        wav += b"\x02\x00\x10\x00data"
        wav += st.pack("<I", len(pcm)) + pcm
        rms = arlowe_audio._rms_from_pcm(wav)
        assert rms >= arlowe_audio._CAPTURE_RMS_FLOOR


class TestStripWavHeader:
    def test_no_header_returns_original(self):
        pcm = b"\x01\x00\x02\x00"
        result = arlowe_audio._strip_wav_header(pcm)
        assert result == pcm

    def test_data_marker_is_stripped(self):
        import struct as st
        pcm = b"\x01\x00\x02\x00"
        # Prefix must not contain the literal b"data" to avoid confusing find().
        wav = b"RIFF\x00\x00\x00\x00WAVEfmt " + b"data" + st.pack("<I", len(pcm)) + pcm
        result = arlowe_audio._strip_wav_header(wav)
        assert result == pcm


# ---------------------------------------------------------------------------
# Tests: journal line format
# ---------------------------------------------------------------------------

class TestJournalLine:
    def test_journal_line_emitted_to_stderr(self, capsys):
        arlowe_audio.selfcheck(
            state_dir=None,
            retries=1,
            capture_runner=_capture_ok,
            playback_runner=_playback_ok,
            proc_root=USB_PLUS_WM8960,
        )
        captured = capsys.readouterr()
        assert "[arlowe-audio]" in captured.err

    def test_journal_line_contains_selfcheck(self, capsys):
        arlowe_audio.selfcheck(
            state_dir=None,
            retries=1,
            capture_runner=_capture_ok,
            playback_runner=_playback_ok,
            proc_root=USB_PLUS_WM8960,
        )
        captured = capsys.readouterr()
        assert "selfcheck" in captured.err

    def test_journal_line_contains_capture_status(self, capsys):
        arlowe_audio.selfcheck(
            state_dir=None,
            retries=1,
            capture_runner=_capture_ok,
            playback_runner=_playback_ok,
            proc_root=USB_PLUS_WM8960,
        )
        captured = capsys.readouterr()
        assert "capture=ok" in captured.err

    def test_journal_line_contains_fail_on_silent(self, capsys):
        arlowe_audio.selfcheck(
            state_dir=None,
            retries=1,
            capture_runner=_capture_silent,
            playback_runner=_playback_ok,
            proc_root=USB_PLUS_WM8960,
        )
        captured = capsys.readouterr()
        assert "capture=FAIL" in captured.err

    def test_journal_line_contains_playback_status(self, capsys):
        arlowe_audio.selfcheck(
            state_dir=None,
            retries=1,
            capture_runner=_capture_ok,
            playback_runner=_playback_ok,
            proc_root=USB_PLUS_WM8960,
        )
        captured = capsys.readouterr()
        assert "playback=ok" in captured.err
