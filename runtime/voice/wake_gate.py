"""
Wake-word accept policy for the voice orchestrator.

Two operating modes, selected at construction time by whether a trained verifier
pickle exists on disk:

  generic (SHIPPED IN v1)
      No verifier file. The openwakeword base model is the only gate, so its
      activation threshold is raised to GENERIC_BASE_THRESHOLD (0.7) to
      compensate for the missing speaker-specific filtering. This is the factory
      state of every device: nothing writes the verifier until the owner opts
      into personalization, which is WAKE-03/WAKE-04 and post-v1.

  personalized (post-v1, opt-in)
      A verifier pickle exists. The base model becomes a cheap pre-filter at
      VERIFIED_BASE_THRESHOLD (0.20) and the sklearn verifier makes the real
      decision at VERIFIER_THRESHOLD (0.30). Feature extraction is only paid for
      after the base model clears the pre-filter.

This module is deliberately stdlib-only: no numpy, no sklearn, no openwakeword.
The verifier object is duck-typed (anything with ``predict_proba``) and the
feature vector arrives through a caller-supplied callable. That keeps the accept
policy testable under a bare python3 instead of requiring the voice venv, and it
keeps the policy honest -- the thresholds live here and nowhere else.

An unreadable or truncated verifier degrades to generic mode rather than
raising. A half-written personalization file must not stop the device booting.
"""

import pickle
import sys
from pathlib import Path
from typing import Any, Callable, Optional, Sequence, Tuple

# Generic mode: the base model is the only gate, so it must be strict.
GENERIC_BASE_THRESHOLD = 0.7

# Personalized mode: the base model is a cheap pre-filter ahead of the verifier.
VERIFIED_BASE_THRESHOLD = 0.20
VERIFIER_THRESHOLD = 0.30

# Verifier scores below this are near-misses not worth a journal line.
VERIFIER_LOG_THRESHOLD = 0.20

_UNSET = object()


def load_verifier(path) -> Optional[Any]:
    """Load the wake-word verifier, or return None if there isn't a usable one.

    Returns None when `path` does not exist (the factory state) and also when it
    exists but cannot be unpickled. Both cases mean the same thing to the
    caller: run the generic model.
    """
    candidate = Path(path)
    if not candidate.exists():
        return None
    try:
        with open(candidate, "rb") as handle:
            return pickle.load(handle)
    except Exception as exc:
        print(
            f"[wake_gate] verifier at {candidate} is unreadable ({exc.__class__.__name__}: {exc}); "
            "falling back to the generic base model",
            file=sys.stderr,
            flush=True,
        )
        return None


class WakeGate:
    """Decides whether a base-model activation counts as a wake."""

    def __init__(self, verifier_path, verifier: Any = _UNSET) -> None:
        self.verifier_path = Path(verifier_path)
        # `verifier` is injectable so callers and tests can supply a classifier
        # directly; passing None explicitly forces generic mode.
        self.verifier = load_verifier(self.verifier_path) if verifier is _UNSET else verifier

    @property
    def personalized(self) -> bool:
        return self.verifier is not None

    @property
    def base_threshold(self) -> float:
        return VERIFIED_BASE_THRESHOLD if self.personalized else GENERIC_BASE_THRESHOLD

    @property
    def mode(self) -> str:
        return "personalized" if self.personalized else "generic"

    def evaluate(
        self,
        base_score: float,
        features_fn: Callable[[], Sequence[float]],
    ) -> Tuple[bool, Optional[float]]:
        """Return (accepted, verifier_score) for one base-model activation.

        `features_fn` is called only in personalized mode, and only once the
        base score clears `base_threshold`. A generic device never pays for
        feature extraction.
        """
        if base_score <= self.base_threshold:
            return False, None
        if not self.personalized:
            return True, None
        verifier_score = float(self.verifier.predict_proba([features_fn()])[0][1])
        return verifier_score > VERIFIER_THRESHOLD, verifier_score
