# Node.js runtime — sourcing

The `arlowe-dashboard` unit runs this Node, not `/usr/bin/node`. Debian bookworm ships 18.20.4
and `bookworm-backports` ships no `nodejs` at all, while `next@16.1.6` requires
`engines.node >= 20.9.0`. Full rationale, including why Node 24 rather than the EOL Node 20 line:
`docs/architecture/0008-image-runtime-dependency-strategy.md`.

## What is pinned

See `manifest.yml`. In summary:

| Field | Value |
|---|---|
| version | 24.21.0 ("Krypton", Active LTS until 2028-04-30) |
| filename | `node-v24.21.0-linux-arm64.tar.xz` |
| sha256 | `6ad1325edbdb5649c379b75a237147a666c95d4f9ae8d340fef2d1575d289ad2` |
| unpacks to | `/opt/arlowe/node` (`--strip-components=1`) |
| interpreter | `/opt/arlowe/node/bin/node` |

The tarball is **never committed**. This is a fetch-at-build pin.

## Getting the bytes

Easiest — let the gate fetch it:

```bash
ARLOWE_NODE_FETCH=1 scripts/verify-third-party.sh
```

This downloads to `/var/cache/arlowe-build/` and then asserts the SHA-256. Fetching never
weakens the pin; the hash is checked either way.

Manual, or for an air-gapped build host:

```bash
curl -fsSL https://nodejs.org/dist/v24.21.0/node-v24.21.0-linux-arm64.tar.xz \
  -o /var/cache/arlowe-build/node-v24.21.0-linux-arm64.tar.xz
```

or place it at `third_party/node/<filename>`, or point `ARLOWE_NODE_TARBALL` at it.

Verify independently against upstream's published sums:

```bash
curl -fsSL https://nodejs.org/dist/v24.21.0/SHASUMS256.txt | grep linux-arm64.tar.xz
```

## Bumping the version

A vendored tarball does not receive `apt upgrade`. When Node 24 publishes a security release,
bump it here deliberately:

1. Pick the new 24.x from <https://nodejs.org/dist/index.json>. Do not move off 24 without
   re-reading the LTS schedule — the current line's end date is in the ADR.
2. Read the new sha256 from that release's `SHASUMS256.txt`.
3. Update `version`, `filename`, `sha256`, `url` and `tarball_root` in `manifest.yml`. All five
   move together; `tarball_root` contains the version string.
4. `install_to`, `node_bin` and `version_floor` do not change — the dashboard unit's `ExecStart`
   and plan 07.1-03's floor gate both depend on them being stable.
5. Re-run `scripts/verify-third-party.sh`.

## License

Node.js core is MIT. The tarball bundles third-party components under their own terms; the
`LICENSE` file at the root of the extracted tree carries the full set and is preserved by the
unpack into `/opt/arlowe/node`.
