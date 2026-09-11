"""
Unit tests for arlowe_config loader.

Run from repo root:
    PYTHONPATH=runtime/lib \
    ARLOWE_SCHEMA_PATH=config/schema.yml \
    ARLOWE_DEFAULTS_PATH=config/defaults.yml \
    ARLOWE_CONFIG_PATH=/nonexistent \
    python3 -m pytest runtime/lib/tests/ -q

Or from runtime/lib/:
    python3 -m pytest tests/ -q
"""

import os
import sys
import pytest
import yaml
import tempfile
import textwrap
from pathlib import Path

# Ensure arlowe_config is importable when tests run from within runtime/lib/
sys.path.insert(0, str(Path(__file__).parent.parent))

import arlowe_config


REPO_ROOT = Path(__file__).parent.parent.parent.parent
SCHEMA_PATH = REPO_ROOT / "config" / "schema.yml"
DEFAULTS_PATH = REPO_ROOT / "config" / "defaults.yml"


def _set_paths(monkeypatch, *, overlay_path: str):
    monkeypatch.setenv("ARLOWE_SCHEMA_PATH", str(SCHEMA_PATH))
    monkeypatch.setenv("ARLOWE_DEFAULTS_PATH", str(DEFAULTS_PATH))
    monkeypatch.setenv("ARLOWE_CONFIG_PATH", overlay_path)
    monkeypatch.setattr(arlowe_config, "SCHEMA", Path(str(SCHEMA_PATH)))
    monkeypatch.setattr(arlowe_config, "DEFAULTS", Path(str(DEFAULTS_PATH)))
    monkeypatch.setattr(arlowe_config, "OVERLAY", Path(overlay_path))


class TestDefaultsOnlyLoad:
    def test_returns_dict_equal_to_parsed_defaults(self, monkeypatch):
        _set_paths(monkeypatch, overlay_path="/nonexistent/config.yml")
        result = arlowe_config.load()
        expected = yaml.safe_load(DEFAULTS_PATH.read_text())
        assert result == expected

    def test_absent_overlay_does_not_raise(self, monkeypatch):
        _set_paths(monkeypatch, overlay_path="/nonexistent/config.yml")
        result = arlowe_config.load()
        assert isinstance(result, dict)


class TestPartialPersonaOverlay:
    def test_partial_sentiment_mapping_deep_merges(self, monkeypatch, tmp_path):
        overlay_file = tmp_path / "config.yml"
        overlay_file.write_text(textwrap.dedent("""\
            persona:
              sentiment_mapping:
                positive:
                  - "excited"
        """))
        _set_paths(monkeypatch, overlay_path=str(overlay_file))

        result = arlowe_config.load()

        sm = result["persona"]["sentiment_mapping"]
        assert sm["positive"] == ["excited"], "overlay value must replace default"
        assert sm["neutral"] == ["idle", "attentive"], "neutral must be preserved from defaults"
        assert sm["negative"] == ["concerned", "sad"], "negative must be preserved from defaults"

    def test_partial_persona_overlay_validates_clean(self, monkeypatch, tmp_path):
        overlay_file = tmp_path / "config.yml"
        overlay_file.write_text(textwrap.dedent("""\
            persona:
              sentiment_mapping:
                positive:
                  - "excited"
        """))
        _set_paths(monkeypatch, overlay_path=str(overlay_file))
        result = arlowe_config.load()
        assert isinstance(result, dict)


class TestSchemaViolations:
    def test_invalid_enum_raises_system_exit_78(self, monkeypatch, tmp_path):
        overlay_file = tmp_path / "config.yml"
        overlay_file.write_text(textwrap.dedent("""\
            ota:
              channel: "purple"
        """))
        _set_paths(monkeypatch, overlay_path=str(overlay_file))

        with pytest.raises(SystemExit) as exc_info:
            arlowe_config.load()
        assert exc_info.value.code == 78

    def test_wrong_type_raises_system_exit_78(self, monkeypatch, tmp_path):
        overlay_file = tmp_path / "config.yml"
        overlay_file.write_text(textwrap.dedent("""\
            ports:
              face: "nope"
        """))
        _set_paths(monkeypatch, overlay_path=str(overlay_file))

        with pytest.raises(SystemExit) as exc_info:
            arlowe_config.load()
        assert exc_info.value.code == 78

    def test_violation_stderr_contains_greppable_prefix(self, monkeypatch, tmp_path, capsys):
        overlay_file = tmp_path / "config.yml"
        overlay_file.write_text(textwrap.dedent("""\
            ota:
              channel: "purple"
        """))
        _set_paths(monkeypatch, overlay_path=str(overlay_file))

        with pytest.raises(SystemExit):
            arlowe_config.load()

        captured = capsys.readouterr()
        assert "[arlowe-config] schema violation at" in captured.err


class TestIdentityBlock:
    """The identity block (ADR-0007) is optional at the top level but always
    present in the merged dict. These tests are the regression proof that adding
    it did not change the contract for any existing consumer."""

    def test_identity_defaults_present_without_overlay(self, monkeypatch):
        _set_paths(monkeypatch, overlay_path="/nonexistent/config.yml")
        identity = arlowe_config.load()["identity"]
        assert identity["provisioning_url"] == ""
        assert identity["credentials_endpoint"] == ""
        assert identity["role_alias"] == ""
        assert identity["poll_interval_seconds"] == 3600

    def test_identity_partial_overlay_deep_merges(self, monkeypatch, tmp_path):
        overlay_file = tmp_path / "config.yml"
        overlay_file.write_text(textwrap.dedent("""\
            identity:
              poll_interval_seconds: 900
        """))
        _set_paths(monkeypatch, overlay_path=str(overlay_file))

        identity = arlowe_config.load()["identity"]

        assert identity["poll_interval_seconds"] == 900, "overlay value must replace default"
        assert identity["provisioning_url"] == "", "sibling keys must survive a partial overlay"
        assert identity["credentials_endpoint"] == ""
        assert identity["role_alias"] == ""

    def test_identity_poll_interval_below_minimum_rejected(self, monkeypatch, tmp_path):
        # 900s is the AWS credentialDurationSeconds floor; a shorter poll would
        # break the one-polling-interval revocation bound ADR-0007 guarantees.
        overlay_file = tmp_path / "config.yml"
        overlay_file.write_text(textwrap.dedent("""\
            identity:
              poll_interval_seconds: 60
        """))
        _set_paths(monkeypatch, overlay_path=str(overlay_file))

        with pytest.raises(SystemExit) as exc_info:
            arlowe_config.load()
        assert exc_info.value.code == 78

    def test_config_without_identity_block_still_validates(self, monkeypatch, tmp_path):
        overlay_file = tmp_path / "config.yml"
        overlay_file.write_text(textwrap.dedent("""\
            ota:
              channel: "beta"
        """))
        _set_paths(monkeypatch, overlay_path=str(overlay_file))

        result = arlowe_config.load()

        assert result["ota"]["channel"] == "beta"
        assert result["identity"]["poll_interval_seconds"] == 3600
