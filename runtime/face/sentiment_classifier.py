#!/usr/bin/env python3
"""
Sentiment Classifier for Arlowe face service.
Uses local NPU (Qwen model) for real-time sentiment analysis.
Maps sentiment to facial expressions.
"""
import json
import os
import urllib.request
import urllib.error
from enum import Enum
from pathlib import Path
from typing import Tuple, Optional

# Resolved per ADR-0001 §Resolution (option-2, plan 13): query ax-llm
# native OpenAI surface on :8000 directly. The openai_wrapper.py shim is gone.
QWEN_URL = "http://localhost:8000/v1/chat/completions"

# Load order: /etc/arlowe/config.yml (post-pairing overlay, Phase 4),
# falling back to <state>/whisplay-config.json for dev.
# During Phase 1 we accept the fallback path; Phase 4 wires the overlay.
CONFIG_OVERLAY = Path(os.environ.get("ARLOWE_CONFIG_PATH", "/etc/arlowe/config.yml"))
CONFIG_PATH = Path(os.environ.get("ARLOWE_STATE_DIR", "/var/lib/arlowe/state")) / "whisplay-config.json"


class Sentiment(Enum):
    """Sentiment categories"""
    POSITIVE = "positive"
    NEGATIVE = "negative"
    NEUTRAL = "neutral"
    UNKNOWN = "unknown"


# Default sentiment-to-expression mapping
DEFAULT_MAPPING = {
    "positive": ["happy", "excited"],
    "negative": ["concerned", "sad"],
    "neutral": ["idle", "attentive"]
}

# Map "concerned" and "attentive" to valid face states
EXPRESSION_TO_STATE = {
    "happy": "happy",
    "excited": "excited",
    "concerned": "confused",  # closest valid state
    "sad": "sad",
    "idle": "idle",
    "attentive": "thinking"  # closest valid state for attentive
}


def load_config() -> dict:
    """Load configuration file with sentiment-to-expression mapping.

    Returns DEFAULT_MAPPING if neither config path exists or is unreadable.
    This is the expected state during Phase 1 / pre-pairing.
    """
    for path in (CONFIG_OVERLAY, CONFIG_PATH):
        if path.exists():
            try:
                with open(path) as f:
                    config = json.load(f)
                    return config.get("sentiment_mapping", DEFAULT_MAPPING)
            except Exception as e:
                print(f"  [sentiment] Config load error ({path}): {e}, using defaults", flush=True)
    return DEFAULT_MAPPING


def save_config(mapping: dict):
    """Save sentiment-to-expression mapping to config.

    Writes to CONFIG_PATH (/var/lib/arlowe/...). Silently skips if the
    directory cannot be created (e.g., read-only filesystem in Phase 1).
    """
    try:
        CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)

        # Load existing config or create new
        if CONFIG_PATH.exists():
            try:
                with open(CONFIG_PATH) as f:
                    config = json.load(f)
            except Exception:
                config = {}
        else:
            config = {}

        config["sentiment_mapping"] = mapping

        with open(CONFIG_PATH, "w") as f:
            json.dump(config, f, indent=2)
        print(f"  [sentiment] Config saved to {CONFIG_PATH}", flush=True)
    except Exception as e:
        print(f"  [sentiment] Config save error: {e}", flush=True)


def classify_sentiment_npu(text: str, timeout: float = 5.0) -> Tuple[Sentiment, float]:
    """
    Classify sentiment using local NPU (Qwen model).
    Returns (sentiment, confidence).

    Uses a simple prompt to get sentiment classification from the local model.
    Fast and efficient for real-time expression selection.
    """
    try:
        # Craft a prompt that returns sentiment classification
        # Use a constrained format to make parsing reliable
        prompt = f"""Analyze the sentiment of this text and respond with ONLY ONE WORD:
- "positive" if the sentiment is happy, excited, joyful, enthusiastic, or optimistic
- "negative" if the sentiment is sad, angry, frustrated, concerned, or pessimistic
- "neutral" if the sentiment is neither positive nor negative, or factual

Text: "{text}"

Sentiment:"""

        data = json.dumps({
            "model": "qwen2.5-1.5b-instruct",
            "messages": [
                {"role": "user", "content": prompt}
            ],
            "max_tokens": 10,  # We only need one word
            "temperature": 0.1  # Low temperature for consistent classification
        }).encode()

        req = urllib.request.Request(
            QWEN_URL,
            data=data,
            headers={"Content-Type": "application/json"}
        )

        with urllib.request.urlopen(req, timeout=timeout) as resp:
            result = json.loads(resp.read().decode())
            if "choices" in result and len(result["choices"]) > 0:
                content = result["choices"][0].get("message", {}).get("content", "").strip().lower()

                # Parse response - look for sentiment keywords
                if "positive" in content:
                    return Sentiment.POSITIVE, 0.8
                elif "negative" in content:
                    return Sentiment.NEGATIVE, 0.8
                elif "neutral" in content:
                    return Sentiment.NEUTRAL, 0.8
                else:
                    # Fallback: try to infer from response
                    if any(word in content for word in ["happy", "joy", "excited", "great", "good"]):
                        return Sentiment.POSITIVE, 0.6
                    elif any(word in content for word in ["sad", "angry", "bad", "upset", "concerned"]):
                        return Sentiment.NEGATIVE, 0.6
                    else:
                        return Sentiment.NEUTRAL, 0.5

        return Sentiment.UNKNOWN, 0.0

    except Exception as e:
        print(f"  [sentiment] NPU classification error: {e}", flush=True)
        return Sentiment.UNKNOWN, 0.0


def classify_sentiment_heuristic(text: str) -> Tuple[Sentiment, float]:
    """
    Fast heuristic-based sentiment classification.
    Fallback when NPU is unavailable or too slow.
    """
    text_lower = text.lower()

    # Positive keywords
    positive_words = [
        "happy", "great", "excellent", "wonderful", "fantastic", "awesome",
        "love", "good", "nice", "thank", "thanks", "exciting", "excited",
        "joy", "yay", "yes", "perfect", "amazing", "brilliant", "cool"
    ]

    # Negative keywords
    negative_words = [
        "sad", "angry", "bad", "terrible", "awful", "hate", "upset",
        "frustrated", "annoying", "wrong", "error", "problem", "broken",
        "disappointed", "worried", "concerned", "unfortunately", "sorry"
    ]

    # Count occurrences
    positive_count = sum(1 for word in positive_words if word in text_lower)
    negative_count = sum(1 for word in negative_words if word in text_lower)

    # Classify based on counts
    if positive_count > negative_count:
        confidence = min(0.7, 0.5 + positive_count * 0.1)
        return Sentiment.POSITIVE, confidence
    elif negative_count > positive_count:
        confidence = min(0.7, 0.5 + negative_count * 0.1)
        return Sentiment.NEGATIVE, confidence
    else:
        return Sentiment.NEUTRAL, 0.5


def classify_sentiment(text: str, use_npu: bool = True, npu_timeout: float = 2.0) -> Tuple[Sentiment, float]:
    """
    Classify sentiment with fallback.

    Args:
        text: Input text to analyze
        use_npu: Whether to use NPU (if False, uses heuristic only)
        npu_timeout: Timeout for NPU request in seconds

    Returns:
        (Sentiment, confidence) tuple
    """
    if not text or not text.strip():
        return Sentiment.NEUTRAL, 0.0

    # Try NPU first if enabled
    if use_npu:
        sentiment, confidence = classify_sentiment_npu(text, npu_timeout)
        if sentiment != Sentiment.UNKNOWN:
            print(f"  [sentiment] NPU: {sentiment.value} ({confidence:.2f})", flush=True)
            return sentiment, confidence

    # Fallback to heuristic
    sentiment, confidence = classify_sentiment_heuristic(text)
    print(f"  [sentiment] Heuristic: {sentiment.value} ({confidence:.2f})", flush=True)
    return sentiment, confidence


def sentiment_to_expression(sentiment: Sentiment, config: Optional[dict] = None) -> str:
    """
    Map sentiment to facial expression.

    Args:
        sentiment: The classified sentiment
        config: Optional custom mapping (loads from file if None)

    Returns:
        Face state name (e.g., "happy", "sad", "idle")
    """
    if config is None:
        config = load_config()

    # Get list of expressions for this sentiment
    expressions = config.get(sentiment.value, ["idle"])

    # For now, pick the first expression
    # Future: could add randomization or context-based selection
    expression = expressions[0] if expressions else "idle"

    # Map to valid face state
    state = EXPRESSION_TO_STATE.get(expression, "idle")

    return state


def analyze_and_express(text: str, use_npu: bool = True, config: Optional[dict] = None) -> Tuple[str, Sentiment, float]:
    """
    Analyze sentiment and return appropriate facial expression.

    Args:
        text: Input text to analyze
        use_npu: Whether to use NPU for classification
        config: Optional custom mapping

    Returns:
        (expression_state, sentiment, confidence) tuple
    """
    sentiment, confidence = classify_sentiment(text, use_npu=use_npu)
    expression = sentiment_to_expression(sentiment, config)

    return expression, sentiment, confidence


if __name__ == "__main__":
    # Test sentiment classification
    print("Testing Sentiment Classifier\n")

    test_texts = [
        "I'm so happy to see you!",
        "This is terrible and I'm very upset.",
        "The weather is 72 degrees.",
        "I love this new feature, it's amazing!",
        "I'm worried about the system errors.",
        "How are you doing today?",
        "Everything is broken and not working.",
        "That's interesting, tell me more.",
    ]

    print("=== NPU Classification ===")
    for text in test_texts:
        expression, sentiment, confidence = analyze_and_express(text, use_npu=True)
        print(f"Text: {text}")
        print(f"  -> Sentiment: {sentiment.value} ({confidence:.2f})")
        print(f"  -> Expression: {expression}")
        print()

    print("\n=== Heuristic Classification ===")
    for text in test_texts:
        expression, sentiment, confidence = analyze_and_express(text, use_npu=False)
        print(f"Text: {text}")
        print(f"  -> Sentiment: {sentiment.value} ({confidence:.2f})")
        print(f"  -> Expression: {expression}")
        print()

    # Test config save/load
    print("\n=== Config Test ===")
    custom_mapping = {
        "positive": ["excited", "happy"],
        "negative": ["sad", "concerned"],
        "neutral": ["thinking", "idle"]
    }
    save_config(custom_mapping)
    loaded = load_config()
    print(f"Saved and loaded config: {json.dumps(loaded, indent=2)}")
