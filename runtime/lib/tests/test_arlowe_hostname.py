"""
Unit tests for arlowe_hostname.

Run from repo root:
    PYTHONPATH=runtime/lib python3 -m pytest runtime/lib/tests/test_arlowe_hostname.py -q

Banned strings are read from scripts/sanitize/banlist.txt at run time and are
never parametrized or placed in assertion messages, so they cannot leak into
this file or into test output. Failures name an entry by its index only.
"""

import re
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

import arlowe_hostname as hn

REPO_ROOT = Path(__file__).resolve().parents[3]
BANLIST = REPO_ROOT / "scripts/sanitize/banlist.txt"
GENERATOR = REPO_ROOT / "scripts/sanitize/gen-hostname-banlist.py"
HASH_FILE = REPO_ROOT / "runtime/lib/arlowe_hostname_banlist.json"
LABEL = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")


def banlist_entries():
    return [
        line.strip().lower()
        for line in BANLIST.read_text().splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


def hostname_shaped_entries():
    return [e for e in banlist_entries() if re.fullmatch(r"[a-z0-9-]+", e)]


def reason_of(name):
    with pytest.raises(hn.HostnameRejected) as exc:
        hn.validate_display_name(name)
    return exc.value.reason


@pytest.mark.parametrize(
    "name, slug",
    [
        ("Kitchen Test", "kitchen-test"),
        ("Café  Nº5!", "cafe-no5"),
        ("--a--b--", "a-b"),
    ],
)
def test_slugify_cases(name, slug):
    assert hn.slugify(name) == slug


def test_slugify_long_name_trimmed_without_trailing_hyphen():
    name = "ab " * 33 + "c"
    slug = hn.slugify(name)
    assert len(slug) <= 63
    assert not slug.endswith("-")
    assert LABEL.match(slug)
    assert hn.slugify("x" * 100) == "x" * 63


def test_default_name_ok():
    assert hn.validate_display_name("Arlowe") == ("Arlowe", "arlowe")


def test_validate_returns_display_name_and_slug():
    assert hn.validate_display_name("Kitchen Test") == ("Kitchen Test", "kitchen-test")


@pytest.mark.parametrize("name", ["", "   ", "\t\n"])
def test_empty_rejected(name):
    assert reason_of(name) == "empty"


def test_too_long_rejected():
    assert reason_of("k" * 33) == "too_long"
    assert hn.validate_display_name("k" * 32)[1] == "k" * 32


@pytest.mark.parametrize("name", ["!!!", "---", "日本語", "★☆"])
def test_no_usable_characters(name):
    assert reason_of(name) == "no_usable_characters"


@pytest.mark.parametrize("name", ["localhost", "LocalHost", "12345", "1 2 3"])
def test_reserved(name):
    assert reason_of(name) == "reserved"


@pytest.mark.parametrize(
    "name",
    ["Kitchen Test", "Café  Nº5!", "--a--b--", "x" * 32, "Ünïcödé Ñame", "a", "9 Lives"],
)
def test_every_slug_is_a_valid_label(name):
    _, slug = hn.validate_display_name(name)
    assert LABEL.match(slug)


def test_slugify_output_always_label_or_empty():
    for name in ["-", "a-", "-a", "a" * 64 + "-b", "Ω≈ç√", "A.B_C", "x-" * 40]:
        slug = hn.slugify(name)
        assert slug == "" or LABEL.match(slug)


def test_banlist_has_hostname_shaped_entries():
    assert hostname_shaped_entries(), "expected at least one hostname-shaped banlist entry"


def test_banlist_entries_rejected():
    for i, entry in enumerate(hostname_shaped_entries()):
        name = "my " + entry + " unit"
        if len(name) > 32:
            name = entry
        try:
            hn.validate_display_name(name)
        except hn.HostnameRejected as e:
            assert e.reason == "not_allowed", f"entry #{i} rejected as {e.reason}"
        else:
            pytest.fail(f"entry #{i} was accepted")


def test_banlist_entries_rejected_case_folded():
    for i, entry in enumerate(hostname_shaped_entries()):
        try:
            hn.validate_display_name(entry.upper())
        except hn.HostnameRejected as e:
            assert e.reason == "not_allowed", f"entry #{i} rejected as {e.reason}"
        else:
            pytest.fail(f"entry #{i} was accepted in upper case")


def test_rejection_does_not_leak():
    for i, entry in enumerate(hostname_shaped_entries()):
        with pytest.raises(hn.HostnameRejected) as exc:
            hn.validate_display_name(entry)
        text = str(exc.value).lower() + repr(exc.value).lower()
        for other in banlist_entries():
            assert other not in text, f"rejection for entry #{i} names a banlist entry"


def test_hash_file_matches_generator():
    result = subprocess.run(
        [sys.executable, str(GENERATOR), "--check"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, "hash file out of sync; run gen-hostname-banlist.py"


def test_hash_file_has_no_literals():
    text = HASH_FILE.read_text().lower()
    for i, entry in enumerate(banlist_entries()):
        assert entry not in text, f"hash file contains banlist entry #{i}"


def test_banlist_path_override(tmp_path, monkeypatch):
    empty = tmp_path / "banlist.json"
    empty.write_text("[]\n")
    monkeypatch.setenv("ARLOWE_HOSTNAME_BANLIST", str(empty))
    entry = hostname_shaped_entries()[0]
    assert hn.validate_display_name(entry)[1] == entry
