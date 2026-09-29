"""Tests for the claim-code store (ADR-0012). Stdlib only: no boto3 needed."""

import hashlib
import json
import multiprocessing
import subprocess
import sys
from pathlib import Path

import pytest

PKI_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PKI_DIR))
import claim_codes  # noqa: E402

CLI = [sys.executable, str(PKI_DIR / "claim_codes.py")]
DEV_A = "a1b2c3d4e5f60718293a4b5c6d7e8f90"
DEV_B = "0f9e8d7c6b5a49382716f5e4d3c2b1a0"


@pytest.fixture
def store(tmp_path):
    path = tmp_path / "claim-codes.json"
    path.write_text("{}")
    return claim_codes.ClaimStore(path)


def entry_for(store, code):
    return store.load()[hashlib.sha256(claim_codes.normalize(code).encode()).hexdigest()]


def test_normalize_uppercases_and_strips_separators():
    assert claim_codes.normalize("abcde-fghjk mnpqr-stvwx") == "ABCDEFGHJKMNPQRSTVWX"


def test_normalize_applies_crockford_aliases():
    assert claim_codes.normalize("IiLlO-oabcd-efghj-kmnpq") == "111100ABCDEFGHJKMNPQ"


@pytest.mark.parametrize("bad", ["", "ABCDE-FGHJK-MNPQR", "ABCDE-FGHJK-MNPQR-STVWXY", "UBCDE-FGHJK-MNPQR-STVWX"])
def test_normalize_rejects_malformed(bad):
    with pytest.raises(ValueError):
        claim_codes.normalize(bad)


def test_mint_adds_unused_entry(store):
    code = store.mint("unit 7")
    assert len(claim_codes.normalize(code)) == 20
    entry = entry_for(store, code)
    assert entry["state"] == "unused"
    assert entry["device_id"] is None
    assert entry["note"] == "unit 7"
    assert entry["minted_at"]


def test_store_never_holds_plaintext(store):
    code = store.mint(None)
    raw = store.path.read_text()
    assert claim_codes.normalize(code) not in raw
    assert code not in raw


def test_redeem_binds_first_device_and_is_idempotent(store):
    code = store.mint(None)
    assert store.redeem(code, DEV_A) is True
    first = entry_for(store, code)
    assert (first["state"], first["device_id"]) == ("bound", DEV_A)
    assert store.redeem(code.lower(), DEV_A) is True
    assert entry_for(store, code) == first


def test_redeem_refuses_other_device_revoked_and_unknown(store):
    code = store.mint(None)
    store.redeem(code, DEV_A)
    assert store.redeem(code, DEV_B) is False
    revoked = store.mint(None)
    store.revoke(revoked)
    assert store.redeem(revoked, DEV_A) is False
    assert store.redeem("00000-00000-00000-00000", DEV_A) is False
    assert entry_for(store, code)["device_id"] == DEV_A


def test_redeem_decision_is_pure():
    entry = {"state": "unused", "device_id": None, "minted_at": "t0", "bound_at": None, "note": None}
    bound = claim_codes.redeem(entry, DEV_A, now="t1")
    assert entry["state"] == "unused"
    assert (bound["state"], bound["device_id"], bound["bound_at"]) == ("bound", DEV_A, "t1")
    assert claim_codes.redeem(bound, DEV_A, now="t2") == bound
    assert claim_codes.redeem(bound, DEV_B) is None
    assert claim_codes.redeem(None, DEV_A) is None
    assert claim_codes.redeem(dict(entry, state="revoked"), DEV_A) is None


def test_release_returns_bound_code_to_unused(store):
    code = store.mint(None)
    store.redeem(code, DEV_A)
    store.release(code)
    entry = entry_for(store, code)
    assert (entry["state"], entry["device_id"], entry["bound_at"]) == ("unused", None, None)
    assert store.redeem(code, DEV_B) is True


def test_release_device_releases_every_code_bound_to_it(store):
    codes = [store.mint(None) for _ in range(3)]
    store.redeem(codes[0], DEV_A)
    store.redeem(codes[1], DEV_A)
    store.redeem(codes[2], DEV_B)
    assert store.release_device(DEV_A) == 2
    assert [entry_for(store, c)["state"] for c in codes] == ["unused", "unused", "bound"]
    assert store.release_device(DEV_A) == 0


def test_revoke_is_permanent(store):
    code = store.mint(None)
    store.redeem(code, DEV_A)
    store.revoke(code)
    store.release(code)
    assert store.release_device(DEV_A) == 0
    assert entry_for(store, code)["state"] == "revoked"
    assert store.redeem(code, DEV_A) is False


def test_missing_store_raises(tmp_path):
    with pytest.raises(FileNotFoundError):
        claim_codes.ClaimStore(tmp_path / "absent.json").load()


def _race_worker(path, code, device_id, barrier, results):
    sys.path.insert(0, str(PKI_DIR))
    import claim_codes as cc

    barrier.wait()
    try:
        results.put(cc.ClaimStore(path).redeem(code, device_id))
    except Exception as exc:  # surface a worker crash as a result, not a queue timeout
        results.put(repr(exc))


def test_concurrent_redeem(store):
    code = store.mint(None)
    ctx = multiprocessing.get_context("spawn")
    ids = ["%032x" % n for n in range(1, 7)]
    barrier = ctx.Barrier(len(ids))
    results = ctx.Queue()
    procs = [ctx.Process(target=_race_worker, args=(str(store.path), code, i, barrier, results)) for i in ids]
    for p in procs:
        p.start()
    outcomes = [results.get(timeout=30) for _ in procs]
    for p in procs:
        p.join(timeout=30)
        assert p.exitcode == 0
    assert sorted(outcomes, key=repr) == [False] * (len(ids) - 1) + [True]
    entries = json.loads(store.path.read_text())
    assert entries[hashlib.sha256(claim_codes.normalize(code).encode()).hexdigest()]["device_id"] in ids


def run_cli(store_path, *args):
    return subprocess.run(CLI + ["--store", str(store_path)] + list(args), capture_output=True, text=True, check=True)


def test_cli_mint_prints_grouped_code_once(tmp_path):
    path = tmp_path / "codes.json"
    out = run_cli(path, "mint", "--note", "unit 9").stdout.strip()
    assert len(out.split("-")) == 4 and all(len(g) == 5 for g in out.split("-"))
    assert claim_codes.ClaimStore(path).redeem(out, DEV_A) is True


def test_cli_revoke_and_release(tmp_path):
    path = tmp_path / "codes.json"
    code = run_cli(path, "mint").stdout.strip()
    claim_codes.ClaimStore(path).redeem(code, DEV_A)
    run_cli(path, "release", code)
    assert claim_codes.ClaimStore(path).redeem(code, DEV_B) is True
    run_cli(path, "revoke", code)
    assert claim_codes.ClaimStore(path).redeem(code, DEV_B) is False


def test_list_never_prints_code(tmp_path):
    path = tmp_path / "codes.json"
    code = run_cli(path, "mint", "--note", "shelf").stdout.strip()
    claim_codes.ClaimStore(path).redeem(code, DEV_A)
    out = run_cli(path, "list").stdout
    assert "bound" in out and DEV_A[:8] in out and "shelf" in out
    assert code not in out
    assert claim_codes.normalize(code) not in out
