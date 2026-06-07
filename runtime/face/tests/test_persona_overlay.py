"""Phase 4 (04-04): arlowe-face consumes persona.sentiment_mapping from the YAML
overlay via the shared loader, deep-merged over defaults; absent overlay -> defaults.

Run from repo root:
  PYTHONPATH=runtime/lib:runtime/face \
  ARLOWE_SCHEMA_PATH=config/schema.yml ARLOWE_DEFAULTS_PATH=config/defaults.yml \
  python3 -m pytest runtime/face/tests/test_persona_overlay.py -q
"""
import importlib
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]


def _load_config(monkeypatch, overlay_path):
    """Point both the shared loader and sentiment_classifier at repo config +
    the given overlay path, then (re)load and call load_config()."""
    monkeypatch.setenv("ARLOWE_SCHEMA_PATH", str(REPO / "config" / "schema.yml"))
    monkeypatch.setenv("ARLOWE_DEFAULTS_PATH", str(REPO / "config" / "defaults.yml"))
    monkeypatch.setenv("ARLOWE_CONFIG_PATH", str(overlay_path))
    # Both modules read their path env vars at import time — reload so each case
    # sees the case-specific env.
    import arlowe_config
    import sentiment_classifier
    importlib.reload(arlowe_config)
    importlib.reload(sentiment_classifier)
    return sentiment_classifier.load_config()


def test_overlay_overrides_one_sentiment_preserves_siblings(tmp_path, monkeypatch):
    overlay = tmp_path / "config.yml"
    overlay.write_text("persona:\n  sentiment_mapping:\n    positive:\n      - excited\n")
    mapping = _load_config(monkeypatch, overlay)
    # Overlay wins for positive; defaults preserved for the untouched siblings.
    assert mapping["positive"] == ["excited"]
    assert mapping["neutral"] == ["idle", "attentive"]
    assert mapping["negative"] == ["concerned", "sad"]


def test_absent_overlay_returns_defaults_without_raising(tmp_path, monkeypatch):
    # ARLOWE_CONFIG_PATH points at a nonexistent file — the pre-pairing state (SC3).
    mapping = _load_config(monkeypatch, tmp_path / "nonexistent.yml")
    assert mapping["positive"] == ["happy", "excited"]
    assert mapping["neutral"] == ["idle", "attentive"]
