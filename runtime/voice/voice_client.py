#!/usr/bin/env python3
"""
Arlowe Voice Client (Visual Feedback MVP)

VISUAL FEEDBACK AT EVERY STEP:
- Mic always listening: idle face, black background
- Wake word detected: thinking face, PINK background
- LLM responding successfully: talking face, black background
- LLM failure: sad face, black background

This makes debugging visible - you can SEE where it fails.
"""
import os
import sys
# Dependencies provided by /opt/arlowe/venv/ at runtime; see requirements.txt

import time
import json
import pickle
import subprocess
import tempfile
import urllib.request
import urllib.error
import numpy as np
import wave
import noisereduce as nr
from pathlib import Path
from llm.router import route as llm_route, reset_local
from voice.rules_engine import get_engine
from voice.voice_expression_controller import get_controller
from voice.action_executor import ActionExecutor
from tts.tts_sync import TTSWithSync, TTSBackend
import openwakeword
from openwakeword.model import Model as WakeWordModel
import pyaudio
from face.sentiment_classifier import Sentiment

# Paths
PIPER_PATH = Path("/opt/arlowe/runtime/tts/bin/piper")
PIPER_MODEL = Path("/opt/arlowe/models/piper-voices/en_US-lessac-medium.onnx")
VERIFIER_MODEL = Path("/var/lib/arlowe/wake-word/verifier.pkl")
# TODO(phase-5): Replace plughw:2,0 with config-driven audio device selection.
RECORD_DEVICE = "plughw:2,0"
PLAY_DEVICE = "plughw:2,0"

# Wake word detection thresholds
BASE_THRESHOLD = 0.20
VERIFIER_THRESHOLD = 0.30

# Face control
FACE_API = "http://localhost:8080"

# Orchestration Dashboard
DASHBOARD_URL = "http://localhost:3000"

# Fan control
FAN_PWM = "/sys/class/hwmon/hwmon2/pwm1"

# Logging
LOG_DIR = Path("/var/lib/arlowe/logs/voice")
LOG_DIR.mkdir(parents=True, exist_ok=True)


def log_voice(message: str):
    """Log voice interactions to file"""
    try:
        LOG_DIR.mkdir(exist_ok=True)
        log_file = LOG_DIR / f"voice_{time.strftime('%Y-%m-%d')}.log"
        with open(log_file, "a") as f:
            f.write(f"{time.strftime('%H:%M:%S')} {message}\n")
    except:
        pass


def set_face(state: str, bg: str = None, source: str = "CLEAR"):
    """
    Update face display state, background, and source icon.
    
    States: idle, thinking, listening, talking, sad, happy, surprised, confused
    Backgrounds: default (black), wake (pink), error (dark red), excited (green), talking (blue)
    Source: "cloud", "local", or "CLEAR"/None (hides icon)
    """
    try:
        payload = {"state": state}
        if bg:
            payload["bg"] = bg
        # Always include source - empty string to clear, or "cloud"/"local" to show
        payload["source"] = source if source in ("cloud", "local") else ""
        
        data = json.dumps(payload).encode()
        req = urllib.request.Request(
            f"{FACE_API}/state", data=data,
            headers={"Content-Type": "application/json"}
        )
        urllib.request.urlopen(req, timeout=1)
        extras = []
        if bg: extras.append(f"bg={bg}")
        if source in ("cloud", "local"): extras.append(f"src={source}")
        print(f"  [face] {state}" + (f" ({', '.join(extras)})" if extras else ""), flush=True)
    except Exception as e:
        print(f"  [face error] {e}", flush=True)


def looks_like_question(text: str) -> bool:
    """Check if response ends with a question that expects a reply"""
    text = text.strip().rstrip("☁️🏠 ")
    if text.endswith("?"):
        return True
    question_phrases = [
        "what do you think", "would you like", "do you want",
        "shall i", "should i", "can you tell", "how about",
        "what about", "let me know", "your thoughts",
    ]
    lower = text.lower()
    return any(phrase in lower for phrase in question_phrases)


def strip_for_speech(text: str) -> str:
    """Remove markdown syntax and emojis for natural TTS output"""
    import re
    
    # Remove model indicator emojis
    text = text.replace("☁️", "").replace("🏠", "")
    
    # Remove common emojis (keep the text clean for TTS)
    text = re.sub(r'[\U0001f300-\U0001f9ff\U00002702-\U000027b0\U0000fe0f]', '', text)
    
    # Remove markdown formatting
    text = re.sub(r'\*\*(.+?)\*\*', r'\1', text)  # **bold**
    text = re.sub(r'\*(.+?)\*', r'\1', text)        # *italic*
    text = re.sub(r'__(.+?)__', r'\1', text)        # __underline__
    text = re.sub(r'_(.+?)_', r'\1', text)          # _italic_
    text = re.sub(r'~~(.+?)~~', r'\1', text)        # ~~strikethrough~~
    text = re.sub(r'`(.+?)`', r'\1', text)          # `code`
    text = re.sub(r'```[\s\S]*?```', '', text)      # ```code blocks```
    text = re.sub(r'^#+\s+', '', text, flags=re.MULTILINE)  # # Headers
    text = re.sub(r'^\s*[-*]\s+', '', text, flags=re.MULTILINE)  # - bullet points
    text = re.sub(r'^\s*\d+\.\s+', '', text, flags=re.MULTILINE)  # 1. numbered lists
    text = re.sub(r'\[(.+?)\]\(.+?\)', r'\1', text)  # [links](url)
    text = re.sub(r'>\s+', '', text)                  # > blockquotes
    
    # Clean up whitespace
    text = re.sub(r'\n{2,}', '. ', text)  # Multiple newlines to period
    text = re.sub(r'\n', ' ', text)       # Single newlines to space
    text = re.sub(r'\s{2,}', ' ', text)   # Multiple spaces
    
    return text.strip()


def fan_off():
    """Turn off NPU fan for quiet recording"""
    try:
        # TODO(phase-4): sudo from voice service breaks under dedicated arlowe user; needs polkit rule or chgrp on hwmon PWM at boot.
        subprocess.run(f"echo 0 | sudo tee {FAN_PWM}", shell=True, capture_output=True, timeout=2)
        print("  [fan] OFF", flush=True)
    except Exception as e:
        print(f"  [fan error] {e}", flush=True)


def fan_on():
    """Restore NPU fan"""
    try:
        # TODO(phase-4): sudo from voice service breaks under dedicated arlowe user; needs polkit rule or chgrp on hwmon PWM at boot.
        subprocess.run(f"echo 75 | sudo tee {FAN_PWM}", shell=True, capture_output=True, timeout=2)
        print("  [fan] ON", flush=True)
    except Exception as e:
        print(f"  [fan error] {e}", flush=True)


# TTS config path
TTS_CONFIG_PATH = Path(__file__).resolve().parent / "tts_config.json"

# Initialize TTS sync engine (global for reuse)
_tts_engine = None

def get_tts_engine():
    """Get or create TTS sync engine"""
    global _tts_engine
    if _tts_engine is None:
        _tts_engine = TTSWithSync(
            PIPER_PATH,
            PIPER_MODEL,
            PLAY_DEVICE,
            FACE_API,
            sync_rate=30
        )
    return _tts_engine


def load_tts_config() -> dict:
    """Load TTS config from dashboard config file"""
    default = {
        "backend": "piper",
        "elevenlabs_voice_id": "EXAVITQu4vr4xnSDxMaL",
        "auto_story_mode": True,
        "story_threshold": 200,
    }
    try:
        if TTS_CONFIG_PATH.exists():
            with open(TTS_CONFIG_PATH) as f:
                return {**default, **json.load(f)}
    except Exception as e:
        print(f"  [TTS] Config load error: {e}", flush=True)
    return default


def speak(text: str, source: str = None):
    """
    Text to speech with real-time lip-sync and hybrid backend support
    
    Args:
        text: Text to speak
        source: Source indicator ("cloud", "local", or None)
    """
    tts = get_tts_engine()
    config = load_tts_config()
    
    # Determine which backend to use
    backend = TTSBackend.PIPER
    if config["backend"] == "elevenlabs":
        backend = TTSBackend.ELEVENLABS
        print(f"  [TTS] Using ElevenLabs (configured)", flush=True)
    elif config["auto_story_mode"] and len(text) > config["story_threshold"]:
        # Auto-switch to ElevenLabs for longer responses
        backend = TTSBackend.ELEVENLABS
        print(f"  [TTS] Auto story mode: {len(text)} chars > {config['story_threshold']}", flush=True)
    
    # Update ElevenLabs voice if configured
    if config.get("elevenlabs_voice_id"):
        tts.set_elevenlabs_voice(config["elevenlabs_voice_id"])
    
    # Auto-set source based on backend if not specified
    if source is None:
        source = "cloud" if backend == TTSBackend.ELEVENLABS else "local"
    
    tts.speak(text, state_before="talking", state_after="idle", 
              bg_mode="talking", source=source, backend=backend)


def record_audio(duration: float = 5.0) -> str:
    """Record audio from microphone"""
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        tmpfile = f.name
    
    time.sleep(0.2)  # Brief pause after wake word
    
    subprocess.run([
        "arecord", "-D", RECORD_DEVICE, "-f", "S16_LE",
        "-r", "16000", "-c", "1", "-d", str(int(duration)), tmpfile
    ], capture_output=True, timeout=duration + 5)
    
    return tmpfile


def reduce_noise(audio_path: str) -> str:
    """Apply noise reduction to recorded audio, returns path to cleaned file"""
    try:
        # Read the WAV file
        with wave.open(audio_path, 'rb') as wf:
            sample_rate = wf.getframerate()
            n_channels = wf.getnchannels()
            audio_bytes = wf.readframes(wf.getnframes())
        
        audio_data = np.frombuffer(audio_bytes, dtype=np.int16).astype(np.float32)
        
        # Apply noise reduction (stationary noise like fans)
        reduced = nr.reduce_noise(
            y=audio_data,
            sr=sample_rate,
            stationary=True,  # Fan noise is stationary
            prop_decrease=0.8  # Aggressive reduction
        )
        
        # Write cleaned audio
        cleaned_path = audio_path.replace(".wav", "_clean.wav")
        reduced_int = reduced.astype(np.int16)
        with wave.open(cleaned_path, 'wb') as wf:
            wf.setnchannels(n_channels)
            wf.setsampwidth(2)
            wf.setframerate(sample_rate)
            wf.writeframes(reduced_int.tobytes())
        
        print("  [noise] Reduced", flush=True)
        return cleaned_path
    except Exception as e:
        print(f"  [noise error] {e}", flush=True)
        return audio_path  # Fall back to original


def transcribe(audio_path: str) -> str:
    """Transcribe audio using local STT server"""
    try:
        with open(audio_path, "rb") as f:
            audio_data = f.read()
        
        req = urllib.request.Request(
            "http://localhost:8082/transcribe",
            data=audio_data,
            headers={"Content-Type": "application/octet-stream"}
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            result = json.loads(resp.read().decode())
            return result.get("text", "").strip()
    except Exception as e:
        print(f"  [STT error] {e}", flush=True)
        return ""


def main_loop():
    """Main voice client loop with visual feedback"""
    print("=" * 50, flush=True)
    print("🎤 ARLOWE VOICE CLIENT", flush=True)
    print("   Visual Feedback MVP", flush=True)
    print("=" * 50, flush=True)
    
    # STEP 1: Load models
    print("\n[1/4] Loading wake word model...", flush=True)
    models = [p for p in openwakeword.get_pretrained_model_paths() if 'jarvis' in p]
    oww_model = WakeWordModel(wakeword_model_paths=models)
    print(f"  Loaded: {models[0]}", flush=True)
    
    print("\n[2/4] Loading verifier...", flush=True)
    with open(VERIFIER_MODEL, 'rb') as f:
        verifier = pickle.load(f)
    print(f"  Loaded: {VERIFIER_MODEL}", flush=True)
    
    print("\n[3/4] Opening audio stream...", flush=True)
    pa = pyaudio.PyAudio()
    device_index = 0
    for i in range(pa.get_device_count()):
        info = pa.get_device_info_by_index(i)
        if info['maxInputChannels'] > 0:
            device_index = i
            print(f"  Device: {info['name']}", flush=True)
            break
    
    stream = pa.open(
        format=pyaudio.paInt16,
        channels=1,
        rate=16000,
        input=True,
        frames_per_buffer=1280,
        input_device_index=device_index
    )
    
    # Initialize orchestration rules engine
    print("\n[4/5] Initializing rules engine...", flush=True)
    rules_engine = get_engine(DASHBOARD_URL)
    action_executor = ActionExecutor(set_face_func=set_face, speak_func=speak)
    print(f"  Dashboard: {DASHBOARD_URL}", flush=True)
    
    # Initialize voice expression controller
    print("\n[5/5] Initializing voice expression controller...", flush=True)
    voice_expr = get_controller(FACE_API)
    print(f"  Config loaded with {len(voice_expr.get_config().get('mappings', {}))} event mappings", flush=True)
    
    # Ready state
    set_face("idle", "default")
    speak("Voice client ready. Say hey arlowe to talk to me.")
    print("\n" + "=" * 50, flush=True)
    print("🎤 LISTENING FOR WAKE WORD", flush=True)
    print("   Say 'Hey Arlowe' to start", flush=True)
    print("=" * 50, flush=True)
    set_face("idle", "default")
    
    try:
        while True:
            # Read audio chunk
            audio_chunk = np.frombuffer(
                stream.read(1280, exception_on_overflow=False), 
                dtype=np.int16
            )
            
            # Check for wake word
            prediction = oww_model.predict(audio_chunk)
            
            for model_name, base_score in prediction.items():
                if base_score > BASE_THRESHOLD:
                    # Get verifier score
                    features = oww_model.preprocessor.get_features(oww_model.model_inputs[model_name])
                    verifier_score = verifier.predict_proba([features.flatten()])[0][1]
                    
                    # Log all attempts above base threshold
                    if verifier_score > 0.20:
                        status = "✓ WAKE" if verifier_score > VERIFIER_THRESHOLD else "✗ miss"
                        print(f"  [{status}] base:{base_score:.2f} verify:{verifier_score:.2f}", flush=True)
                    
                    if verifier_score > VERIFIER_THRESHOLD:
                        # ====== WAKE WORD DETECTED ======
                        # Close stream to free device for recording
                        stream.stop_stream()
                        stream.close()
                        
                        print("\n" + "=" * 50, flush=True)
                        print(f"🔔 WAKE DETECTED (v:{verifier_score:.2f})", flush=True)
                        log_voice(f"🔔 Wake word (score: {verifier_score:.2f})")
                        
                        # VISUAL: Pink background + listening (ears open!), clear any icon
                        voice_expr.wake_word()  # Trigger wake word expression event
                        set_face("listening", "wake", None)
                        
                        # ====== RECORD ======
                        fan_off()  # Quiet the fan for better recording
                        print("🎙️ Recording 5s...", flush=True)
                        voice_expr.listening_start()  # Trigger listening event
                        audio_file = record_audio(5)
                        fan_on()  # Restore fan
                        
                        # ====== NOISE REDUCTION ======
                        print("🔇 Reducing noise...", flush=True)
                        voice_expr.listening_end()  # Trigger listening end event
                        set_face("thinking", "wake", None)
                        cleaned_file = reduce_noise(audio_file)
                        
                        # ====== TRANSCRIBE ======
                        print("🧠 Transcribing...", flush=True)
                        text = transcribe(cleaned_file)
                        
                        # Clean up audio files
                        os.unlink(audio_file)
                        if cleaned_file != audio_file:
                            os.unlink(cleaned_file)
                        
                        if text:
                            print(f"📝 Heard: \"{text}\"", flush=True)
                            log_voice(f"🎤 Heard: {text}")
                            
                            # ====== ORCHESTRATION RULES ======
                            # Check if any orchestration rules match the input
                            print("🎯 Evaluating orchestration rules...", flush=True)
                            matched_actions = rules_engine.evaluate_voice_input(text, current_expression="listening")
                            
                            if matched_actions:
                                print(f"  [rules] Executing {len(matched_actions)} action(s)", flush=True)
                                action_executor.execute_actions(matched_actions)
                                log_voice(f"🎯 Executed {len(matched_actions)} rule action(s)")
                                # Note: Rules can trigger TTS/expressions, but IOL routing still continues
                            
                            # ====== IOL ROUTING ======
                            # Route to local Qwen or cloud Claude with sentiment analysis
                            print("🧠 IOL routing...", flush=True)
                            response, success, source, model, expression, sentiment, confidence = llm_route(text)
                            
                            # Set face based on sentiment (before processing response)
                            set_face(expression, "excited", None)
                            
                            if success:
                                # ====== SUCCESS: Talk ======
                                print(f"💬 Response ({source}/{model}): \"{response}\"", flush=True)
                                print(f"😊 Sentiment: {sentiment.value} ({confidence:.2f}) → {expression}", flush=True)
                                log_voice(f"🔊 Response ({source}|{model}): {response}")
                                log_voice(f"😊 Sentiment: {sentiment.value} ({confidence:.2f}) → {expression}")
                                
                                # Strip markdown/emoji for TTS, show icon on display
                                spoken_text = strip_for_speech(response)
                                voice_expr.speaking_start(source=source)  # Trigger speaking event
                                set_face("talking", "talking", source)  # Blue bg + cloud/home icon
                                speak(spoken_text, source=source)  # Speak with lip-sync
                                voice_expr.speaking_end(source=source)  # Trigger speaking end event
                                
                                # ====== FOLLOW-UP LISTENING ======
                                # If response was a question, listen for a reply
                                if looks_like_question(response):
                                    print("❓ Response was a question — listening for follow-up...", flush=True)
                                    set_face("listening", "wake", None)
                                    log_voice("❓ Waiting for follow-up response")
                                    
                                    # Record for follow-up (10 seconds)
                                    fan_off()
                                    audio_file = record_audio(10)
                                    fan_on()
                                    
                                    # Noise reduce + transcribe
                                    set_face("thinking", "wake", None)
                                    cleaned_file = reduce_noise(audio_file)
                                    follow_up = transcribe(cleaned_file)
                                    os.unlink(audio_file)
                                    if cleaned_file != audio_file:
                                        os.unlink(cleaned_file)
                                    
                                    if follow_up:
                                        print(f"📝 Follow-up: \"{follow_up}\"", flush=True)
                                        log_voice(f"🎤 Follow-up: {follow_up}")
                                        
                                        response2, success2, source2, model2, expression2, sentiment2, confidence2 = llm_route(follow_up)
                                        
                                        # Set face based on follow-up sentiment
                                        set_face(expression2, "excited", None)
                                        print(f"😊 Follow-up sentiment: {sentiment2.value} ({confidence2:.2f}) → {expression2}", flush=True)
                                        
                                        if success2:
                                            spoken2 = strip_for_speech(response2)
                                            set_face("talking", "talking", source2)
                                            speak(spoken2, source=source2)  # Speak with lip-sync
                                        else:
                                            set_face("sad", "default", None)
                                            speak(strip_for_speech(response2))  # No source for error
                                    else:
                                        print("  [follow-up] No response heard, returning to idle", flush=True)
                            else:
                                # ====== FAILURE: Sad ======
                                print(f"❌ Failed: \"{response}\"", flush=True)
                                log_voice(f"❌ Error: {response}")
                                voice_expr.error()  # Trigger error event
                                set_face("sad", "default", None)
                                speak(strip_for_speech(response))
                                time.sleep(1)
                        else:
                            # ====== NO SPEECH: Confused ======
                            print("❌ No speech detected", flush=True)
                            log_voice("❌ No speech detected")
                            voice_expr.confused()  # Trigger confused event
                            set_face("confused", "default", None)
                            speak("I didn't catch that.")
                            time.sleep(1)
                        
                        # ====== BACK TO LISTENING ======
                        # Reset local LLM KV cache between conversations
                        reset_local()
                        oww_model.reset()
                        stream = pa.open(
                            format=pyaudio.paInt16,
                            channels=1,
                            rate=16000,
                            input=True,
                            frames_per_buffer=1280,
                            input_device_index=device_index
                        )
                        print("\n" + "=" * 50, flush=True)
                        print("🎤 LISTENING FOR WAKE WORD", flush=True)
                        print("=" * 50, flush=True)
                        set_face("idle", "default", None)  # Clear source icon
                        
    except KeyboardInterrupt:
        print("\n\nShutting down...", flush=True)
    finally:
        stream.close()
        pa.terminate()
        set_face("sleeping", "default")


if __name__ == "__main__":
    main_loop()
