"""
Shared config loader for Arlowe runtime services.

Installed flat at /opt/arlowe/runtime/lib/arlowe_config.py; import as:
    from arlowe_config import load

Merge semantics:
  - defaults.yml is loaded unconditionally.
  - /etc/arlowe/config.yml (overlay) is optional; absent == pre-pairing, no error.
  - Merge is SHALLOW at the top level but DEEP for nested dicts, so a partial
    persona overlay that sets only persona.sentiment_mapping.positive merges over
    the defaults while preserving neutral/negative siblings.
  - The merged dict is validated AFTER merge; a partial overlay is valid because
    the merged dict always carries all keys from defaults.
  - Schema violations print a greppable stderr line and raise SystemExit(78)
    (EX_CONFIG from sysexits.h) — systemd records the exit code and shows stderr.
"""

import os
import sys
import yaml
from pathlib import Path
from jsonschema import Draft202012Validator

DEFAULTS = Path(os.environ.get("ARLOWE_DEFAULTS_PATH", "/opt/arlowe/config/defaults.yml"))
OVERLAY = Path(os.environ.get("ARLOWE_CONFIG_PATH", "/etc/arlowe/config.yml"))
SCHEMA = Path(os.environ.get("ARLOWE_SCHEMA_PATH", "/opt/arlowe/config/schema.yml"))


def deep_merge(base: dict, overlay: dict) -> dict:
    """Return a new dict that is overlay deep-merged onto base.

    Nested dicts are merged recursively so sub-keys from base are preserved
    when the overlay only sets some of them. All other types are replaced by
    the overlay value (no list-appending, no coercion).
    """
    result = dict(base)
    for key, value in overlay.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def load() -> dict:
    """Load, merge, validate, and return the resolved config dict.

    Returns:
        Merged and validated config dict.

    Raises:
        SystemExit(78): On any JSON Schema violation (EX_CONFIG).
        FileNotFoundError: If defaults.yml or schema.yml is missing.
    """
    defaults = yaml.safe_load(DEFAULTS.read_text())

    if OVERLAY.exists():
        overlay = yaml.safe_load(OVERLAY.read_text()) or {}
    else:
        overlay = {}

    merged = deep_merge(defaults, overlay)

    schema = yaml.safe_load(SCHEMA.read_text())
    validator = Draft202012Validator(schema)
    errors = sorted(validator.iter_errors(merged), key=lambda e: list(e.path))

    if errors:
        for e in errors:
            path = "/".join(map(str, e.path)) or "<root>"
            print(f"[arlowe-config] schema violation at {path}: {e.message}", file=sys.stderr)
        raise SystemExit(78)

    return merged
