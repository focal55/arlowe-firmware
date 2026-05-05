#!/usr/bin/env python3
"""
Voice Expression Controller
Manages automatic face expression changes based on voice activity
"""
import json
import time
import threading
import urllib.request
from pathlib import Path
from typing import Optional, Dict, Any
from dataclasses import dataclass

@dataclass
class ExpressionChange:
    """Represents a scheduled expression change"""
    expression: str
    background: Optional[str] = None
    source: Optional[str] = None
    timestamp: float = 0
    duration_ms: Optional[int] = None


class VoiceExpressionController:
    """
    Controls face expressions based on voice activity events.
    Provides configurable mapping between voice states and expressions.
    """
    
    def __init__(self, config_path: Optional[str] = None, face_api: str = "http://localhost:8080"):
        """
        Initialize the controller
        
        Args:
            config_path: Path to voice_expression_config.json (defaults to same directory)
            face_api: Base URL for face API
        """
        self.face_api = face_api
        self.config_path = config_path or str(Path(__file__).parent / "voice_expression_config.json")
        self.config = self._load_config()
        self.current_source: Optional[str] = None
        self._pending_changes = []
        self._lock = threading.Lock()
        self._timer_thread = None
        self._enabled = True
        
    def _load_config(self) -> Dict[str, Any]:
        """Load configuration from JSON file"""
        try:
            with open(self.config_path, 'r') as f:
                return json.load(f)
        except Exception as e:
            print(f"[VoiceExpression] Failed to load config: {e}", flush=True)
            # Return minimal default config
            return {
                "mappings": {},
                "defaults": {
                    "idle_expression": "idle",
                    "idle_background": "default"
                }
            }
    
    def reload_config(self):
        """Reload configuration from file (for dashboard updates)"""
        self.config = self._load_config()
        print(f"[VoiceExpression] Config reloaded", flush=True)
    
    def set_enabled(self, enabled: bool):
        """Enable or disable automatic expression changes"""
        self._enabled = enabled
        print(f"[VoiceExpression] {'Enabled' if enabled else 'Disabled'}", flush=True)
    
    def get_config(self) -> Dict[str, Any]:
        """Get current configuration"""
        return self.config.copy()
    
    def update_config(self, new_config: Dict[str, Any]):
        """Update configuration and save to file"""
        self.config = new_config
        try:
            with open(self.config_path, 'w') as f:
                json.dump(new_config, f, indent=2)
            print(f"[VoiceExpression] Config updated", flush=True)
        except Exception as e:
            print(f"[VoiceExpression] Failed to save config: {e}", flush=True)
    
    def _set_face(self, expression: str, background: Optional[str] = None, 
                  source: Optional[str] = None, clear_source: bool = False):
        """
        Send face state change to face service
        
        Args:
            expression: Face expression state
            background: Background mode (optional)
            source: Source indicator "cloud", "local", or None
            clear_source: If True, explicitly clear the source indicator
        """
        try:
            payload = {"state": expression}
            
            if background:
                payload["bg"] = background
            
            # Handle source indicator
            if clear_source:
                payload["source"] = ""  # Empty string clears the icon
            elif source:
                payload["source"] = source
            elif self.current_source:
                payload["source"] = self.current_source
            
            data = json.dumps(payload).encode()
            req = urllib.request.Request(
                f"{self.face_api}/state",
                data=data,
                headers={"Content-Type": "application/json"}
            )
            urllib.request.urlopen(req, timeout=1)
            
            # Build debug message
            parts = [f"{expression}"]
            if background:
                parts.append(f"bg={background}")
            if source or self.current_source:
                parts.append(f"src={source or self.current_source}")
            print(f"[VoiceExpression] {' | '.join(parts)}", flush=True)
            
        except Exception as e:
            print(f"[VoiceExpression] Failed to set face: {e}", flush=True)
    
    def set_source(self, source: Optional[str]):
        """
        Set the current source indicator (cloud/local)
        This persists across expression changes unless explicitly cleared
        """
        self.current_source = source
    
    def trigger_event(self, event: str, source: Optional[str] = None, **kwargs):
        """
        Trigger a voice activity event and change expression accordingly
        
        Args:
            event: Event name (e.g., "speaking_start", "listening_start")
            source: Optional source indicator ("cloud" or "local")
            **kwargs: Additional parameters (reserved for future use)
        """
        if not self._enabled:
            return
        
        # Update source if provided
        if source is not None:
            self.current_source = source
        
        # Get mapping for this event
        mapping = self.config.get("mappings", {}).get(event)
        
        if not mapping:
            print(f"[VoiceExpression] No mapping for event: {event}", flush=True)
            return
        
        expression = mapping.get("expression")
        background = mapping.get("background")
        duration_ms = mapping.get("duration_ms")
        
        if not expression:
            print(f"[VoiceExpression] No expression defined for event: {event}", flush=True)
            return
        
        # Apply expression change
        self._set_face(expression, background, self.current_source)
        
        # Schedule return to idle if duration is specified
        if duration_ms:
            self._schedule_idle_return(duration_ms / 1000.0)
    
    def _schedule_idle_return(self, delay_seconds: float):
        """Schedule a return to idle expression after a delay"""
        def return_to_idle():
            time.sleep(delay_seconds)
            defaults = self.config.get("defaults", {})
            idle_expr = defaults.get("idle_expression", "idle")
            idle_bg = defaults.get("idle_background", "default")
            self._set_face(idle_expr, idle_bg, clear_source=True)
        
        # Cancel any existing timer
        if self._timer_thread and self._timer_thread.is_alive():
            # Can't cancel easily, but new timer will override
            pass
        
        self._timer_thread = threading.Thread(target=return_to_idle, daemon=True)
        self._timer_thread.start()
    
    def speaking_start(self, source: Optional[str] = None):
        """Convenience: Trigger speaking start event"""
        self.trigger_event("speaking_start", source=source)
    
    def speaking_end(self, source: Optional[str] = None):
        """Convenience: Trigger speaking end event"""
        self.trigger_event("speaking_end", source=source)
    
    def listening_start(self):
        """Convenience: Trigger listening start event"""
        self.trigger_event("listening_start")
    
    def listening_end(self):
        """Convenience: Trigger listening end event"""
        self.trigger_event("listening_end")
    
    def thinking_start(self):
        """Convenience: Trigger thinking start event"""
        self.trigger_event("thinking_start")
    
    def thinking_end(self):
        """Convenience: Trigger thinking end event"""
        self.trigger_event("thinking_end")
    
    def error(self):
        """Convenience: Trigger error event"""
        self.trigger_event("error")
    
    def wake_word(self):
        """Convenience: Trigger wake word event"""
        self.trigger_event("wake_word")
    
    def success(self):
        """Convenience: Trigger success event"""
        self.trigger_event("success")
    
    def confused(self):
        """Convenience: Trigger confused event"""
        self.trigger_event("confused")


# Global singleton instance
_controller_instance: Optional[VoiceExpressionController] = None


def get_controller(face_api: str = "http://localhost:8080") -> VoiceExpressionController:
    """Get or create the global controller instance"""
    global _controller_instance
    if _controller_instance is None:
        _controller_instance = VoiceExpressionController(face_api=face_api)
    return _controller_instance


if __name__ == "__main__":
    # Demo usage
    print("Voice Expression Controller Demo")
    controller = VoiceExpressionController()
    
    print("\nCurrent config:")
    print(json.dumps(controller.get_config(), indent=2))
    
    print("\n\nTriggering events (5 second sequence):")
    
    controller.wake_word()
    time.sleep(1)
    
    controller.listening_start()
    time.sleep(1)
    
    controller.thinking_start()
    time.sleep(1)
    
    controller.speaking_start(source="cloud")
    time.sleep(2)
    
    controller.speaking_end()
    print("\nDemo complete!")
