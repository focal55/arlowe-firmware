"""
Unit tests for voice.wake_gate.

Run from repo root:
    PYTHONPATH=runtime python3 -m pytest runtime/voice/tests/test_wake_gate.py -q

Fully offline and hardware-free: no numpy, no openwakeword, no pyaudio, no Pi.
The verifier is a picklable stub and the feature vector is a plain list, which
is the whole point of keeping wake_gate stdlib-only. If this file ever needs a
third-party import beyond pytest, the module has grown a dependency the image
substrate cannot satisfy.

Every fixture is built under tmp_path at runtime -- no binary artifacts are
committed, matching the tests/phase-7 convention.
"""

import pickle
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from voice.wake_gate import (  # noqa: E402
    GENERIC_BASE_THRESHOLD,
    VERIFIED_BASE_THRESHOLD,
    VERIFIER_THRESHOLD,
    WakeGate,
    load_verifier,
)


class StubVerifier:
    """Stands in for the sklearn classifier. Module-level so pickle can find it."""

    def __init__(self, proba):
        self.proba = proba
        self.calls = 0

    def predict_proba(self, rows):
        self.calls += 1
        return [list(self.proba)]


class CountingFeatures:
    """Zero-arg features_fn that records whether it was ever invoked."""

    def __init__(self):
        self.calls = 0

    def __call__(self):
        self.calls += 1
        return [0.1, 0.2, 0.3]


def write_verifier(tmp_path, proba):
    path = tmp_path / "verifier.pkl"
    with open(path, "wb") as handle:
        pickle.dump(StubVerifier(proba), handle)
    return path


def test_absent_verifier_yields_generic_mode(tmp_path):
    """Case 1: the factory state. No pickle on disk, so the base model is the gate."""
    missing = tmp_path / "wake-word" / "verifier.pkl"
    assert not missing.exists()

    assert load_verifier(missing) is None

    gate = WakeGate(missing)
    assert gate.personalized is False
    assert gate.base_threshold == GENERIC_BASE_THRESHOLD == 0.7
    assert gate.mode == "generic"


def test_generic_below_threshold_never_extracts_features(tmp_path):
    """Case 2: the cost guarantee. A generic device must not pay for feature extraction."""
    gate = WakeGate(tmp_path / "verifier.pkl")
    features = CountingFeatures()

    assert gate.evaluate(0.5, features) == (False, None)
    assert features.calls == 0


def test_generic_above_threshold_accepts(tmp_path):
    """Case 3: base model alone can accept once it clears 0.7."""
    gate = WakeGate(tmp_path / "verifier.pkl")
    features = CountingFeatures()

    assert gate.evaluate(0.8, features) == (True, None)
    # Still no extraction: there is no verifier to feed.
    assert features.calls == 0


def test_present_verifier_accepts_above_verifier_threshold(tmp_path):
    """Case 4: personalized mode drops the base gate to 0.20 and defers to the verifier."""
    gate = WakeGate(write_verifier(tmp_path, [0.6, 0.4]))

    assert gate.personalized is True
    assert gate.base_threshold == VERIFIED_BASE_THRESHOLD == 0.20
    assert gate.mode == "personalized"

    features = CountingFeatures()
    accepted, score = gate.evaluate(0.25, features)

    assert (accepted, score) == (True, 0.4)
    assert score > VERIFIER_THRESHOLD
    assert features.calls == 1

    # 0.25 clears the personalized base gate but would be rejected outright on a
    # generic device -- the two modes are genuinely different decisions.
    assert 0.25 < GENERIC_BASE_THRESHOLD


def test_present_verifier_rejects_below_verifier_threshold(tmp_path):
    """Case 5: base cleared, verifier said no."""
    gate = WakeGate(write_verifier(tmp_path, [0.8, 0.2]))

    features = CountingFeatures()
    accepted, score = gate.evaluate(0.25, features)

    assert (accepted, score) == (False, 0.2)
    assert score < VERIFIER_THRESHOLD
    assert features.calls == 1


def test_corrupt_verifier_degrades_to_generic(tmp_path, capsys):
    """Case 6: a half-written personalization file must not stop the device booting."""
    corrupt = tmp_path / "verifier.pkl"
    corrupt.write_bytes(b"not a pickle")

    assert load_verifier(corrupt) is None

    gate = WakeGate(corrupt)
    assert gate.personalized is False
    assert gate.base_threshold == GENERIC_BASE_THRESHOLD

    # The degradation is announced, not silent.
    assert "unreadable" in capsys.readouterr().err

    features = CountingFeatures()
    assert gate.evaluate(0.5, features) == (False, None)
    assert gate.evaluate(0.8, features) == (True, None)
    assert features.calls == 0


def test_truncated_verifier_degrades_to_generic(tmp_path):
    """A pickle that starts valid and stops mid-stream is the realistic corruption."""
    good = write_verifier(tmp_path, [0.6, 0.4])
    truncated = tmp_path / "truncated.pkl"
    truncated.write_bytes(good.read_bytes()[:-4])

    assert load_verifier(truncated) is None
    assert WakeGate(truncated).personalized is False


def test_explicit_verifier_injection_bypasses_disk(tmp_path):
    """Callers may supply a classifier directly; passing None forces generic mode."""
    stub = StubVerifier([0.1, 0.9])

    injected = WakeGate(tmp_path / "nonexistent.pkl", verifier=stub)
    assert injected.personalized is True
    assert injected.evaluate(0.25, CountingFeatures()) == (True, 0.9)

    forced_generic = WakeGate(write_verifier(tmp_path, [0.1, 0.9]), verifier=None)
    assert forced_generic.personalized is False
    assert forced_generic.base_threshold == GENERIC_BASE_THRESHOLD


@pytest.mark.parametrize("base_score", [0.0, 0.2, 0.69, 0.7])
def test_generic_rejects_at_and_below_threshold(base_score, tmp_path):
    """The gate is strictly greater-than, matching the pre-existing comparison."""
    gate = WakeGate(tmp_path / "verifier.pkl")
    assert gate.evaluate(base_score, CountingFeatures()) == (False, None)


def test_wake_gate_imports_no_third_party_modules():
    """The stdlib-only constraint is the reason this suite can run in the cheap CI job."""
    import voice.wake_gate as module

    source = Path(module.__file__).read_text()
    for banned in ("numpy", "sklearn", "openwakeword", "pyaudio", "noisereduce"):
        assert f"import {banned}" not in source
