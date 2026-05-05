#!/usr/bin/env python3
"""
Train a custom verifier model for "Hey Arlowe" wake word detection.

This uses openWakeWord's verifier system to train a speaker-specific model
on top of the hey_jarvis base model (phonetically similar to "Hey Arlowe").

The verifier learns to recognize YOUR voice saying the wake word, reducing
false positives from other speakers or similar-sounding words.

Usage: ./train_verifier.py
Requires: At least 50 positive and 30 negative samples in the appropriate dirs.
"""
import os
import sys

_extra = os.environ.get("ARLOWE_VENV_SITE_PACKAGES")
if _extra and _extra not in sys.path:
    sys.path.insert(0, _extra)

import glob
import openwakeword
from openwakeword.custom_verifier_model import train_custom_verifier

_STATE_DIR = os.environ.get("ARLOWE_WAKE_WORD_STATE", "/var/lib/arlowe/wake-word")
POSITIVE_DIR = os.path.join(_STATE_DIR, "positive")
NEGATIVE_DIR = os.path.join(_STATE_DIR, "negative")
OUTPUT_MODEL = os.environ.get("ARLOWE_WAKE_WORD_VERIFIER",
                              os.path.join(_STATE_DIR, "verifier.pkl"))

# Base model - hey_jarvis is phonetically close to "hey arlowe"
BASE_MODEL = "hey_jarvis"

def main():
    # Check sample counts
    positive_samples = glob.glob(os.path.join(POSITIVE_DIR, "*.wav"))
    negative_samples = glob.glob(os.path.join(NEGATIVE_DIR, "*.wav"))
    
    print("=" * 50)
    print("HEY ARLOWE VERIFIER TRAINING")
    print("=" * 50)
    print(f"\nPositive samples: {len(positive_samples)}")
    print(f"Negative samples: {len(negative_samples)}")
    
    if len(positive_samples) < 50:
        print(f"\nNeed at least 50 positive samples (have {len(positive_samples)})")
        print("Run: ./collect_samples.py positive")
        return 1

    if len(negative_samples) < 30:
        print(f"\nNeed at least 30 negative samples (have {len(negative_samples)})")
        print("Run: ./collect_samples.py negative")
        return 1
    
    print(f"\nBase model: {BASE_MODEL}")
    print(f"Output: {OUTPUT_MODEL}")
    print("\nStarting training...\n")

    try:
        train_custom_verifier(
            positive_reference_clips=positive_samples,
            negative_reference_clips=negative_samples,
            output_path=OUTPUT_MODEL,
            model_name=BASE_MODEL
        )

        print(f"\nTraining complete!")
        print(f"Model saved to: {OUTPUT_MODEL}")
        print("\nTest it with: ./test_verifier.py")
        return 0

    except Exception as e:
        print(f"\nTraining failed: {e}")
        import traceback
        traceback.print_exc()
        return 1

if __name__ == "__main__":
    sys.exit(main())
