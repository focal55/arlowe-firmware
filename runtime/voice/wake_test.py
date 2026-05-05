#!/usr/bin/env python3
"""Quick wake word test - say "Hey Jarvis" (closest to Hey Arlowe)"""
# Dependencies provided by /opt/arlowe/venv/ at runtime; see requirements.txt
import sys

import pyaudio
import numpy as np
from openwakeword.model import Model

# Load wake word model
print("Loading wake word model...")
import openwakeword
models = [p for p in openwakeword.get_pretrained_model_paths() if 'jarvis' in p]
oww_model = Model(wakeword_model_paths=models)

# Audio setup
pa = pyaudio.PyAudio()

# Use device 0 (WM8960)
device_index = 0
print(f"Using device index {device_index}")

stream = pa.open(
    format=pyaudio.paInt16,
    channels=1,
    rate=16000,
    input=True,
    frames_per_buffer=1280,
    input_device_index=device_index
)

print("\n🎤 Listening for 'Hey Jarvis' (say it like 'Hey Arlowe')...", flush=True)
print("Press Ctrl+C to stop\n", flush=True)

try:
    while True:
        audio = np.frombuffer(stream.read(1280, exception_on_overflow=False), dtype=np.int16)
        prediction = oww_model.predict(audio)
        
        for wake_word, score in prediction.items():
            if score > 0.1:  # Lower threshold, print any activity
                print(f"Score: {wake_word}: {score:.3f}", flush=True)
            if score > 0.4:  # Detection threshold
                print(f"🔔 WAKE WORD DETECTED! ({wake_word}: {score:.2f})", flush=True)
                oww_model.reset()
except KeyboardInterrupt:
    print("\nStopped.")
finally:
    stream.close()
    pa.terminate()
