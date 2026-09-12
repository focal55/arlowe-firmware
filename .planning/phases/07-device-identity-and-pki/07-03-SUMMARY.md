---
phase: 07-device-identity-and-pki
plan: 03
subsystem: identity
tags: [device-id, sha256, o-excl, atomic-write, sanitize-gate, provisioning]
requires:
  - phase: 04-config-overlay
    provides: arlowe_config's ARLOWE_*_PATH env-override idiom and the pytest layout copied here
  - phase: 07-02
    provides: the python-test and python-floor-bookworm CI jobs that run this suite
provides:
  - "arlowe_identity.py: device-id derivation, per-device entropy, identity-store path constants"
  - "write_secret: the umask-independent O_EXCL writer for every write-once file in the store"
  - "read_metadata / update_metadata: the only sanctioned accessors of identity.json"
  - "resolve_hostname (banlist-safe encoding); install-arlowe-config.sh globs runtime/lib/*.py"
affects: [07-04, 07-06, 07-07, 07-08a]
tech-stack:
  patterns:
    - "Write-once material via O_EXCL + explicit chmod; the one mutable file gets an O_EXCL temp + os.replace"
    - "Structural sanitize-gate safety: encode derived strings so a banned literal is unreachable, not filtered"
key-files:
  created: [runtime/lib/arlowe_identity.py, runtime/lib/tests/test_arlowe_identity.py, runtime/lib/tests/fixtures/identity/]
  modified: [scripts/provision/install-arlowe-config.sh]
duration: 55min
completed: 2026-09-10
key-decisions:
  - "device_id = sha256(f'{source_tag}:{serial}:{entropy.hex()}')[:32]; entropy is load-bearing, closing the Pi-4-era duplicate-serial hole and removing the serial as an enumeration vector"
  - "identity.json is the single documented exception to O_EXCL; update_metadata owns it and write_secret was NOT weakened to accommodate it"
  - "Hostname substitutes 'd' + device_id[:12], making the banlist literal structurally unreachable in --scan-dir mode where .sanitize-allowlist does not apply"
---

# Phase 07 Plan 03: Device Identity Derivation Summary

**An offline, stdlib-only identity module: device-id derived once from rpi-duid (falling back to dt-serial then cpuinfo) plus 32 bytes of per-device entropy, persisted at 0600 through an O_EXCL writer that no later plan may weaken, with identity.json mutated only through an atomic temp-and-replace.**

## Path constants (import verbatim; 07-06/07-07/07-08a depend on them)

```python
IDENTITY_DIR   = Path(os.environ.get("ARLOWE_IDENTITY_DIR", "/var/lib/arlowe/identity"))
DEVICE_ID_PATH = IDENTITY_DIR / "device-id"   # ENTROPY_PATH  = "device-entropy"
KEY_PATH       = IDENTITY_DIR / "device.key"  # CSR_PATH      = "device.csr"
CERT_PATH      = IDENTITY_DIR / "device.crt"  # METADATA_PATH = "identity.json"
SECRET_MODE    = 0o600
```

## Contracts downstream plans must honour

- `write_secret(path, data: bytes) -> None` — O_EXCL + explicit `chmod` + `fsync`. **Raises `FileExistsError` on an existing path.** Sole writer for `device-id`, `device-entropy`, `device.key`, `device.csr`, `device.crt`. To replace key material, unlink first and say why.
- `read_metadata() -> dict` — `{}` when absent, `ValueError` on corrupt JSON. 07-07's `resolve_endpoints` reads through this, never by opening the path.
- `update_metadata(**fields) -> dict` — merges and returns; the **only** sanctioned mutator of `identity.json`. 07-08a's `provision` step 4 would raise `FileExistsError` without it. Atomic (O_EXCL temp at 0600, then `os.replace`), so a power cut never loses `serial_source`/`derived_at` — which `ensure_device_id` never rewrites, because it short-circuits on the persisted id.
- `ensure_device_id() -> str` — idempotent, never re-derives once `device-id` exists.
- `resolve_hostname(template, device_id) -> str` — substitutes `${device_serial}` with `"d" + device_id[:12]`, e.g. `arlowe-d008c0e4cd2ea`. The constant `d` forces a letter after the prefix so the `rg -iF` banlist entry of the form `<prefix>-<digit>` can never match. `ValueError` if the template has no placeholder. Do not simplify to the raw id.

## Test overrides and verification

`ARLOWE_IDENTITY_DIR` relocates the store; `ARLOWE_SERIAL_ROOT` prefixes the serial sources (fixtures at `runtime/lib/tests/fixtures/identity/{all_three,rpi_duid_only,dt_serial_only,cpuinfo_only}`). Both are import-time constants, so tests monkeypatch module attributes too.

25 new cases pass (110 total in `runtime/lib/tests/`), including a 5000-iteration property test that reads the live `scripts/sanitize/banlist.txt` and an atomicity case that patches `os.replace` to fail and asserts the original file is byte-identical with no `.tmp` residue. `scripts/sanitize/check.sh` and `shellcheck` are clean. Net diff 488 lines plus this summary, under the 550 budget.
