# axcl Host Driver — Install Instructions

## Overview

`axcl_host_aarch64_V3.10.2.deb` installs the Axera AXCL kernel modules and
userspace runtime (`axcl-smi`, shared libraries) that the AX8850 NPU requires.
The `.deb` is not committed to this repo (see `DISTRIBUTION-RIGHTS.md`).
You must obtain it from Axera and place it where the build expects it before
running `scripts/verify-third-party.sh` or the Phase 6 image build.

## Pinned Version

| Field    | Value |
|----------|-------|
| Filename | `axcl_host_aarch64_V3.10.2.deb` |
| Version  | V3.10.2 |
| SHA-256  | `1d6bd551644df30e39e3adbe3f32ab9b1d4cdc9c9d12752c27ebc99b35725b94` |

## How to Obtain the .deb

1. Contact Axera Semiconductor directly or use the provisioning kit that
   came with your AX8850 evaluation board / M.2 module.
2. Confirm the downloaded file matches the pinned SHA-256:
   ```bash
   sha256sum axcl_host_aarch64_V3.10.2.deb
   # expected: 1d6bd551644df30e39e3adbe3f32ab9b1d4cdc9c9d12752c27ebc99b35725b94
   ```
3. If the hash does not match, do not proceed — you have a different version.

## Where to Place the File

The verification script checks these locations in order:

1. `$AXCL_DEB` environment variable (set this for CI or custom paths).
2. `third_party/axcl/axcl_host_aarch64_V3.10.2.deb` (committed strategy — not
   in use, see `DISTRIBUTION-RIGHTS.md`, but the script checks here).
3. `/var/cache/arlowe-build/axcl_host_aarch64_V3.10.2.deb` (default build
   cache location).

For local development / smoke test:
```bash
cp /path/to/axcl_host_aarch64_V3.10.2.deb /var/cache/arlowe-build/
# or
export AXCL_DEB=/path/to/axcl_host_aarch64_V3.10.2.deb
```

## Verification

After placing the file, run the hash-check gate:
```bash
scripts/verify-third-party.sh
```

Expected output on success:
```
[OK]   axcl_host_aarch64_V3.10.2.deb                     sha256 matches
[OK]   third_party/ax-llm                                 @ df75c34c
All checks passed.
```

## Installation on the Target Device

The Phase 6 image build installs the `.deb` into the image:
```bash
dpkg -i axcl_host_aarch64_V3.10.2.deb
```

On a running Pi (manual install for smoke test):
```bash
sudo dpkg -i /path/to/axcl_host_aarch64_V3.10.2.deb
sudo modprobe axcl
axcl-smi  # should report the AX8850 device
```

## On arlowe-1.local (Phase 1 dev unit)

The driver is already installed system-wide on `arlowe-1.local` from the
original provisioning. The Phase 1 smoke test does not require reinstalling it.
This procedure applies to fresh image builds (Phase 6+).
