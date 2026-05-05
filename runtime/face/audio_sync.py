#!/usr/bin/env python3
"""
Audio Sync Module for Real-time TTS Face Animation

Analyzes audio amplitude in real-time to sync mouth movements
with speech during TTS playback.
"""
import wave
import numpy as np
import threading
import time
from typing import Callable, Optional
from pathlib import Path


class AudioSyncAnalyzer:
    """Real-time audio amplitude analyzer for lip-sync"""

    def __init__(self,
                 sample_rate: int = 16000,
                 window_ms: int = 50,
                 smoothing: float = 0.3):
        """
        Initialize audio sync analyzer

        Args:
            sample_rate: Audio sample rate in Hz
            window_ms: Analysis window size in milliseconds
            smoothing: Smoothing factor (0=no smoothing, 1=max smoothing)
        """
        self.sample_rate = sample_rate
        self.window_size = int(sample_rate * window_ms / 1000)
        self.smoothing = smoothing
        self.is_playing = False
        self.playback_thread = None
        self._stop_event = threading.Event()

    def analyze_amplitude(self, audio_data: np.ndarray) -> float:
        """
        Analyze audio amplitude and return normalized mouth openness

        Args:
            audio_data: Audio samples as numpy array

        Returns:
            Mouth openness value between 0.0 (closed) and 1.0 (fully open)
        """
        if len(audio_data) == 0:
            return 0.0

        # Calculate RMS amplitude
        rms = np.sqrt(np.mean(audio_data.astype(float) ** 2))

        # Normalize to typical speech range (adjust based on audio level)
        # Typical RMS for speech is around 1000-5000 for int16 audio
        normalized = min(1.0, rms / 3000.0)

        # Apply non-linear scaling for more natural mouth movement
        # Use power curve to make mouth more responsive to louder sounds
        mouth_open = normalized ** 0.7

        return mouth_open

    def extract_phoneme_features(self, audio_data: np.ndarray) -> dict:
        """
        Extract phoneme-like features from audio for enhanced animation

        Args:
            audio_data: Audio samples as numpy array

        Returns:
            Dictionary with features: amplitude, frequency_center, energy
        """
        if len(audio_data) == 0:
            return {'amplitude': 0.0, 'frequency_center': 0.0, 'energy': 0.0}

        # RMS amplitude
        rms = np.sqrt(np.mean(audio_data.astype(float) ** 2))
        amplitude = min(1.0, rms / 3000.0)

        # Spectral centroid (brightness of sound)
        fft = np.fft.rfft(audio_data)
        magnitude = np.abs(fft)
        freqs = np.fft.rfftfreq(len(audio_data), 1.0 / self.sample_rate)

        if magnitude.sum() > 0:
            centroid = np.sum(freqs * magnitude) / magnitude.sum()
            # Normalize to 0-1 range (assume speech is 100-3000 Hz)
            frequency_center = min(1.0, max(0.0, (centroid - 100) / 2900))
        else:
            frequency_center = 0.5

        # Energy in different bands for expression hints
        energy = amplitude

        return {
            'amplitude': amplitude,
            'frequency_center': frequency_center,
            'energy': energy
        }

    def sync_with_audio_file(self,
                             audio_path: str,
                             callback: Callable[[float, dict], None],
                             update_rate: int = 30):
        """
        Analyze audio file and call callback with mouth position updates

        Args:
            audio_path: Path to WAV audio file
            callback: Function to call with (mouth_open, features) every update
            update_rate: Updates per second (Hz)
        """
        self.is_playing = True
        self._stop_event.clear()

        # Load WAV file
        with wave.open(audio_path, 'rb') as wf:
            sample_rate = wf.getframerate()
            n_channels = wf.getnchannels()
            n_frames = wf.getnframes()
            audio_bytes = wf.readframes(n_frames)

        # Convert to numpy array
        audio_data = np.frombuffer(audio_bytes, dtype=np.int16)

        # If stereo, convert to mono
        if n_channels == 2:
            audio_data = audio_data.reshape(-1, 2).mean(axis=1).astype(np.int16)

        # Calculate total duration
        duration = len(audio_data) / sample_rate

        # Update interval
        update_interval = 1.0 / update_rate
        samples_per_update = int(sample_rate * update_interval)

        # Smooth mouth position
        smooth_mouth = 0.0

        # Analyze and send updates
        start_time = time.time()
        update_count = 0

        while update_count * samples_per_update < len(audio_data) and not self._stop_event.is_set():
            # Calculate position for this update
            position = update_count * samples_per_update

            # Get audio window
            window_end = min(position + samples_per_update, len(audio_data))
            window = audio_data[position:window_end]

            if len(window) > 0:
                # Analyze amplitude
                mouth_open = self.analyze_amplitude(window)
                features = self.extract_phoneme_features(window)

                # Apply smoothing
                smooth_mouth = (self.smoothing * smooth_mouth +
                                (1 - self.smoothing) * mouth_open)

                # Send update
                callback(smooth_mouth, features)

            update_count += 1

            # Sleep until next update time
            next_update_time = start_time + (update_count * update_interval)
            sleep_time = next_update_time - time.time()
            if sleep_time > 0:
                time.sleep(sleep_time)

        # Ensure mouth closes at end
        callback(0.0, {'amplitude': 0.0, 'frequency_center': 0.5, 'energy': 0.0})
        self.is_playing = False

    def start_sync_thread(self,
                          audio_path: str,
                          callback: Callable[[float, dict], None],
                          update_rate: int = 30):
        """
        Start audio sync in background thread

        Args:
            audio_path: Path to WAV audio file
            callback: Function to call with (mouth_open, features) every update
            update_rate: Updates per second (Hz)
        """
        self.stop_sync()  # Stop any existing sync

        def sync_worker():
            try:
                self.sync_with_audio_file(audio_path, callback, update_rate)
            except Exception as e:
                print(f"  [audio_sync error] {e}", flush=True)
                self.is_playing = False

        self.playback_thread = threading.Thread(target=sync_worker, daemon=True)
        self.playback_thread.start()

    def stop_sync(self):
        """Stop audio sync"""
        self._stop_event.set()
        if self.playback_thread and self.playback_thread.is_alive():
            self.playback_thread.join(timeout=1.0)
        self.is_playing = False


def get_audio_duration(audio_path: str) -> float:
    """Get duration of audio file in seconds"""
    try:
        with wave.open(audio_path, 'rb') as wf:
            frames = wf.getnframes()
            rate = wf.getframerate()
            return frames / float(rate)
    except Exception as e:
        print(f"  [duration error] {e}", flush=True)
        return 0.0


if __name__ == "__main__":
    # Test the analyzer
    import sys

    if len(sys.argv) < 2:
        print("Usage: python audio_sync.py <audio_file.wav>")
        sys.exit(1)

    audio_file = sys.argv[1]

    def print_callback(mouth_open: float, features: dict):
        bar = "#" * int(mouth_open * 40)
        print(f"\rMouth: [{bar:<40}] {mouth_open:.2f} | "
              f"Freq: {features['frequency_center']:.2f} | "
              f"Energy: {features['energy']:.2f}", end="", flush=True)

    analyzer = AudioSyncAnalyzer()
    print(f"Analyzing: {audio_file}")
    print(f"Duration: {get_audio_duration(audio_file):.2f}s")
    print("\nLip-sync visualization:")

    analyzer.sync_with_audio_file(audio_file, print_callback, update_rate=30)
    print("\n\nDone!")
