# axcl Host Driver — Distribution Rights Investigation

## Subject

`axcl_host_aarch64_V3.10.2.deb` — the Axera AXCL kernel modules and userspace
runtime required by the AX8850 NPU over PCIe (M.2 form factor).

SHA-256 (verified on arlowe-1.local, 2026-05-01):
`1d6bd551644df30e39e3adbe3f32ab9b1d4cdc9c9d12752c27ebc99b35725b94`

## Vendor

**Axera Semiconductor** (`axera-tech.com`). The AXCL package is the host-side
companion to the AX8850 chip that powers Arlowe's NPU (the same chip that runs
`ax-llm`). The package ships the kernel module that exposes the PCIe device
plus a userspace runtime (`axcl-smi`, shared libraries, etc.).

## Public Download URL

No public download URL was located during research. Axera does not publish
this package via a stable public URL — it appears to ship the `.deb` directly
to hardware partners or through private channels. The copy on `arlowe-1.local`
arrived via the Axera evaluation board provisioning process; the original
download location was not recorded.

## License Investigation

The package control metadata was not accessible without connecting to
`arlowe-1.local` at plan-09 execution time. Based on prior research:

- The `ax-llm` project (also by Axera) is BSD-3-Clause.
- AXCL kernel modules are likely proprietary; Axera does not publish
  source under an open-source license.
- No explicit redistribution grant was found in any Axera public
  documentation, GitHub repo, or website searched during research.

**Conservative assumption: redistribution is NOT permitted** until Axera
explicitly grants it in writing or via a public license statement.

## Decision

**Strategy C — User-supplies-file at image build.**

Rationale:
- Redistribution rights are unresolved and cannot safely be assumed.
- Strategy A (commit to repo) and Strategy B (host on S3/release asset)
  both involve redistribution, which requires explicit permission.
- Strategy C carries no redistribution risk: the `.deb` is never stored
  in this repo or on infrastructure we control. The image build script
  requires the operator to supply the file from their own copy (obtained
  directly from Axera).
- `scripts/verify-third-party.sh` enforces the SHA-256 pin before the
  image build proceeds, ensuring version integrity without redistribution.

If Axera publishes the `.deb` under a permissive license or provides a
stable public URL in the future, revisit this decision:
1. Update this document with the URL and license citation.
2. Set `url:` in `manifest.yml`.
3. Update `scripts/verify-third-party.sh` to fetch from that URL.
4. Switch to Strategy B.

## Upgrade Path

When Axera releases a new driver version:
1. Obtain the new `.deb` from Axera.
2. Compute `sha256sum axcl_host_aarch64_<version>.deb`.
3. Update `manifest.yml` (version, filename, sha256).
4. Update this file if sourcing or licensing details changed.
5. Test on a Pi 5 dev unit; confirm `axcl-smi` reports the device.
6. Open a PR with the manifest update.

## Contacts / References

- Axera GitHub org: https://github.com/AXERA-TECH
- ax-llm project (BSD-3-Clause): https://github.com/AXERA-TECH/ax-llm
- AXCL documentation: shipped with the evaluation board; not publicly indexed.
