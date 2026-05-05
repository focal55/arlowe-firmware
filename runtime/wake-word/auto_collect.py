#!/usr/bin/env python3
"""Auto-collect wake word samples with voice prompts.

Samples are written to:
  ARLOWE_WAKE_WORD_STATE/positive/  (wake-word recordings)
  ARLOWE_WAKE_WORD_STATE/negative/  (ambient/non-wake recordings)

Environment:
  ARLOWE_WAKE_WORD_STATE — base dir (default /var/lib/arlowe/wake-word)
  ARLOWE_SPEAK_BIN       — path to speak helper (default /usr/local/bin/speak)
  ARLOWE_ALSA_DEVICE     — ALSA capture device (default plughw:2,0)
"""
import os
import sys
import time
import subprocess
from pathlib import Path

_STATE_DIR = os.environ.get("ARLOWE_WAKE_WORD_STATE", "/var/lib/arlowe/wake-word")
_SPEAK_BIN = os.environ.get("ARLOWE_SPEAK_BIN", "/usr/local/bin/speak")
_ALSA_DEVICE = os.environ.get("ARLOWE_ALSA_DEVICE", "plughw:2,0")

POSITIVE_DIR = Path(_STATE_DIR) / "positive"
NEGATIVE_DIR = Path(_STATE_DIR) / "negative"


def speak(text):
    if os.path.exists(_SPEAK_BIN):
        subprocess.run([_SPEAK_BIN, text], capture_output=True)


def record_sample(output_path, duration=2):
    """Record a sample."""
    subprocess.run([
        "arecord", "-D", _ALSA_DEVICE, "-f", "S16_LE",
        "-r", "16000", "-c", "1", "-d", str(duration),
        str(output_path)
    ], capture_output=True)


def beep():
    """Short beep sound via speaker."""
    subprocess.run(
        f"sox -n -r 48000 -c 2 /tmp/beep.wav synth 0.15 sine 800 vol 0.5 && aplay -D {_ALSA_DEVICE} -q /tmp/beep.wav",
        shell=True, capture_output=True
    )


def collect_positive(count=50):
    """Collect positive 'Hey Arlowe' samples."""
    POSITIVE_DIR.mkdir(parents=True, exist_ok=True)
    existing = len(list(POSITIVE_DIR.glob("*.wav")))

    speak(f"Recording hey arlowe samples. Say it clearly after each beep. Starting in 3 seconds.")
    time.sleep(3)

    for i in range(existing, count):
        print(f"[{i+1}/{count}] Recording...", flush=True)
        beep()
        time.sleep(0.3)

        output = POSITIVE_DIR / f"sample_{i:03d}.wav"
        record_sample(output, duration=2)
        print(f"  Saved {output.name}", flush=True)
        time.sleep(0.5)

        if (i + 1) % 10 == 0:
            speak(f"{i + 1} done. {count - i - 1} to go.")
            time.sleep(1)

    speak("Positive samples complete!")
    print(f"\nCollected {count} positive samples")


def collect_negative(count=30):
    """Collect negative (non-wake-word) samples."""
    NEGATIVE_DIR.mkdir(parents=True, exist_ok=True)
    existing = len(list(NEGATIVE_DIR.glob("*.wav")))

    speak(f"Recording negative samples. Say anything except hey arlowe. Random words, sentences, anything. Starting in 3 seconds.")
    time.sleep(3)

    for i in range(existing, count):
        print(f"[{i+1}/{count}] Recording...", flush=True)
        beep()
        time.sleep(0.3)

        output = NEGATIVE_DIR / f"sample_{i:03d}.wav"
        record_sample(output, duration=2)
        print(f"  Saved {output.name}", flush=True)
        time.sleep(0.5)

        if (i + 1) % 10 == 0:
            speak(f"{i + 1} done. {count - i - 1} to go.")
            time.sleep(1)

    speak("Negative samples complete!")
    print(f"\nCollected {count} negative samples")


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "positive"
    count = int(sys.argv[2]) if len(sys.argv) > 2 else (50 if mode == "positive" else 30)

    if mode == "positive":
        collect_positive(count)
    elif mode == "negative":
        collect_negative(count)
    else:
        print("Usage: auto_collect.py [positive|negative] [count]")
