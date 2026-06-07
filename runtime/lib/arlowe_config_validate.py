"""
Standalone config validator for use as a systemd ExecStartPre entry point.

Usage (in each *.service [Service] block):
    ExecStartPre=/opt/arlowe/venvs/<svc>/bin/python -m arlowe_config_validate

Exits 0 on success (prints "[arlowe-config] OK" to stdout).
Exits 78 (EX_CONFIG) on schema violation (stderr lines from arlowe_config.load()).

The module lives at /opt/arlowe/runtime/lib alongside arlowe_config.py as a flat
module (not a package). Runnable when /opt/arlowe/runtime/lib is on PYTHONPATH.
"""

try:
    from arlowe_config import load
except ImportError:
    import importlib.util as _util
    import pathlib as _pathlib
    _spec = _util.spec_from_file_location(
        "arlowe_config",
        _pathlib.Path(__file__).parent / "arlowe_config.py",
    )
    _mod = _util.module_from_spec(_spec)
    _spec.loader.exec_module(_mod)
    load = _mod.load

if __name__ == "__main__":
    load()
    print("[arlowe-config] OK")
