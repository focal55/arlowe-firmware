#!/usr/bin/env python3
"""LLM router.

Dispatches between local Qwen (HTTP, on-device) and cloud Claude (subprocess).
Renamed from iol_router.py per ADR-0001 — the "IOL" prefix was historical
residue; this module has no IOL infrastructure dependency.
"""
import re
import json
import os
import shutil
import subprocess
import time
import urllib.request
import urllib.error
from datetime import datetime, timezone
from pathlib import Path
from filelock import FileLock

# Sentiment classifier lives in the sibling face/ package after extraction.
from face.sentiment_classifier import analyze_and_express, Sentiment

# Usage stats file — whisplay local bookkeeping; not shared with any other
# service. Writes to the arlowe state directory instead of the old developer
# workspace location. See ADR-0001. State dir overridable for tests + dev.
_STATE_DIR = Path(os.environ.get("ARLOWE_STATE_DIR", "/var/lib/arlowe/state"))
USAGE_STATS_PATH = _STATE_DIR / "usage-stats.json"
USAGE_LOCK_PATH = USAGE_STATS_PATH.with_suffix(".lock")
# Lazy mkdir — at write time, not import time. Import must not require
# write permission to the state dir (smoke-test runtimes mount /tmp paths).

# Local Qwen API
# Resolved per ADR-0001 §Resolution (option-2, plan 13): point directly at
# ax-llm's native OpenAI-compatible surface on :8000. The intermediate
# openai_wrapper.py shim is no longer in the path; qwen-openai.service is
# scheduled for removal from the systemd unit set in Phase 11.
QWEN_URL = "http://localhost:8000/v1/chat/completions"

# Claude Code CLI (Claude Agent, non-interactive print mode).
# Resolved via ARLOWE_CLAUDE_BIN env var, then PATH lookup, then a
# hard-coded fallback. The fallback will fail-fast at first invocation if
# the binary is absent — that's intentional; we don't want silent no-ops.
# See ADR-0001 for the cloud-path credential story (Phase 7 fix).
CLAUDE_BIN = os.environ.get("ARLOWE_CLAUDE_BIN") or shutil.which("claude") or "/usr/bin/claude"

# Voice model defaults — Haiku 4.5 gives ~1-2s first-token latency and is
# more than capable for 1-2 sentence conversational replies. Override via
# env var for experimentation. Config-knob territory for Phase 4.
VOICE_MODEL = os.environ.get("ARLOWE_VOICE_MODEL", "claude-haiku-4-5")
VOICE_TIMEOUT_SECS = int(os.environ.get("ARLOWE_VOICE_TIMEOUT", "60"))

VOICE_SYSTEM_PROMPT = (
    "You are Arlowe, a friendly, curious voice assistant running on a "
    "Raspberry Pi with a small animated face. You are not a coding "
    "assistant — you are a conversational companion. Respond naturally "
    "to whatever the user says: chit-chat, trivia, jokes, opinions, "
    "feelings, small talk, advice. Keep every reply to 1-2 sentences, "
    "plain speech only — no markdown, no code blocks, no lists, no "
    "headings. Never mention that you are Claude or Claude Code. Never "
    "refuse a casual question by saying you're for software engineering. "
    "If you genuinely can't answer (e.g. you lack real-time data), say "
    "so in one friendly sentence."
)

# DISALLOWED_TOOLS is a defense-in-depth measure: the names listed here are
# Claude Code workforce tools that should never be invoked from the voice path
# even on a dev unit. The list is not load-bearing — it just prevents accidents
# if a customer unit somehow ends up with workforce tooling on PATH.
DISALLOWED_TOOLS = " ".join([
    "Bash", "Edit", "Write", "Read", "Glob", "Grep", "WebFetch", "WebSearch",
    "Agent", "NotebookEdit",
    "TaskCreate", "TaskUpdate", "TaskList", "TaskGet",
    "CronCreate", "CronList", "CronDelete", "RemoteTrigger",
])

# Force mode: "local", "cloud", or None (auto routing)
FORCE_MODE = None  # SET TO "local" or "cloud" FOR TESTING

# Patterns that should go to LOCAL Qwen (simple, factual, quick)
LOCAL_PATTERNS = [
    # Greetings
    r"^(hi|hello|hey|good morning|good night|good evening|goodnight|sup|yo)\b",
    # Simple questions
    r"^what (is|are|was|were)\b",
    r"^who (is|are|was|were)\b",
    r"^where (is|are|was|were)\b",
    r"^when (is|are|was|were|did)\b",
    r"^how (do|does|did|is|are|many|much|old|far|long|tall)\b",
    r"^(define|explain|describe|translate)\b",
    r"^what('s| is) the (weather|time|date|temperature)\b",
    # Math
    r"^what('s| is) \d+",
    r"^\d+\s*[\+\-\*\/\%]\s*\d+",
    # Quick facts
    r"^(tell me|what) (a |an )?(joke|fact|fun fact|story)\b",
    # Yes/no simple
    r"^(is|are|can|do|does|did|will|would|should) ",
    # Conversational
    r"^(thanks|thank you|ok|okay|sure|cool|nice|great|awesome|bye|goodbye|goodnight)\b",
    r"^how are you",
    r"^what('s| is) up",
    r"^(i('m| am)|i was|i have|i had|i think|i feel|i want|i need|i like)\b",
]

# Patterns that MUST go to CLOUD (need tools, memory, or complex reasoning)
CLOUD_PATTERNS = [
    # Actions that need tools
    r"(send|post|message|email|tweet|check|search|look up|find|google)\b",
    r"(create|make|build|write|code|program|develop|implement|deploy|install)\b",
    r"(schedule|remind|alarm|timer|calendar|cron)\b",
    r"(file|folder|directory|git|commit|push|pull|repo)\b",
    # System/project references
    r"(discord|whisplay|axera|npu|service|systemctl)\b",
    r"(project|milestone|task|todo|status|update|progress)\b",
    # Complex reasoning
    r"(compare|analyze|review|evaluate|design|architect|plan|strategy)\b",
    r"(debug|fix|error|broken|not working|issue|problem|troubleshoot)\b",
    # Memory/context
    r"(remember|yesterday|last time|before|earlier|we discussed|you said)\b",
]


def log_usage(provider: str, input_tokens: int = 0, output_tokens: int = 0,
              latency_ms: int = 0, success: bool = True, cost: float = 0.0):
    """
    Log model usage to usage-stats.json.
    Thread-safe via file locking.
    """
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    try:
        # Ensure the state dir exists before FileLock tries to create its lockfile.
        _STATE_DIR.mkdir(parents=True, exist_ok=True)
        lock = FileLock(str(USAGE_LOCK_PATH), timeout=5)
        with lock:
            # Read existing stats
            if USAGE_STATS_PATH.exists():
                with open(USAGE_STATS_PATH) as f:
                    stats = json.load(f)
            else:
                stats = {"version": 1, "daily": {}}

            # Ensure today's entry exists
            if today not in stats.get("daily", {}):
                stats.setdefault("daily", {})[today] = []

            # Find or create provider entry for today
            provider_entry = None
            for entry in stats["daily"][today]:
                if entry.get("provider") == provider:
                    provider_entry = entry
                    break

            if not provider_entry:
                provider_entry = {
                    "provider": provider,
                    "calls": 0,
                    "inputTokens": 0,
                    "outputTokens": 0,
                    "totalLatencyMs": 0,
                    "failures": 0
                }
                if provider in ("anthropic", "google-gemini"):
                    provider_entry["cost"] = 0.0
                stats["daily"][today].append(provider_entry)

            # Update stats
            provider_entry["calls"] = provider_entry.get("calls", 0) + 1
            provider_entry["inputTokens"] = provider_entry.get("inputTokens", 0) + input_tokens
            provider_entry["outputTokens"] = provider_entry.get("outputTokens", 0) + output_tokens
            provider_entry["totalLatencyMs"] = provider_entry.get("totalLatencyMs", 0) + latency_ms
            if not success:
                provider_entry["failures"] = provider_entry.get("failures", 0) + 1
            if cost > 0:
                provider_entry["cost"] = provider_entry.get("cost", 0.0) + cost

            # Update timestamp
            stats["lastUpdated"] = datetime.now(timezone.utc).isoformat()

            # Write back
            USAGE_STATS_PATH.parent.mkdir(parents=True, exist_ok=True)
            with open(USAGE_STATS_PATH, "w") as f:
                json.dump(stats, f, indent=2)

    except Exception as e:
        print(f"  [router] Usage logging failed: {e}", flush=True)


def estimate_tokens(text: str) -> int:
    """Rough token estimate (4 chars per token average)."""
    return max(1, len(text) // 4)


def classify(text: str) -> str:
    """
    Classify query as 'local' or 'cloud'.
    Returns 'local' for simple queries, 'cloud' for complex ones.
    """
    lower = text.lower().strip()

    # Short messages (< 8 words) are more likely simple
    word_count = len(lower.split())

    # Check cloud patterns first (they take priority)
    for pattern in CLOUD_PATTERNS:
        if re.search(pattern, lower):
            return "cloud"

    # Check local patterns
    for pattern in LOCAL_PATTERNS:
        if re.search(pattern, lower):
            return "local"

    # Heuristic: very short messages -> local, long messages -> cloud
    if word_count <= 5:
        return "local"
    elif word_count >= 20:
        return "cloud"

    # Default: cloud (safer for unknown queries)
    return "cloud"


def reset_local() -> bool:
    """Reset the local Qwen KV cache. Call between conversations."""
    try:
        data = json.dumps({
            "system_prompt": "You are Arlowe, a friendly AI assistant with a calm, curious personality. Be brief, conversational, and helpful. Reply in 1-2 sentences."
        }).encode()
        req = urllib.request.Request(
            QWEN_NATIVE_URL + "/api/reset",
            data=data,
            headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            print("  [router] KV cache reset", flush=True)
            return True
    except Exception as e:
        print(f"  [router] Reset failed: {e}", flush=True)
        return False


def query_local(text: str) -> tuple[str, bool]:
    """Send query to local Qwen model. Returns (response, success)."""
    start_time = time.time()
    input_tokens = estimate_tokens(text)

    try:
        # No system role - Qwen wrapper doesn't support it
        # Prepend persona instruction to user message
        prompt = f"[You are Arlowe, a friendly AI assistant. Reply in 1-2 sentences.]\n{text}"
        data = json.dumps({
            "model": "qwen2.5-1.5b-instruct",
            "messages": [
                {"role": "user", "content": prompt}
            ],
            "max_tokens": 100
        }).encode()

        req = urllib.request.Request(
            QWEN_URL,
            data=data,
            headers={"Content-Type": "application/json"}
        )

        with urllib.request.urlopen(req, timeout=30) as resp:
            latency_ms = int((time.time() - start_time) * 1000)
            result = json.loads(resp.read().decode())
            if "choices" in result and len(result["choices"]) > 0:
                content = result["choices"][0].get("message", {}).get("content", "")
                if content.strip():
                    # Catch KV cache overflow error
                    if "SetKVCache failed" in content or "context may be full" in content:
                        print("  [router] KV cache full — resetting and retrying", flush=True)
                        reset_local()
                        return query_local(text)  # Retry once after reset

                    output_tokens = estimate_tokens(content)
                    log_usage("qwen-local", input_tokens, output_tokens, latency_ms, success=True)
                    return content.strip(), True

        latency_ms = int((time.time() - start_time) * 1000)
        log_usage("qwen-local", input_tokens, 0, latency_ms, success=False)
        return "I had trouble with that.", False
    except Exception as e:
        latency_ms = int((time.time() - start_time) * 1000)
        log_usage("qwen-local", input_tokens, 0, latency_ms, success=False)
        print(f"  [local error] {e}", flush=True)
        return None, False


def query_cloud(text: str) -> tuple[str, bool]:
    """Send query to Claude via the ``claude`` CLI. Returns (response, success).

    Runs ``claude -p`` as a subprocess with the voice system prompt
    appended and all tools disallowed. Uses JSON output format so we get
    the response text, token counts, and exact USD cost directly from
    Claude Code — no local pricing table needed.
    """
    start_time = time.time()
    input_tokens = estimate_tokens(text)

    try:
        proc = subprocess.run(
            [
                CLAUDE_BIN,
                "-p",
                "--model", VOICE_MODEL,
                "--output-format", "json",
                # REPLACE (not append) the default Claude Code system
                # prompt so the coding-assistant persona doesn't bleed
                # through into voice replies.
                "--system-prompt", VOICE_SYSTEM_PROMPT,
                "--disallowed-tools", DISALLOWED_TOOLS,
            ],
            input=text,
            capture_output=True,
            text=True,
            timeout=VOICE_TIMEOUT_SECS,
        )
        latency_ms = int((time.time() - start_time) * 1000)

        if proc.returncode != 0:
            stderr = (proc.stderr or "").strip()[:300]
            print(f"  [cloud error] claude exit {proc.returncode}: {stderr}", flush=True)
            log_usage("anthropic", input_tokens, 0, latency_ms, success=False)
            return None, False

        try:
            payload = json.loads(proc.stdout)
        except json.JSONDecodeError as e:
            print(f"  [cloud error] bad JSON from claude cli: {e}", flush=True)
            log_usage("anthropic", input_tokens, 0, latency_ms, success=False)
            return None, False

        if payload.get("is_error") or payload.get("subtype") != "success":
            reason = payload.get("subtype") or payload.get("error") or "unknown"
            print(f"  [cloud error] claude returned {reason}", flush=True)
            log_usage("anthropic", input_tokens, 0, latency_ms, success=False)
            return None, False

        content = (payload.get("result") or "").strip()
        if not content:
            log_usage("anthropic", input_tokens, 0, latency_ms, success=False)
            return "I had trouble with that.", False

        usage = payload.get("usage") or {}
        actual_input = usage.get("input_tokens") or input_tokens
        actual_output = usage.get("output_tokens") or estimate_tokens(content)
        # Claude Code reports the true USD cost — use it directly instead
        # of guessing from a local pricing table.
        cost = payload.get("total_cost_usd") or 0.0

        log_usage("anthropic", actual_input, actual_output, latency_ms, success=True, cost=cost)
        return content, True

    except subprocess.TimeoutExpired:
        latency_ms = int((time.time() - start_time) * 1000)
        log_usage("anthropic", input_tokens, 0, latency_ms, success=False)
        print(f"  [cloud error] claude cli timed out after {VOICE_TIMEOUT_SECS}s", flush=True)
        return None, False
    except FileNotFoundError:
        latency_ms = int((time.time() - start_time) * 1000)
        log_usage("anthropic", input_tokens, 0, latency_ms, success=False)
        print(f"  [cloud error] claude cli not found at {CLAUDE_BIN}", flush=True)
        return None, False
    except Exception as e:
        latency_ms = int((time.time() - start_time) * 1000)
        log_usage("anthropic", input_tokens, 0, latency_ms, success=False)
        print(f"  [cloud error] {e}", flush=True)
        return None, False


def route(text: str, analyze_sentiment: bool = True) -> tuple[str, bool, str, str, str, Sentiment, float]:
    """
    Route query to appropriate model with sentiment analysis.

    Args:
        text: User input text
        analyze_sentiment: Whether to perform sentiment analysis (default True)

    Returns:
        (response, success, source, model, expression, sentiment, confidence)
        - response: The LLM response text
        - success: Whether the query succeeded
        - source: "local" or "cloud"
        - model: Model name (e.g. "qwen2.5-1.5b", "claude-haiku-4-5")
        - expression: Suggested face expression based on sentiment
        - sentiment: Sentiment enum value
        - confidence: Sentiment classification confidence (0-1)

    See ADR-0001 for the rename from iol_route and the openai_wrapper resolution.
    """
    # Force mode override for testing
    if FORCE_MODE:
        target = FORCE_MODE
        print(f"  [router] FORCED → {target}", flush=True)
    else:
        target = classify(text)
        print(f"  [router] '{text[:40]}...' → {target}", flush=True)

    # Perform sentiment analysis on user input
    expression = "idle"
    sentiment = Sentiment.NEUTRAL
    confidence = 0.0

    if analyze_sentiment:
        # Use NPU sentiment analysis (fast, local)
        # Timeout of 1.5s to keep it responsive
        expression, sentiment, confidence = analyze_and_express(text, use_npu=True)

    if target == "local":
        response, success = query_local(text)
        if success:
            return response, True, "local", "qwen2.5-1.5b", expression, sentiment, confidence
        # Fallback to cloud on local failure
        if FORCE_MODE == "local":
            return "Local model failed. Try again?", False, "local", "qwen2.5-1.5b", expression, sentiment, confidence
        print("  [router] Local failed, falling back to cloud", flush=True)

    # Cloud query (or fallback)
    response, success = query_cloud(text)
    return response, success, "cloud", VOICE_MODEL, expression, sentiment, confidence


if __name__ == "__main__":
    # Test classification and sentiment analysis
    test_queries = [
        "Hello!",
        "What is 2+2?",
        "Tell me a joke",
        "How are you?",
        "Create a new Discord channel",
        "Check the system status",
        "What's the weather like?",
        "Compare Python and JavaScript",
        "I'm feeling tired",
        "Debug the voice assistant",
        "I'm so happy today!",
        "This is terrible and frustrating",
    ]

    print("=== Classification Test ===")
    for q in test_queries:
        target = classify(q)
        print(f"  {target:5s} | {q}")

    print("\n=== Sentiment Analysis Test ===")
    for q in test_queries[:3]:  # Test first 3 with actual routing
        print(f"\nQuery: {q}")
        response, success, source, model, expression, sentiment, confidence = route(q, analyze_sentiment=True)
        print(f"  Source: {source} | Model: {model}")
        print(f"  Sentiment: {sentiment.value} ({confidence:.2f}) → Expression: {expression}")
        if success:
            print(f"  Response: {response[:100]}...")
