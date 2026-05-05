#!/usr/bin/env python3
"""
Fast STT Server using faster-whisper
Model stays loaded in memory for quick transcription

faster-whisper downloads base.en on first run to ~/.cache/huggingface/.
In the image build, pre-populate /var/lib/arlowe/models/whisper/ to skip the download.
"""
import os
import json
import tempfile
from pathlib import Path
from http.server import HTTPServer, BaseHTTPRequestHandler
from faster_whisper import WhisperModel

# Configuration
HOST = "localhost"
PORT = 8082
MODEL_SIZE = "base.en"  # base.en is more accurate, still fast enough

print(f"Loading Whisper {MODEL_SIZE} model...")
model = WhisperModel(MODEL_SIZE, device="cpu", compute_type="int8")
print("Model loaded!")


class STTHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Suppress request logging

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"status": "ok", "model": MODEL_SIZE}).encode())
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == "/transcribe":
            content_length = int(self.headers.get("Content-Length", 0))
            audio_data = self.rfile.read(content_length)

            # Save to temp file
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
                f.write(audio_data)
                tmpfile = f.name

            try:
                # Transcribe
                segments, info = model.transcribe(
                    tmpfile,
                    beam_size=1,
                    language="en",
                    vad_filter=True,
                    vad_parameters=dict(min_silence_duration_ms=500)
                )
                text = " ".join(seg.text for seg in segments).strip()

                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({
                    "text": text,
                    "language": info.language,
                    "duration": info.duration
                }).encode())
            except Exception as e:
                self.send_response(500)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"error": str(e)}).encode())
            finally:
                os.unlink(tmpfile)
        else:
            self.send_response(404)
            self.end_headers()


if __name__ == "__main__":
    server = HTTPServer((HOST, PORT), STTHandler)
    print(f"STT server listening on http://{HOST}:{PORT}")
    print("Endpoints:")
    print("  GET  /health     - Health check")
    print("  POST /transcribe - Transcribe WAV audio (send raw bytes)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
