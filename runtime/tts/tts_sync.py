#!/usr/bin/env python3
"""
TTS Sync Module - Text-to-Speech with Real-time Face Synchronization

Supports multiple TTS backends:
- Piper (local, fast, ~200ms latency)  [DEFAULT]
- ElevenLabs (cloud, high quality, ~1-2s latency)  [opt-in]

Coordinates TTS audio playback with facial expressions and lip-sync.
"""
import os
import subprocess
import tempfile
import time
import json
import urllib.request
from pathlib import Path
from typing import Optional, Tuple
from enum import Enum

from face.audio_sync import AudioSyncAnalyzer, get_audio_duration


class TTSBackend(Enum):
    PIPER = "piper"           # Local, fast, robotic
    ELEVENLABS = "elevenlabs" # Cloud, quality, natural


# Default ElevenLabs settings
DEFAULT_ELEVENLABS_VOICE = "EXAVITQu4vr4xnSDxMaL"  # Sarah
DEFAULT_ELEVENLABS_MODEL = "eleven_turbo_v2_5"


def _load_elevenlabs_key() -> Optional[str]:
    """Load ElevenLabs API key from (in order):
       1. ELEVENLABS_API_KEY env var
       2. /etc/arlowe/config.yml (Phase 4 overlay; key under tts.elevenlabs.api_key)
       3. None (ElevenLabs disabled)
    NOTE: ElevenLabs is opt-in cloud TTS. Local Piper is the default.
    """
    key = os.environ.get("ELEVENLABS_API_KEY")
    if key:
        return key
    overlay = Path("/etc/arlowe/config.yml")
    if overlay.exists():
        try:
            import yaml  # PyYAML — listed in requirements.txt
            with open(overlay) as f:
                cfg = yaml.safe_load(f) or {}
            return cfg.get("tts", {}).get("elevenlabs", {}).get("api_key")
        except Exception:
            return None
    return None


ELEVENLABS_API_KEY = _load_elevenlabs_key()


def load_elevenlabs_config() -> dict:
    """Load ElevenLabs config from environment and config overlay."""
    config = {
        "api_key": ELEVENLABS_API_KEY,
        "voice_id": os.environ.get("ELEVENLABS_VOICE_ID", DEFAULT_ELEVENLABS_VOICE),
        "model_id": os.environ.get("ELEVENLABS_MODEL_ID", DEFAULT_ELEVENLABS_MODEL),
    }

    # Re-read overlay for voice/model overrides (not just the key)
    overlay = Path("/etc/arlowe/config.yml")
    if overlay.exists():
        try:
            import yaml
            with open(overlay) as f:
                cfg = yaml.safe_load(f) or {}
            tts_cfg = cfg.get("tts", {}).get("elevenlabs", {})
            if tts_cfg.get("voice_id"):
                config["voice_id"] = tts_cfg["voice_id"]
            if tts_cfg.get("model_id"):
                config["model_id"] = tts_cfg["model_id"]
        except Exception:
            pass

    return config


class TTSWithSync:
    """TTS engine with real-time face synchronization and multiple backends"""

    def __init__(self,
                 piper_path: Path,
                 piper_model: Path,
                 play_device: str | None = None,
                 face_api: str = "http://localhost:8080",
                 sync_rate: int = 30,
                 backend: TTSBackend = TTSBackend.PIPER):
        """
        Initialize TTS sync engine

        Args:
            piper_path: Path to Piper TTS executable
            piper_model: Path to Piper voice model
            play_device: ALSA playback device; resolved via arlowe_audio if None
            face_api: URL of face control API
            sync_rate: Face update rate in Hz
            backend: TTS backend to use (PIPER or ELEVENLABS)
        """
        self.piper_path = piper_path
        self.piper_model = piper_model
        if play_device is None:
            try:
                import arlowe_audio  # noqa: PLC0415 — lazy; avoids import-time config dep
                import arlowe_config
                _cfg = arlowe_config.load()
                _play_override = _cfg.get("audio", {}).get("playback_device", "auto")
                play_device = arlowe_audio.resolve_playback(_play_override) or "plughw:2,0"
            except Exception:
                play_device = "plughw:2,0"
        self.play_device = play_device
        self.face_api = face_api
        self.sync_rate = sync_rate
        self.backend = backend
        self.analyzer = AudioSyncAnalyzer(
            sample_rate=16000,
            window_ms=50,
            smoothing=0.25  # Less smoothing for more responsive mouth
        )

        # Load ElevenLabs config
        self._elevenlabs_config = load_elevenlabs_config()

    def set_backend(self, backend: TTSBackend):
        """Switch TTS backend"""
        self.backend = backend
        print(f"  [TTS] Backend switched to: {backend.value}", flush=True)

    def set_elevenlabs_voice(self, voice_id: str):
        """Set ElevenLabs voice ID"""
        self._elevenlabs_config["voice_id"] = voice_id
        print(f"  [TTS] ElevenLabs voice set to: {voice_id}", flush=True)

    def _update_face_mouth(self, mouth_open: float, features: dict):
        """Send mouth position update to face service"""
        try:
            data = json.dumps({"open": mouth_open}).encode()
            req = urllib.request.Request(
                f"{self.face_api}/mouth",
                data=data,
                headers={"Content-Type": "application/json"}
            )
            urllib.request.urlopen(req, timeout=0.5)
        except Exception:
            pass  # Fail silently to avoid blocking audio

    def _set_face_state(self, state: str, bg: Optional[str] = None, source: Optional[str] = None):
        """Update face state"""
        try:
            payload = {"state": state}
            if bg:
                payload["bg"] = bg
            if source is not None:
                payload["source"] = source if source in ("cloud", "local") else ""

            data = json.dumps(payload).encode()
            req = urllib.request.Request(
                f"{self.face_api}/state",
                data=data,
                headers={"Content-Type": "application/json"}
            )
            urllib.request.urlopen(req, timeout=1)
        except Exception as e:
            print(f"  [face error] {e}", flush=True)

    def _generate_piper(self, text: str) -> Tuple[str, float]:
        """Generate audio using Piper (local)"""
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            tmpfile = f.name

        subprocess.run(
            [str(self.piper_path), "--model", str(self.piper_model),
             "--output_file", tmpfile],
            input=text.encode(),
            capture_output=True,
            timeout=30
        )

        duration = get_audio_duration(tmpfile)
        return tmpfile, duration

    def _generate_elevenlabs(self, text: str) -> Tuple[str, float]:
        """Generate audio using ElevenLabs API"""
        config = self._elevenlabs_config

        if not config.get("api_key"):
            raise ValueError(
                "ElevenLabs API key not configured. "
                "Set ELEVENLABS_API_KEY env var or add tts.elevenlabs.api_key to /etc/arlowe/config.yml"
            )

        # Create temp file for audio
        with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as f:
            tmpfile_mp3 = f.name

        # Prepare API request
        url = f"https://api.elevenlabs.io/v1/text-to-speech/{config['voice_id']}"
        payload = {
            "text": text,
            "model_id": config.get("model_id", DEFAULT_ELEVENLABS_MODEL),
            "voice_settings": {
                "stability": 0.5,
                "similarity_boost": 0.75,
                "style": 0.0,
            }
        }

        headers = {
            "Accept": "audio/mpeg",
            "Content-Type": "application/json",
            "xi-api-key": config["api_key"],
        }

        # Make request
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode(),
            headers=headers
        )

        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                with open(tmpfile_mp3, "wb") as f:
                    f.write(response.read())
        except urllib.error.HTTPError as e:
            error_body = e.read().decode()
            raise ValueError(f"ElevenLabs API error ({e.code}): {error_body}")

        # Convert MP3 to WAV for consistent processing
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            tmpfile_wav = f.name

        subprocess.run(
            ["sox", tmpfile_mp3, tmpfile_wav],
            capture_output=True,
            timeout=30
        )

        # Cleanup MP3
        try:
            os.unlink(tmpfile_mp3)
        except Exception:
            pass

        duration = get_audio_duration(tmpfile_wav)
        return tmpfile_wav, duration

    def generate_audio(self, text: str, backend: Optional[TTSBackend] = None) -> Tuple[str, float]:
        """
        Generate TTS audio file using configured backend

        Args:
            text: Text to synthesize
            backend: Override backend for this call (optional)

        Returns:
            Tuple of (audio_file_path, duration_seconds)
        """
        use_backend = backend or self.backend

        if use_backend == TTSBackend.ELEVENLABS:
            return self._generate_elevenlabs(text)
        else:
            return self._generate_piper(text)

    def play_audio_sync(self, audio_path: str):
        """
        Play audio with real-time mouth sync

        Args:
            audio_path: Path to audio file to play
        """
        # Convert to 48kHz stereo for playback device
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            converted_file = f.name

        # Convert audio for playback (sox handles this)
        subprocess.Popen(
            f"sox {audio_path} -r 48000 -c 2 -t wav {converted_file}",
            shell=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        ).wait()

        # Start face sync in background
        self.analyzer.start_sync_thread(
            audio_path,
            self._update_face_mouth,
            update_rate=self.sync_rate
        )

        # Play audio (blocking)
        subprocess.run(
            f"aplay -D {self.play_device} -q {converted_file}",
            shell=True,
            capture_output=True,
            timeout=60
        )

        # Stop sync and ensure mouth closes
        self.analyzer.stop_sync()
        self._update_face_mouth(0.0, {})

        # Cleanup
        try:
            os.unlink(converted_file)
        except Exception:
            pass

    def speak(self,
              text: str,
              state_before: str = "talking",
              state_after: str = "idle",
              bg_mode: Optional[str] = "talking",
              source: Optional[str] = None,
              backend: Optional[TTSBackend] = None):
        """
        Speak text with synchronized face animation

        Args:
            text: Text to speak
            state_before: Face state during speech (default: "talking")
            state_after: Face state after speech (default: "idle")
            bg_mode: Background mode during speech
            source: Source indicator ("cloud", "local", or None)
            backend: Override TTS backend for this call
        """
        use_backend = backend or self.backend

        # Auto-set source based on backend if not specified
        if source is None:
            source = "cloud" if use_backend == TTSBackend.ELEVENLABS else "local"

        # Set face to talking state
        self._set_face_state(state_before, bg_mode, source)

        backend_name = use_backend.value
        print(f"  [TTS:{backend_name}] Generating audio...", flush=True)

        try:
            audio_file, duration = self.generate_audio(text, use_backend)
            print(f"  [TTS:{backend_name}] Duration: {duration:.2f}s", flush=True)

            # Play with lip-sync
            print(f"  [TTS:{backend_name}] Playing with lip-sync...", flush=True)
            self.play_audio_sync(audio_file)

            # Cleanup
            try:
                os.unlink(audio_file)
            except Exception:
                pass

        except Exception as e:
            print(f"  [TTS:{backend_name}] Error: {e}", flush=True)
            # Fallback to Piper if ElevenLabs fails
            if use_backend == TTSBackend.ELEVENLABS:
                print("  [TTS] Falling back to Piper...", flush=True)
                audio_file, duration = self._generate_piper(text)
                self.play_audio_sync(audio_file)
                try:
                    os.unlink(audio_file)
                except Exception:
                    pass

        # Return to idle state
        self._set_face_state(state_after, "default", None)
        print("  [TTS] Done", flush=True)

    def speak_with_emotion(self,
                          text: str,
                          emotion: str = "neutral",
                          source: Optional[str] = None,
                          backend: Optional[TTSBackend] = None):
        """
        Speak with emotion-appropriate facial expression

        Args:
            text: Text to speak
            emotion: Emotion type (neutral, happy, excited, thoughtful)
            source: Source indicator ("cloud", "local", or None)
            backend: Override TTS backend for this call
        """
        # Map emotions to face states and backgrounds
        emotion_mapping = {
            "neutral": ("talking", "talking"),
            "happy": ("happy", "talking"),
            "excited": ("excited", "excited"),
            "thoughtful": ("thinking", "default"),
            "confused": ("confused", "default"),
            "sad": ("sad", "default"),
        }

        state, bg = emotion_mapping.get(emotion, ("talking", "talking"))

        # Speak with appropriate expression
        self.speak(text, state_before=state, state_after="idle",
                  bg_mode=bg, source=source, backend=backend)

    def speak_story(self, text: str, emotion: str = "neutral"):
        """
        Speak in storytelling mode (always uses ElevenLabs for quality)

        Args:
            text: Story text to speak
            emotion: Emotion for facial expression
        """
        self.speak_with_emotion(text, emotion, backend=TTSBackend.ELEVENLABS)

    def speak_quick(self, text: str, emotion: str = "neutral"):
        """
        Speak in quick response mode (always uses Piper for speed)

        Args:
            text: Text to speak
            emotion: Emotion for facial expression
        """
        self.speak_with_emotion(text, emotion, backend=TTSBackend.PIPER)


def main():
    """Test TTS sync with Piper backend"""

    # Image-build paths (see manifest.yml for asset pins)
    PIPER_PATH = Path("/opt/arlowe/runtime/tts/bin/piper")
    PIPER_MODEL = Path("/opt/arlowe/models/piper-voices/en_US-lessac-medium.onnx")

    # Create TTS engine (defaults to Piper)
    tts = TTSWithSync(PIPER_PATH, PIPER_MODEL)

    print("\n" + "=" * 60)
    print("Testing Piper (local, fast)")
    print("=" * 60)
    tts.speak_quick("Hello! This is Piper, the fast local voice.", "neutral")

    time.sleep(1)

    # Check if ElevenLabs is configured
    config = load_elevenlabs_config()
    if config.get("api_key"):
        print("\n" + "=" * 60)
        print("Testing ElevenLabs (cloud, quality)")
        print("=" * 60)
        tts.speak_story("Hello! This is ElevenLabs, the high quality cloud voice.", "happy")
    else:
        print("\nElevenLabs not configured - skipping cloud test")
        print("  Set ELEVENLABS_API_KEY or add tts.elevenlabs.api_key to /etc/arlowe/config.yml")

    print("\nTTS sync test complete!")


if __name__ == "__main__":
    main()
