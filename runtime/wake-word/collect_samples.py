#!/usr/bin/env python3
"""
Wake Word Sample Collector
Collects positive ("Hey Arlowe") and negative (other speech) samples for verifier training.

Usage:
  ./collect_samples.py positive   # Record wake word samples
  ./collect_samples.py negative   # Record other speech samples
  ./collect_samples.py status     # Show current counts

Environment:
  ARLOWE_WAKE_WORD_STATE -- base dir containing positive/ and negative/ subdirs
                            (default /var/lib/arlowe/wake-word)
"""
import sys
import os
import time
import wave
import pyaudio
import numpy as np
from datetime import datetime

_STATE_DIR = os.environ.get("ARLOWE_WAKE_WORD_STATE", "/var/lib/arlowe/wake-word")
POSITIVE_DIR = os.path.join(_STATE_DIR, "positive")
NEGATIVE_DIR = os.path.join(_STATE_DIR, "negative")

# Audio settings (must match openWakeWord expectations)
SAMPLE_RATE = 16000
CHANNELS = 1
CHUNK = 1024
FORMAT = pyaudio.paInt16
RECORD_SECONDS = 2.0  # Duration per sample


def ensure_dirs():
    os.makedirs(POSITIVE_DIR, exist_ok=True)
    os.makedirs(NEGATIVE_DIR, exist_ok=True)


def get_next_filename(sample_type: str) -> str:
    """Get next available filename for the sample type."""
    directory = POSITIVE_DIR if sample_type == "positive" else NEGATIVE_DIR
    existing = [f for f in os.listdir(directory) if f.endswith('.wav')]
    next_num = len(existing) + 1
    timestamp = datetime.now().strftime("%H%M%S")
    return os.path.join(directory, f"{sample_type}_{next_num:03d}_{timestamp}.wav")


def record_sample(filename: str) -> bool:
    """Record a single audio sample to file."""
    pa = pyaudio.PyAudio()

    # Find WM8960 device
    device_index = None
    for i in range(pa.get_device_count()):
        info = pa.get_device_info_by_index(i)
        if 'wm8960' in info['name'].lower() and info['maxInputChannels'] > 0:
            device_index = i
            break

    if device_index is None:
        device_index = 0  # fallback to default

    try:
        stream = pa.open(
            format=FORMAT,
            channels=CHANNELS,
            rate=SAMPLE_RATE,
            input=True,
            input_device_index=device_index,
            frames_per_buffer=CHUNK
        )

        frames = []
        num_chunks = int(SAMPLE_RATE / CHUNK * RECORD_SECONDS)

        print("Recording...", end="", flush=True)
        for _ in range(num_chunks):
            data = stream.read(CHUNK, exception_on_overflow=False)
            frames.append(data)
        print(" Done!")

        stream.stop_stream()
        stream.close()
        pa.terminate()

        # Save to WAV file
        with wave.open(filename, 'wb') as wf:
            wf.setnchannels(CHANNELS)
            wf.setsampwidth(pa.get_sample_size(FORMAT))
            wf.setframerate(SAMPLE_RATE)
            wf.writeframes(b''.join(frames))

        return True

    except Exception as e:
        print(f"\nError: {e}")
        pa.terminate()
        return False


def collect_positive():
    """Collect positive wake word samples."""
    print("=" * 50)
    print("POSITIVE SAMPLE COLLECTION")
    print("=" * 50)
    print("\nSay 'Hey Arlowe' clearly when prompted.")
    print("Vary your tone, distance from mic, and speaking speed.")
    print("Press Enter to record, 'q' to quit.\n")

    count = len([f for f in os.listdir(POSITIVE_DIR) if f.endswith('.wav')])
    target = 50

    while count < target:
        remaining = target - count
        print(f"[{count}/{target}] {remaining} samples remaining")

        user_input = input("Press Enter to record (or 'q' to quit): ").strip().lower()
        if user_input == 'q':
            break

        filename = get_next_filename("positive")
        if record_sample(filename):
            count += 1
            print(f"Saved: {os.path.basename(filename)}\n")
        else:
            print("Recording failed, try again.\n")

    print(f"\nCollection complete! {count} positive samples in {POSITIVE_DIR}")


def collect_negative():
    """Collect negative (non-wake-word) speech samples."""
    print("=" * 50)
    print("NEGATIVE SAMPLE COLLECTION")
    print("=" * 50)
    print("\nSay random phrases that are NOT 'Hey Arlowe'.")
    print("Examples: 'Hello', 'What time is it', 'Play some music'")
    print("Press Enter to record, 'q' to quit.\n")

    count = len([f for f in os.listdir(NEGATIVE_DIR) if f.endswith('.wav')])
    target = 30

    while count < target:
        remaining = target - count
        print(f"[{count}/{target}] {remaining} samples remaining")

        user_input = input("Press Enter to record (or 'q' to quit): ").strip().lower()
        if user_input == 'q':
            break

        filename = get_next_filename("negative")
        if record_sample(filename):
            count += 1
            print(f"Saved: {os.path.basename(filename)}\n")
        else:
            print("Recording failed, try again.\n")

    print(f"\nCollection complete! {count} negative samples in {NEGATIVE_DIR}")


def show_status():
    """Show current sample counts."""
    pos_count = len([f for f in os.listdir(POSITIVE_DIR) if f.endswith('.wav')])
    neg_count = len([f for f in os.listdir(NEGATIVE_DIR) if f.endswith('.wav')])

    print("\nCurrent Sample Status:")
    print(f"  Positive ('Hey Arlowe'): {pos_count}/50")
    print(f"  Negative (other speech): {neg_count}/30")

    if pos_count >= 50 and neg_count >= 30:
        print("\nReady to train! Run: ./train_verifier.py")
    else:
        print("\nNeed more samples before training.")


def main():
    ensure_dirs()

    if len(sys.argv) < 2:
        print("Usage: ./collect_samples.py [positive|negative|status]")
        show_status()
        return

    action = sys.argv[1].lower()

    if action == "positive":
        collect_positive()
    elif action == "negative":
        collect_negative()
    elif action == "status":
        show_status()
    else:
        print(f"Unknown action: {action}")
        print("Usage: ./collect_samples.py [positive|negative|status]")

if __name__ == "__main__":
    main()
