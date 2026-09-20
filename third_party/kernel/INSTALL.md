# Raspberry Pi kernel — sourcing

The image ships kernel **6.12.96**, installed from six pinned `.deb` files rather than resolved
by apt. Full rationale: `manifest.yml` header and
`docs/architecture/0009-build-input-pinning.md`.

The one-line version: 6.12.109 gained a fourth `exclude_bars` parameter to
`pci_resize_resource`, the vendored axcl 3.10.2 driver passes three arguments, and the
out-of-tree module stopped compiling at `ax_pcie_dev_host.c:220`. Nothing in this repo changed.
6.12.96 is the kernel on the card that boots.

## What is pinned

| Field | Value |
|---|---|
| version | 6.12.96 |
| deb version (filenames) | `6.12.96-1+rpt1` (apt reports the epoch form, `1:6.12.96-1+rpt1`) |
| kernel string | `6.12.96+rpt` |
| flavours | `rpi-2712` (Pi 5), `rpi-v8` (Pi 4) |
| total download | 78,133,728 bytes — about 75 MiB |

Six debs, each with its own `sha256` in `manifest.yml`:

```
linux-image-6.12.96+rpt-rpi-2712_6.12.96-1+rpt1_arm64.deb     32,734,444 B
linux-image-6.12.96+rpt-rpi-v8_6.12.96-1+rpt1_arm64.deb       32,739,088 B
linux-headers-6.12.96+rpt-rpi-2712_6.12.96-1+rpt1_arm64.deb    1,347,420 B
linux-headers-6.12.96+rpt-rpi-v8_6.12.96-1+rpt1_arm64.deb      1,347,400 B
linux-headers-6.12.96+rpt-common-rpi_6.12.96-1+rpt1_all.deb    8,771,560 B
linux-kbuild-6.12.96+rpt_6.12.96-1+rpt1_arm64.deb              1,193,816 B
```

**The debs are never committed to this repo.** This is a fetch-at-build pin, like
`third_party/node`. `third_party/kernel/` holds only this file and `manifest.yml`;
`.gitignore` keeps any `.deb` staged here out of git.

### Why all six, and why both flavours

Upstream pi-gen's `stage0/02-firmware/01-packages` requests both `linux-image-rpi-v8` and
`linux-image-rpi-2712`, plus both headers metas. Pinning only the Pi 5 flavour would leave
`linux-headers-rpi-v8` resolving to the newest version and dragging
`linux-headers-6.12.109+rpt-common-rpi` back into `/usr/src` — reintroducing the exact header
that broke the compile. `linux-headers-*-common-rpi` is architecture-`all` and shared by both
flavours; `linux-kbuild` is required by both headers packages.

Dropping the v8 flavour entirely is plausible for a Pi-5-only device and would halve this pin,
but changing what the image ships is a separate decision from pinning what it already ships.

## Getting the bytes

Easiest — let the gate fetch them:

```bash
ARLOWE_KERNEL_FETCH=1 scripts/verify-third-party.sh
```

The SHA-256 of every deb is asserted whether it was fetched or found, so fetching never weakens
the pin. Without `ARLOWE_KERNEL_FETCH=1` the gate never touches the network; it fails and tells
you where to put the files.

### Search order

For each deb, `scripts/verify-third-party.sh` check 7 looks in:

1. `$ARLOWE_KERNEL_DIR/<filename>`
2. `third_party/kernel/<filename>`
3. `/var/cache/arlowe-build/kernel/<filename>`
4. `${XDG_CACHE_HOME:-$HOME/.cache}/arlowe-build/kernel/<filename>`

On a fetch, the gate tries `/var/cache/arlowe-build/kernel/` first and falls back to the
XDG user cache when `/var/cache` is not writable, saying which it chose. **An unprivileged
build user on a machine that has never run a build can run the fetch.** That matters: a bare
`mkdir: Permission denied` surfacing three lines above an unrelated-looking "not found" is
how the equivalent defect in the Node check cost a build cycle.

Once all six verify, the gate writes the directory holding them to
`build/.arlowe-kernel-cache`. `scripts/build-image.sh` reads that file, exports it as
`ARLOWE_KERNEL_CACHE`, and forwards it across the `sudo` boundary into pi-gen, where
`stage0/02-firmware/00-run.sh` copies the debs into the chroot and installs them. If the six
debs resolved from more than one directory, the gate stages them into a single one first — the
downstream contract is "one directory containing exactly these six files".

### Manual, or for an air-gapped build host

```bash
mkdir -p /var/cache/arlowe-build/kernel
base=http://archive.raspberrypi.com/debian/pool/main/l/linux
for f in \
  linux-image-6.12.96+rpt-rpi-2712_6.12.96-1+rpt1_arm64.deb \
  linux-image-6.12.96+rpt-rpi-v8_6.12.96-1+rpt1_arm64.deb \
  linux-headers-6.12.96+rpt-rpi-2712_6.12.96-1+rpt1_arm64.deb \
  linux-headers-6.12.96+rpt-rpi-v8_6.12.96-1+rpt1_arm64.deb \
  linux-headers-6.12.96+rpt-common-rpi_6.12.96-1+rpt1_all.deb \
  linux-kbuild-6.12.96+rpt_6.12.96-1+rpt1_arm64.deb ; do
    curl -fsSL "$base/$f" -o "/var/cache/arlowe-build/kernel/$f"
done
```

Or drop them in `third_party/kernel/`, or point `ARLOWE_KERNEL_DIR` at wherever they live.

### Verifying independently of us

The archive publishes its own digests. These are a genuinely separate source from the pool
bytes, so comparing all three (index, downloaded file, `manifest.yml`) is a real check:

```bash
curl -sS http://archive.raspberrypi.com/debian/dists/bookworm/main/binary-arm64/Packages.gz \
  | gunzip -c | grep -A20 '^Package: linux-image-6.12.96+rpt-rpi-2712$' | grep '^SHA256:'
```

## Mirror these somewhere you control

**Pool retention is not an archive.** `archive.raspberrypi.com` currently retains 6.12.19
through 6.12.109 in the pool, but that is Raspberry Pi's retention policy, not a commitment to
us. There is no Raspberry Pi snapshot service to fall back on —
`snapshot.raspberrypi.com` and `snapshot.raspberrypi.org` both return HTTP 000 from the build
host. That is precisely why the Debian side of this phase pins to `snapshot.debian.org` and the
Pi side pins by digest plus local cache: only one of the two archives offers a time machine.

The day the pool drops 6.12.96, the `url` fields in `manifest.yml` stop working and the only
copies that still exist are the ones you kept. Before that day:

1. Copy the six debs to durable storage the project controls — object storage, a package
   repository, or a release asset on this repo.
2. Keep the `manifest.yml` `sha256` values as the pin regardless of where the bytes came from.
   A mirror changes the `url`, never the digest.
3. Keep `/var/cache/arlowe-build/kernel/` populated on any long-lived build host. That is what
   makes a rebuild independent of the network entirely.

## Bumping the version

**This is not a number swap.** A kernel bump is a change to the ABI the out-of-tree axcl module
compiles against, and that is exactly what broke last time.

1. Pick the new version and confirm all six packages exist for it in the Pi archive index.
2. Download all six and record their real `sha256` and `size` — read the digests from the bytes
   you fetched, and cross-check against the index's own `SHA256:` field.
3. Update `version`, `deb_version`, `kernel_string`, `expected_module_dirs`,
   `expected_headers_dir`, and every `filename`/`url`/`sha256`/`size` in `manifest.yml`. They
   all carry the version string and they all move together.
4. Update the version strings in `overlays/pi-gen/stage0/02-firmware/00-run.sh` only if that
   script stops deriving them from the manifest. It reads them from the manifest today, and it
   should stay that way.
5. Re-run `scripts/verify-third-party.sh`.
6. **Re-prove the axcl module compile** (phase 7.2 SC6) on real hardware before trusting the
   bump. A green build is not evidence here; the 6.12.109 breakage was a compile failure inside
   a postinst, and the whole point of this pin is that a kernel is only known-good once it has
   booted with the module loaded.

## License

Linux is GPL-2.0, with the standard syscall-boundary exception for userspace. It is freely
redistributable, which is why `url` is populated in `manifest.yml` — unlike
`third_party/axcl/manifest.yml`, whose `url` is `null` because redistribution rights are
unresolved. Each deb carries its copyright file at
`/usr/share/doc/<package>/copyright` inside the installed rootfs.
