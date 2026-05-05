#!/usr/bin/env python3
"""
Arlowe Face Service
HTTP control interface + animated face display
"""
import sys
import os
import json
import threading
import time
from http.server import HTTPServer, BaseHTTPRequestHandler

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from .face import ArloweeFace, State

# Global face instance
face = None

# Current source indicator (cloud/local/none)
current_source = None

class ControlHandler(BaseHTTPRequestHandler):
    """HTTP handler for face control"""

    def log_message(self, format, *args):
        pass  # Quiet logging

    def do_GET(self):
        if self.path == '/status':
            self._json_response({
                'state': face.state.state.value if face else 'stopped',
                'running': face.running if face else False,
                'source': current_source
            })
        elif self.path == '/':
            self._html_response()
        else:
            self.send_error(404)

    def do_POST(self):
        global current_source
        if self.path == '/voice-expression/reload':
            # Reload voice expression configuration
            # This endpoint is called by the dashboard when config is updated
            try:
                self._json_response({'ok': True, 'message': 'Reload signal received'})
            except Exception as e:
                self._json_response({'ok': False, 'error': str(e)}, 500)
        elif self.path == '/state':
            length = int(self.headers.get('Content-Length', 0))
            data = json.loads(self.rfile.read(length)) if length else {}
            state_name = data.get('state', 'idle')
            bg_mode = data.get('bg')  # Optional background mode
            source = data.get('source')  # Optional: "cloud" or "local"

            try:
                new_state = State(state_name)
                if face:
                    face.set_state(new_state)
                    if bg_mode:
                        face.set_bg_mode(bg_mode)
                    # Always update source if the key is present (even if None/null)
                    if 'source' in data:
                        current_source = source
                        face.set_source(source if source else "")  # Pass empty string to clear
                    self._json_response({'ok': True, 'state': state_name, 'bg': bg_mode, 'source': source})
                else:
                    self._json_response({'ok': False, 'error': 'Face not running'}, 500)
            except ValueError:
                self._json_response({'ok': False, 'error': f'Unknown state: {state_name}'}, 400)
        elif self.path == '/mouth':
            # Real-time mouth position update for TTS sync
            length = int(self.headers.get('Content-Length', 0))
            data = json.loads(self.rfile.read(length)) if length else {}
            mouth_open = data.get('open', 0.0)  # 0.0 to 1.0

            if face:
                face.state.mouth_open = max(0.0, min(1.0, mouth_open))
                self._json_response({'ok': True, 'mouth_open': face.state.mouth_open})
            else:
                self._json_response({'ok': False, 'error': 'Face not running'}, 500)
        elif self.path == '/discord':
            # Called when Discord activity happens
            length = int(self.headers.get('Content-Length', 0))
            data = json.loads(self.rfile.read(length)) if length else {}
            activity = data.get('activity', 'message')  # message, thinking, typing

            if face:
                if activity == 'thinking':
                    face.set_state(State.THINKING)
                    face.set_bg_mode("default")
                elif activity == 'message':
                    face.set_state(State.TALKING)
                    face.set_bg_mode("talking")
                    source = data.get('source', 'cloud')
                    face.set_source(source)
                elif activity == 'idle':
                    face.set_state(State.IDLE)
                    face.set_bg_mode("default")
                    face.set_source("")
                self._json_response({'ok': True, 'activity': activity})
            else:
                self._json_response({'ok': False, 'error': 'Face not running'}, 500)
        elif self.path == '/bg':
            length = int(self.headers.get('Content-Length', 0))
            data = json.loads(self.rfile.read(length)) if length else {}
            bg_mode = data.get('mode', 'default')
            if face:
                face.set_bg_mode(bg_mode)
                self._json_response({'ok': True, 'bg': bg_mode})
            else:
                self._json_response({'ok': False, 'error': 'Face not running'}, 500)
        else:
            self.send_error(404)

    def _add_cors_headers(self):
        """Add CORS headers to allow cross-origin requests from dashboard"""
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')

    def do_OPTIONS(self):
        """Handle CORS preflight requests"""
        self.send_response(200)
        self._add_cors_headers()
        self.end_headers()

    def _json_response(self, data, code=200):
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self._add_cors_headers()
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def _html_response(self):
        html = '''<!DOCTYPE html>
<html>
<head>
    <title>Arlowe Face Control</title>
    <style>
        body { font-family: system-ui; background: #111; color: #0f0; padding: 20px; }
        button { background: #0f0; color: #111; border: none; padding: 10px 20px;
                 margin: 5px; cursor: pointer; font-size: 16px; }
        button:hover { background: #0c0; }
        .status { margin: 20px 0; font-size: 18px; }
    </style>
</head>
<body>
    <h1>Arlowe Face Control</h1>
    <div class="status">State: <span id="state">loading...</span></div>
    <div>
        <button onclick="setState('idle')">Idle</button>
        <button onclick="setState('thinking')">Thinking</button>
        <button onclick="setState('listening')">Listening</button>
        <button onclick="setState('talking')">Talking</button>
        <button onclick="setState('sleeping')">Sleeping</button>
    </div>
    <script>
        async function setState(s) {
            await fetch('/state', {method:'POST', body:JSON.stringify({state:s})});
            updateStatus();
        }
        async function updateStatus() {
            const r = await fetch('/status');
            const d = await r.json();
            document.getElementById('state').textContent = d.state;
        }
        updateStatus();
        setInterval(updateStatus, 2000);
    </script>
</body>
</html>'''
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.end_headers()
        self.wfile.write(html.encode())


def run_server(port=8080):
    """Run HTTP control server"""
    server = HTTPServer(('0.0.0.0', port), ControlHandler)
    print(f"Face control server on http://localhost:{port}")
    server.serve_forever()


def main():
    global face

    # Start control server in background
    server_thread = threading.Thread(target=run_server, daemon=True)
    server_thread.start()

    # Start face
    face = ArloweeFace()
    face.run(fps=15)  # Lower FPS for service mode


if __name__ == "__main__":
    main()
