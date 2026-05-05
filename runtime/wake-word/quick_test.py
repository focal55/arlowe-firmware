#!/usr/bin/env python3
"""Quick wake word test with audio confirmation.

Loads the base model and optionally a verifier, then listens for ~30 seconds.
If no verifier is found at ARLOWE_WAKE_WORD_VERIFIER the test runs in
base-model-only mode (higher false-positive rate, no speaker gating).

Environment:
  ARLOWE_VENV_SITE_PACKAGES — extra sys.path entry (set in dev / image build)
  ARLOWE_WAKE_WORD_STATE    — base dir (default /var/lib/arlowe/wake-word)
  ARLOWE_WAKE_WORD_VERIFIER — verifier .pkl path (default STATE_DIR/verifier.pkl)
  ARLOWE_SPEAK_BIN          — path to speak helper (default /usr/local/bin/speak)
"""
import os
import sys

_extra = os.environ.get("ARLOWE_VENV_SITE_PACKAGES")
if _extra and _extra not in sys.path:
    sys.path.insert(0, _extra)

import pickle
import subprocess
import pyaudio
import numpy as np
import openwakeword
from openwakeword.model import Model

_STATE_DIR = os.environ.get("ARLOWE_WAKE_WORD_STATE", "/var/lib/arlowe/wake-word")
VERIFIER_MODEL = os.environ.get("ARLOWE_WAKE_WORD_VERIFIER",
                                os.path.join(_STATE_DIR, "verifier.pkl"))
_SPEAK_BIN = os.environ.get("ARLOWE_SPEAK_BIN", "/usr/local/bin/speak")


def speak(text):
    if os.path.exists(_SPEAK_BIN):
        subprocess.run([_SPEAK_BIN, text], capture_output=True)


def main():
    print("Loading models...", flush=True)

    # Load base model
    models = [p for p in openwakeword.get_pretrained_model_paths() if 'jarvis' in p]
    oww_model = Model(wakeword_model_paths=models)

    # Load verifier if present; fall back to base-model-only
    verifier = None
    if os.path.exists(VERIFIER_MODEL):
        with open(VERIFIER_MODEL, 'rb') as f:
            verifier = pickle.load(f)
        print(f"Verifier loaded: {VERIFIER_MODEL}", flush=True)
    else:
        print(f"No verifier at {VERIFIER_MODEL} -- base-model-only mode (threshold 0.7).", flush=True)

    print("Models loaded!", flush=True)

    # Audio setup
    pa = pyaudio.PyAudio()
    stream = pa.open(
        format=pyaudio.paInt16,
        channels=1,
        rate=16000,
        input=True,
        frames_per_buffer=1280,
        input_device_index=0
    )

    speak("Listening for hey arlowe")
    print("Listening... say 'Hey Arlowe'", flush=True)

    detected = False
    loops = 0
    max_loops = 300  # ~30 seconds

    while not detected and loops < max_loops:
        loops += 1
        audio = np.frombuffer(stream.read(1280, exception_on_overflow=False), dtype=np.int16)
        prediction = oww_model.predict(audio)

        for wake_word, score in prediction.items():
            # Base-model-only path (no verifier)
            if verifier is None:
                if score > 0.7:
                    print(f"Base score: {score:.3f} DETECTED!", flush=True)
                    speak("I heard you! Hey Arlowe works!")
                    detected = True
                    break
                continue

            # Verifier path
            if score > 0.25:
                print(f"Base score: {score:.3f}", flush=True)

                # Get verifier score
                features = oww_model.preprocessor.get_features(oww_model.model_inputs[wake_word])
                verifier_score = verifier.predict_proba([features.flatten()])[0][1]
                print(f"Verifier score: {verifier_score:.3f}", flush=True)

                if verifier_score > 0.5:
                    print("DETECTED!", flush=True)
                    speak("I heard you! Hey Arlowe works!")
                    detected = True
                    break

    stream.close()
    pa.terminate()

    if not detected:
        print("Timeout - didn't detect wake word", flush=True)
        speak("Didn't hear the wake word. Let's try again.")

if __name__ == "__main__":
    main()
