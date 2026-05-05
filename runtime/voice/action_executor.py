"""
Action Executor Stub
TODO: Replace with full implementation from Issue #156
"""

class ActionExecutor:
    """Stub action executor that logs but doesn't execute"""
    
    def __init__(self, set_face_func=None, speak_func=None, face_url="http://localhost:8080"):
        self.set_face_func = set_face_func
        self.speak_func = speak_func
        self.face_url = face_url
    
    def execute(self, actions):
        """Execute actions from rules - stub just logs"""
        for action in actions:
            action_type = action.get('type', 'unknown')
            print(f"[action_executor] Would execute: {action_type}")
            
            if action_type == 'set_expression' and self.set_face_func:
                try:
                    self.set_face_func(action.get('expressionId', 'idle'))
                except Exception as e:
                    print(f"[action_executor] Error setting expression: {e}")
            
            elif action_type == 'play_tts' and self.speak_func:
                try:
                    self.speak_func(action.get('text', ''))
                except Exception as e:
                    print(f"[action_executor] Error playing TTS: {e}")
    
    def set_expression(self, expression_id):
        """Set face expression"""
        if self.set_face_func:
            self.set_face_func(expression_id)
        else:
            print(f"[action_executor] Would set expression: {expression_id}")
    
    def play_tts(self, text, voice_id=None):
        """Play TTS"""
        if self.speak_func:
            self.speak_func(text)
        else:
            print(f"[action_executor] Would play TTS: {text[:50]}...")
    
    def send_api(self, url, method="GET", body=None):
        """Send API request - stub"""
        print(f"[action_executor] Would call API: {method} {url}")
