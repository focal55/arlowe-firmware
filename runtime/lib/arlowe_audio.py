"""
ALSA audio device enumeration and selection for Arlowe.

Parses /proc/asound to enumerate cards, resolves a stored card-id override
token or auto-picks a device using the locked fallback orders:
  - Capture:  USB -> wm8960 codec -> None
  - Playback: USB -> wm8960 codec -> HDMI -> None

Card identity is the stable ALSA card-id string (from /proc/asound/card<N>/id),
NOT a bare plughw:N index (indices shuffle across reboots/re-plugs).

Device strings use plughw (not hw) so ALSA can resample/convert format as
needed — mirrors the old plughw:2,0 behavior and avoids gating selection on
native 16 kHz S16_LE support.

The Pi 5 has no onboard 3.5mm analog jack. "3.5mm fallback" in AUDIO-02/SC2
means the Whisplay WM8960 codec on this hardware; HDMI is the true last resort.

This module is pure read + compute — no service restarts, no config writes.
"""

import argparse
import glob
import json
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

WM8960_MATCH = "wm8960"
HDMI_MATCH = "vc4-hdmi"
USB_USBID_FILENAME = "usbid"

# Forgiving RMS floor: plughw resampling can produce quiet buffers; set low
# enough to pass real (non-silent) recordings while rejecting all-zero buffers.
_CAPTURE_RMS_FLOOR = 10.0

# State directory where selfcheck writes its JSON status.
_DEFAULT_STATE_DIR = "/var/lib/arlowe/state"

# Retry defaults for the selfcheck sentinels.
_DEFAULT_RETRIES = 3
_RETRY_SLEEP_S = 1.0

# Regex for /proc/asound/cards lines:
#   " 0 [wm8960soundcard]: wm8960-soundcard - wm8960-soundcard"
_CARDS_LINE_RE = re.compile(
    r"^\s*(\d+)\s+\[([^\]]+)\]\s*:\s*\S+\s+-\s+(.+)$"
)


def enumerate_cards(proc_root: str = "/proc/asound") -> list:
    """Parse /proc/asound and return a list of card dicts.

    Each dict contains:
      index       int   ALSA card index N (ephemeral; used only to build plughw:N,0)
      id          str   Stable card-id token (from /proc/asound/card<N>/id)
      longname    str   Human-readable card name from /proc/asound/cards
      is_usb      bool  True if the card is a USB audio device
      is_wm8960   bool  True if the card is the WM8960 codec (Whisplay HAT)
      is_hdmi     bool  True if the card is a vc4-hdmi output
      has_capture bool  True if any pcm*c (capture) directory exists under card<N>/
      has_playback bool True if any pcm*p (playback) directory exists under card<N>/

    proc_root is parameterized so tests can inject fixture trees without real hardware.
    """
    cards_path = Path(proc_root) / "cards"
    if not cards_path.exists():
        return []

    cards = []
    for line in cards_path.read_text().splitlines():
        m = _CARDS_LINE_RE.match(line)
        if not m:
            continue
        index = int(m.group(1))
        bracketed_id = m.group(2).strip()
        longname = m.group(3).strip()

        card_dir = Path(proc_root) / f"card{index}"

        # /proc/asound/card<N>/id is the canonical stable card-id; the bracketed
        # name in the cards file is usually the same but /id is authoritative.
        id_file = card_dir / "id"
        card_id = id_file.read_text().strip() if id_file.exists() else bracketed_id

        # Presence of a usbid file reliably marks USB audio cards.
        usbid_file = card_dir / USB_USBID_FILENAME
        is_usb = usbid_file.exists()

        is_wm8960 = WM8960_MATCH in card_id.lower() or WM8960_MATCH in longname.lower()
        is_hdmi = HDMI_MATCH in card_id.lower() or HDMI_MATCH in longname.lower()

        # pcm*c directories indicate capture capability; pcm*p indicate playback.
        # glob returns empty list if card_dir doesn't exist, so no guard needed.
        has_capture = bool(glob.glob(str(card_dir / "pcm*c")))
        has_playback = bool(glob.glob(str(card_dir / "pcm*p")))

        cards.append({
            "index": index,
            "id": card_id,
            "longname": longname,
            "is_usb": is_usb,
            "is_wm8960": is_wm8960,
            "is_hdmi": is_hdmi,
            "has_capture": has_capture,
            "has_playback": has_playback,
        })

    return cards


def _plughw(index: int) -> str:
    return f"plughw:{index},0"


def _resolve_override(override_token: str | None, cards: list) -> dict | None:
    """Return the card matching override_token, or None if absent/auto."""
    if not override_token or override_token.lower() == "auto":
        return None
    token = override_token.strip()
    for card in cards:
        if card["id"] == token:
            return card
    # Token supplied but card not present — caller falls back to auto-pick.
    return None


def resolve_capture(
    override_token: str | None = None,
    cards: list | None = None,
    proc_root: str = "/proc/asound",
) -> str | None:
    """Resolve the capture (mic) device string.

    Priority:
      1. override_token resolves to a present card with capture capability
      2. Auto-pick: first USB capture card (lowest index)
      3. Auto-pick: first wm8960 capture card (lowest index)
      4. None — genuine "no mic" failure; caller handles this

    Returns plughw:N,0 string or None.
    """
    if cards is None:
        cards = enumerate_cards(proc_root)

    # Sort by index for deterministic lowest-index tie-breaking.
    cards_sorted = sorted(cards, key=lambda c: c["index"])

    override_card = _resolve_override(override_token, cards_sorted)
    if override_card is not None and override_card["has_capture"]:
        return _plughw(override_card["index"])

    # Auto-pick: USB first.
    for card in cards_sorted:
        if card["is_usb"] and card["has_capture"]:
            return _plughw(card["index"])

    # Auto-pick: onboard/HAT codec (wm8960) fallback.
    for card in cards_sorted:
        if card["is_wm8960"] and card["has_capture"]:
            return _plughw(card["index"])

    return None


def resolve_playback(
    override_token: str | None = None,
    cards: list | None = None,
    proc_root: str = "/proc/asound",
) -> str | None:
    """Resolve the playback (speaker) device string.

    Priority:
      1. override_token resolves to a present card with playback capability
      2. Auto-pick: first USB playback card (lowest index)
      3. Auto-pick: wm8960 codec (Whisplay HAT on this hardware)
      4. Auto-pick: HDMI (last resort — vc4-hdmi*)
      5. None — no playback card found

    Returns plughw:N,0 string or None.
    """
    if cards is None:
        cards = enumerate_cards(proc_root)

    cards_sorted = sorted(cards, key=lambda c: c["index"])

    override_card = _resolve_override(override_token, cards_sorted)
    if override_card is not None and override_card["has_playback"]:
        return _plughw(override_card["index"])

    # Auto-pick: USB first.
    for card in cards_sorted:
        if card["is_usb"] and card["has_playback"]:
            return _plughw(card["index"])

    # Auto-pick: wm8960 codec (Whisplay HAT).
    for card in cards_sorted:
        if card["is_wm8960"] and card["has_playback"]:
            return _plughw(card["index"])

    # Auto-pick: HDMI as last resort.
    for card in cards_sorted:
        if card["is_hdmi"] and card["has_playback"]:
            return _plughw(card["index"])

    return None


def portaudio_index_for_card(
    card_id_or_plughw: str,
    pa=None,
    proc_root: str = "/proc/asound",
) -> int | None:
    """Find the PortAudio input device index for a given ALSA card.

    The wake-word loop uses pyaudio (PortAudio), which has a separate device
    namespace from ALSA. This helper maps an ALSA card to a PortAudio device
    by substring-matching the card's longname/id against PortAudio device names,
    so the wake-word mic follows the same auto-detected/overridden card.

    When pa is None the function imports pyaudio lazily and constructs a
    PyAudio instance; callers may supply their own instance (real or stub)
    in which case no import of pyaudio is attempted.  This keeps the module
    importable in CI where pyaudio is not installed.

    Args:
        card_id_or_plughw: ALSA card-id token or plughw:N,0 string.
        pa: A pyaudio.PyAudio()-compatible instance.  If None, pyaudio is
            imported and instantiated here (caller is then responsible for
            nothing; the instance is terminated before return).
        proc_root: Root of the proc/asound tree; injectable for tests.

    Returns:
        PortAudio device index, or None if no name match (caller falls back
        to PortAudio default).
    """
    if pa is None:
        try:
            import pyaudio  # noqa: PLC0415 — intentionally lazy
            pa = pyaudio.PyAudio()
        except ImportError:
            return None

    # Normalise: strip plughw prefix to get a bare token for name matching.
    token = card_id_or_plughw
    if token.startswith("plughw:"):
        # plughw:N,0 -> extract N and look up the card id in proc_root
        m = re.match(r"plughw:(\d+)", token)
        if m:
            card_dir = Path(proc_root) / f"card{m.group(1)}"
            id_file = card_dir / "id"
            if id_file.exists():
                token = id_file.read_text().strip()

    token_lower = token.lower()
    count = pa.get_device_count()
    for i in range(count):
        info = pa.get_device_info_by_index(i)
        if info.get("maxInputChannels", 0) > 0:
            name = info.get("name", "").lower()
            if token_lower in name:
                return i

    return None


# ---------------------------------------------------------------------------
# Boot-check sentinels — capture RMS + playback tone, retry-then-report
# ---------------------------------------------------------------------------

def _default_capture_runner(device: str) -> bytes:
    """Record ~1 s of audio from device, return raw S16_LE PCM bytes.

    Runs arecord and returns the WAV/raw bytes; raises subprocess.CalledProcessError
    on non-zero exit or OSError if the binary is missing.
    """
    result = subprocess.run(
        [
            "arecord",
            "-D", device,
            "-f", "S16_LE",
            "-r", "16000",
            "-c", "1",
            "-d", "1",
            "--quiet",
        ],
        capture_output=True,
        check=True,
        timeout=5,
    )
    return result.stdout


def _default_playback_runner(device: str) -> None:
    """Emit a short 440 Hz tone to device.

    Uses sox + aplay pipeline; raises subprocess.CalledProcessError on failure.
    Falls back to aplay with a generated WAV if sox is unavailable.
    """
    try:
        sox = subprocess.run(
            ["sox", "-n", "-t", "wav", "-", "synth", "0.3", "sine", "440"],
            capture_output=True,
            check=True,
            timeout=5,
        )
        subprocess.run(
            ["aplay", "-D", device, "--quiet"],
            input=sox.stdout,
            capture_output=True,
            check=True,
            timeout=5,
        )
    except FileNotFoundError:
        # sox not available — generate a minimal WAV header with silence and
        # play it; success = aplay exits 0 (locked decision: no acoustic check).
        subprocess.run(
            ["aplay", "-D", device, "-f", "S16_LE", "-r", "16000", "-c", "1", "--quiet"],
            input=b"\x00" * 32000,
            capture_output=True,
            check=True,
            timeout=5,
        )


def _rms_from_pcm(raw_bytes: bytes) -> float:
    """Compute RMS of raw S16_LE PCM bytes.

    Skips any WAV header (looks for 'data' chunk) so arecord output works
    whether it includes a header or not.  Returns 0.0 for empty input.
    """
    try:
        import numpy as np  # noqa: PLC0415 — intentionally lazy; numpy is a voice dep
    except ImportError:
        # Fallback: pure-Python RMS without numpy (slower but correct).
        import struct
        if len(raw_bytes) < 2:
            return 0.0
        # Skip WAV header if present.
        data = _strip_wav_header(raw_bytes)
        n_samples = len(data) // 2
        if n_samples == 0:
            return 0.0
        samples = struct.unpack(f"<{n_samples}h", data[:n_samples * 2])
        mean_sq = sum(s * s for s in samples) / n_samples
        return mean_sq ** 0.5

    data = _strip_wav_header(raw_bytes)
    if len(data) < 2:
        return 0.0
    samples = np.frombuffer(data, dtype=np.int16).astype(np.float64)
    if len(samples) == 0:
        return 0.0
    return float(np.sqrt(np.mean(samples ** 2)))


def _strip_wav_header(raw_bytes: bytes) -> bytes:
    """Strip a WAV header if present; return the raw PCM data portion."""
    # WAV 'data' chunk marker: search for b'data' and skip 8 bytes (chunk id + size).
    idx = raw_bytes.find(b"data")
    if idx != -1 and idx + 8 <= len(raw_bytes):
        return raw_bytes[idx + 8:]
    return raw_bytes


def _run_capture_sentinel(
    device: str,
    capture_runner,
    retries: int,
) -> dict:
    """Run the capture RMS sentinel, retry up to retries times.

    Returns a dict with keys: device, ok (bool), error (str or None).
    Never raises.
    """
    last_error = None
    for attempt in range(retries):
        try:
            raw = capture_runner(device)
            rms = _rms_from_pcm(raw)
            if rms >= _CAPTURE_RMS_FLOOR:
                return {"device": device, "ok": True}
            last_error = f"RMS {rms:.1f} below floor {_CAPTURE_RMS_FLOOR}"
        except Exception as exc:
            last_error = str(exc)
        if attempt < retries - 1:
            time.sleep(_RETRY_SLEEP_S)
    return {"device": device, "ok": False, "error": last_error}


def _run_playback_sentinel(
    device: str,
    playback_runner,
    retries: int,
) -> dict:
    """Run the playback tone sentinel, retry up to retries times.

    Success = playback_runner exits without exception (locked decision: no
    acoustic loopback; exit-0 is sufficient proof).  Never raises.
    """
    last_error = None
    for attempt in range(retries):
        try:
            playback_runner(device)
            return {"device": device, "ok": True}
        except Exception as exc:
            last_error = str(exc)
        if attempt < retries - 1:
            time.sleep(_RETRY_SLEEP_S)
    return {"device": device, "ok": False, "error": last_error}


def selfcheck(
    state_dir: str | None = _DEFAULT_STATE_DIR,
    retries: int = _DEFAULT_RETRIES,
    capture_runner=None,
    playback_runner=None,
    proc_root: str = "/proc/asound",
) -> dict:
    """Run the audio boot-check sentinel.

    Resolves capture and playback devices, runs each sentinel independently
    with up to `retries` attempts, persists a Phase-11-consumable JSON status
    to state_dir, emits a greppable [arlowe-audio] journal line to stderr, and
    returns the status dict.

    Args:
        state_dir: Directory where audio-selfcheck.json is written atomically.
                   None or unwritable => skip file write (no crash).
        retries:   Max attempts per sentinel before reporting failure.
        capture_runner: Callable(device: str) -> bytes.  Defaults to the real
                        arecord helper; inject a fake for unit tests.
        playback_runner: Callable(device: str) -> None.  Defaults to the real
                         sox+aplay helper; inject a fake for unit tests.
        proc_root: /proc/asound root; injectable for tests.

    Returns:
        {
          "check": "audio",
          "capture": {"device": str|None, "ok": bool, "error": str},
          "playback": {"device": str|None, "ok": bool, "error": str},
          "ts": "<iso8601>"
        }
    """
    if capture_runner is None:
        capture_runner = _default_capture_runner
    if playback_runner is None:
        playback_runner = _default_playback_runner

    cap_device = resolve_capture(proc_root=proc_root)
    play_device = resolve_playback(proc_root=proc_root)

    if cap_device is not None:
        cap_result = _run_capture_sentinel(cap_device, capture_runner, retries)
    else:
        cap_result = {"device": None, "ok": False, "error": "no capture device found"}

    if play_device is not None:
        play_result = _run_playback_sentinel(play_device, playback_runner, retries)
    else:
        play_result = {"device": None, "ok": False, "error": "no playback device found"}

    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    status = {
        "check": "audio",
        "capture": cap_result,
        "playback": play_result,
        "ts": ts,
    }

    _persist_status(status, state_dir)
    _emit_journal_line(cap_result, play_result)

    return status


def _persist_status(status: dict, state_dir: str | None) -> None:
    """Atomically write status JSON to state_dir/audio-selfcheck.json.

    Skips silently if state_dir is None or the directory is unwritable.
    """
    if not state_dir:
        return
    try:
        state_path = Path(state_dir)
        state_path.mkdir(parents=True, exist_ok=True)
        target = state_path / "audio-selfcheck.json"
        payload = json.dumps(status, indent=2)
        # Atomic write: write to a temp file in the same dir, then rename.
        with tempfile.NamedTemporaryFile(
            mode="w",
            dir=state_path,
            prefix=".audio-selfcheck-",
            suffix=".json.tmp",
            delete=False,
        ) as tf:
            tf.write(payload)
            tmp_path = Path(tf.name)
        tmp_path.rename(target)
    except Exception as exc:
        print(f"[arlowe-audio] WARN could not write state: {exc}", file=sys.stderr)


def _emit_journal_line(cap_result: dict, play_result: dict) -> None:
    """Print a greppable [arlowe-audio] journal line to stderr."""
    cap_status = "ok" if cap_result.get("ok") else "FAIL"
    play_status = "ok" if play_result.get("ok") else "FAIL"
    cap_device = cap_result.get("device") or "none"
    play_device = play_result.get("device") or "none"
    print(
        f"[arlowe-audio] selfcheck capture={cap_status} device={cap_device}"
        f" playback={play_status} device={play_device}",
        file=sys.stderr,
    )


# ---------------------------------------------------------------------------
# CLI surface — lazy config import so pure functions work without a config file
# ---------------------------------------------------------------------------

def _cli_main() -> None:
    parser = argparse.ArgumentParser(
        prog="python3 -m arlowe_audio",
        description="Resolve ALSA audio devices from /proc/asound.",
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument(
        "--resolve-capture",
        action="store_true",
        help="Print resolved capture plughw string (exit 1 if none).",
    )
    group.add_argument(
        "--resolve-playback",
        action="store_true",
        help="Print resolved playback plughw string (exit 1 if none).",
    )
    group.add_argument(
        "--list",
        action="store_true",
        help="Print enumerated cards as JSON.",
    )
    group.add_argument(
        "--selfcheck",
        action="store_true",
        help=(
            "Run capture+playback sentinels, write JSON status to "
            "/var/lib/arlowe/state/audio-selfcheck.json, print JSON to stdout. "
            "Exit 0 if both sentinels pass, exit 1 if either fails."
        ),
    )
    args = parser.parse_args()

    # Import config lazily so tests of pure functions don't require a config file.
    try:
        from arlowe_config import load as _load_config  # noqa: PLC0415
        cfg = _load_config()
        capture_override = cfg.get("audio", {}).get("capture_device", "auto")
        playback_override = cfg.get("audio", {}).get("playback_device", "auto")
    except Exception:
        capture_override = "auto"
        playback_override = "auto"

    if args.list:
        cards = enumerate_cards()
        print(json.dumps(cards, indent=2))
    elif args.resolve_capture:
        result = resolve_capture(capture_override)
        if result is None:
            sys.exit(1)
        print(result)
    elif args.resolve_playback:
        result = resolve_playback(playback_override)
        if result is None:
            sys.exit(1)
        print(result)
    elif args.selfcheck:
        status = selfcheck()
        print(json.dumps(status, indent=2))
        if not (status["capture"]["ok"] and status["playback"]["ok"]):
            sys.exit(1)


if __name__ == "__main__":
    _cli_main()
