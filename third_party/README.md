# Vendored Third-Party Dependencies

This directory contains pinned external dependencies the runtime requires.

## Layout

| Path | Type | Pin |
|---|---|---|
| `ax-llm/` | Git submodule | branch `axcl-context` @ `df75c34c` |
| `axcl/` | .deb manifest | V3.10.2, sha256 `1d6bd551...` |
| `whisplay-driver/` | Provenance placeholder | See `whisplay-driver/PROVENANCE.md` |

## ax-llm

Upstream: https://github.com/AXERA-TECH/ax-llm.git
License: BSD-3-Clause

The AX8850 NPU communicates over PCIe (M.2 form factor) using the AXCL split-build
path. The `axcl-context` branch targets this configuration specifically. The upstream
primary branch (`axllm`) is for a different deployment mode (unified single-binary)
and risks breaking the working build. See `.planning/phases/01-runtime-extraction/01-RESEARCH.md`
§EXTRACT-09 for the full branch decision rationale.

The submodule is pinned to commit `df75c34ca2ed8fe55e7576204e4da9c5b5f88ad8` rather
than the branch tip — this is intentional. The branch tip may advance; we only update
the pin when the new commit has been build-tested on a Pi 5 dev unit.

### Bump procedure

1. Test the new commit on a Pi 5 dev unit:
   ```bash
   cd third_party/ax-llm
   git fetch origin
   git checkout <new-commit>
   bash build_aarch64.sh  # confirm it builds cleanly
   ```
2. Run the smoke test (Phase 1 procedure in `docs/operations/`).
3. If both pass, stage the submodule pointer update:
   ```bash
   cd ../..
   git add third_party/ax-llm
   ```
4. Commit with a summary entry recording the new commit hash, date tested,
   and any changelog notes from the upstream repo.

## axcl Host Driver

`.deb` package providing the AXCL kernel modules and userspace runtime for the
AX8850 NPU.

- Version pinned: `V3.10.2`
- SHA-256 pinned in `axcl/manifest.yml`
- Distribution strategy: **user-supplies-file** (Strategy C). The `.deb` is not
  committed to this repo. See `axcl/DISTRIBUTION-RIGHTS.md` for the full decision.
- Install path on image: installed system-wide via `dpkg -i`. See `axcl/INSTALL.md`.

### Bump procedure

1. Obtain the new `.deb` from Axera.
2. Compute the SHA-256: `sha256sum axcl_host_aarch64_<version>.deb`.
3. Update `axcl/manifest.yml` (version, filename, sha256).
4. Update `axcl/DISTRIBUTION-RIGHTS.md` if sourcing/licensing details changed.
5. Test installation on a Pi 5 dev unit; confirm `axcl-smi` reports the AX8850.
6. Commit the manifest update.

## Verification Gate

`scripts/verify-third-party.sh` runs at image build time (Phase 6). It exits 0
only when all pins match:

- The axcl `.deb` SHA-256 matches the pin in `axcl/manifest.yml`.
- The `third_party/ax-llm` submodule HEAD matches the pinned commit.

Run manually before any image build step:
```bash
scripts/verify-third-party.sh
```

## What Does NOT Live Here

- The axcl `.deb` binary itself — not committed; obtain from Axera.
- The ax-llm build artifacts (`main_api_axcl_aarch64`) — built from source
  during image build (Phase 11 scope).
- The founder's voice verifier model (`hey_arlowe_verifier.pkl`) — never committed;
  this is biometric data. The wake-word scripts live in `runtime/wake-word/`.
