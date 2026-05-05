#!/usr/bin/env python3
"""
Test the custom "Hey Arlowe" wake word verifier.

Listens for wake word detections using the base model + verifier combination.

State is read from environment:
  ARLOWE_WAKE_WORD_STATE    — base dir (default /var/lib/arlowe/wake-word)
  ARLOWE_WAKE_WORD_VERIFIER — verifier .pkl path (default STATE_DIR/verifier.pkl)
"""
import os
import sys

_extra = os.environ.get("ARLOWE_VENV_SITE_PACKAGES")
if _extra and _extra not in sys.path:
    sys.path.insert(0, _extra)

import pickle
import pyaudio
import numpy as np
import openwakeword
from openwakeword.model import Model

_STATE_DIR = os.environ.get("ARLOWE_WAKE_WORD_STATE", "/var/lib/arlowe/wake-word")
VERIFIER_MODEL = os.environ.get("ARLOWE_WAKE_WORD_VERIFIER",
                                os.path.join(_STATE_DIR, "verifier.pkl"))
BASE_MODEL = "hey_jarvis"

# Detection thresholds
BASE_THRESHOLD = 0.3       # Threshold for base model detection
VERIFIER_THRESHOLD = 0.6   # Threshold for verifier confirmation

def main():
    # Check for verifier model
    if not os.path.exists(VERIFIER_MODEL):
        print(f"Verifier model not found: {VERIFIER_MODEL}")
        print("Run train_verifier.py first!")
        return 1

    print("=" * 50)
    print("HEY ARLOWE WAKE WORD TEST")
    print("=" * 50)

    # Load models
    print("\nLoading base model...", end=" ", flush=True)
    models = [p for p in openwakeword.get_pretrained_model_paths() if 'jarvis' in p]
    oww_model = Model(wakeword_model_paths=models)
    print("OK")

    print("Loading verifier model...", end=" ", flush=True)
    with open(VERIFIER_MODEL, 'rb') as f:
        verifier = pickle.load(f)
    print("OK")

    # Audio setup
    pa = pyaudio.PyAudio()

    # Find WM8960 device
    device_index = 0
    for i in range(pa.get_device_count()):
        info = pa.get_device_info_by_index(i)
        if 'wm8960' in info['name'].lower() and info['maxInputChannels'] > 0:
            device_index = i
            break

    stream = pa.open(
        format=pyaudio.paInt16,
        channels=1,
        rate=16000,
        input=True,
        frames_per_buffer=1280,
        input_device_index=device_index
    )

    print(f"\nListening for 'Hey Arlowe'...")
    print("Press Ctrl+C to stop\n")

    try:
        while True:
            # Get audio chunk
            audio = np.frombuffer(
                stream.read(1280, exception_on_overflow=False),
                dtype=np.int16
            )

            # Get base model prediction
            prediction = oww_model.predict(audio)

            for wake_word, score in prediction.items():
                # Show activity
                if score > 0.1:
                    print(f"Base: {score:.3f}", end="")

                # Check if base model triggered
                if score > BASE_THRESHOLD:
                    # Get features for verifier
                    features = oww_model.preprocessor.get_features(
                        oww_model.model_inputs[wake_word]
                    )

                    # Run verifier
                    verifier_score = verifier.predict_proba([features.flatten()])[0][1]
                    print(f" -> Verifier: {verifier_score:.3f}", end="")

                    if verifier_score > VERIFIER_THRESHOLD:
                        print(f" WAKE WORD DETECTED!")
                        oww_model.reset()
                    else:
                        print(" (rejected)")
                elif score > 0.1:
                    print()  # newline for activity display

    except KeyboardInterrupt:
        print("\n\nStopped.")
    finally:
        stream.close()
        pa.terminate()

    return 0

if __name__ == "__main__":
    sys.exit(main())
