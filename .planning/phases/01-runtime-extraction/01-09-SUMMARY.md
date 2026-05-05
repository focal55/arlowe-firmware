---
phase: 01-runtime-extraction
plan: 09
type: summary
status: complete
---

# Plan 09 Summary — ax-llm Submodule + axcl Deb Pin

## ax-llm Submodule

- URL: `https://github.com/AXERA-TECH/ax-llm.git`
- Branch: `axcl-context`
- Pinned commit: `df75c34ca2ed8fe55e7576204e4da9c5b5f88ad8` ("修复内存泄漏" — fix memory leak)
- License: BSD-3-Clause (verified upstream)
- Branch rationale: `axcl-context` targets the AXCL PCIe path used by the AX8850 M.2 module on Arlowe-1. The upstream primary branch (`axllm`) uses a different deployment mode and was explicitly not used to avoid breaking the working build.

## axcl SHA-256 Pin

- Filename: `axcl_host_aarch64_V3.10.2.deb`
- SHA-256: `1d6bd551644df30e39e3adbe3f32ab9b1d4cdc9c9d12752c27ebc99b35725b94`
- Source: verified on `arlowe-1.local` via `sha256sum` (2026-05-01 per research)

## Distribution-Rights Decision

**Strategy C — user-supplies-file.** The `.deb` is not committed to the repo.

Reason: No public download URL was located for the Axera AXCL host package. No
explicit redistribution grant was found in Axera's public documentation or GitHub
presence. Strategy C avoids redistribution entirely — the image build requires the
operator to supply the file from their own copy (obtained from Axera), and the
verification script enforces the SHA-256 pin before proceeding.

If Axera publishes the package publicly with a permissive license in the future,
update `third_party/axcl/DISTRIBUTION-RIGHTS.md` and switch to Strategy B
(fetch-by-URL at image build time).

## Verification Gate Readiness

`scripts/verify-third-party.sh` is:
- Executable
- Syntactically valid bash (`set -euo pipefail`)
- Reads pinned SHA-256 from `third_party/axcl/manifest.yml` via python3/yaml
- Resolves `.deb` via `$AXCL_DEB`, `third_party/axcl/`, or `/var/cache/arlowe-build/`
- Checks ax-llm submodule HEAD against `df75c34ca2ed8fe55e7576204e4da9c5b5f88ad8`
- Exits 0 only if both checks pass; prints `[OK]`/`[FAIL]` table

Confirmed: SHA-256 mismatch exits 1 (tested with random bytes). Correct hash
exits 0. ax-llm check passes on the current checkout.

## Requirements Closed

- EXTRACT-09: `third_party/ax-llm` registered as git submodule, branch `axcl-context`,
  pinned at verified commit. Phase 6 image build uses this for building `main_api_axcl_aarch64`.
- EXTRACT-10: `axcl_host_aarch64_V3.10.2.deb` pinned by SHA-256 in `manifest.yml`.
  Hash verified at image build via `scripts/verify-third-party.sh`.

## Phase 1 Smoke Test Impact

None. The binaries are already installed system-wide on `arlowe-1.local` from the
original provisioning. This work blocks Phase 6 (image build), not Phase 1's smoke test.
