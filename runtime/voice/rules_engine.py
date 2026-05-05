"""
Rules Engine Stub
TODO: Replace with full implementation from Issue #156
"""

class RulesEngine:
    """Stub rules engine that does nothing"""
    
    def __init__(self, dashboard_url="http://localhost:3000"):
        self.dashboard_url = dashboard_url
        self.rules = []
    
    def evaluate(self, text, context=None):
        """Evaluate rules against input text - stub returns empty list"""
        return []
    
    def evaluate_voice_input(self, text, current_expression=None):
        """Evaluate voice input against orchestration rules - stub returns empty list"""
        # TODO: Implement actual rule evaluation
        return []
    
    def refresh_rules(self):
        """Refresh rules from dashboard API - stub does nothing"""
        pass

_engine = None

def get_engine(dashboard_url="http://localhost:3000"):
    """Get singleton rules engine instance"""
    global _engine
    if _engine is None:
        _engine = RulesEngine(dashboard_url)
    return _engine
