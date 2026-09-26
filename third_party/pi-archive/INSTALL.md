# Raspberry Pi archive packages: sourcing

`manifest.yml` pins every package the image installs from `archive.raspberrypi.com`, except
the kernel (`third_party/kernel/`). Each line gives the pool `url`, `size` and `sha256`. The
Debian side is already pinned to a snapshot.debian.org timestamp. The Pi archive has no
snapshot service and its index keeps one version per package, so these digests are the pin.

**`manifest.yml` is generated. Don't hand-edit it.** `tests/phase-07.3/bootstrap-manifest.sh`
regenerates it from `docs/operations/phase-07.2-inputs.reference`, the installed set of a real
build, and a Pi index that apt has verified against the Raspberry Pi archive key. CI
(`tests/phase-07.3/test-pi-archive-committed.sh`) requires every entry to be a `pkg` row of
that reference. A bump therefore re-records the reference in the same change. The procedure
is in `docs/operations/phase-07.3-pi-archive-pinning.md`.

`resolve_only` lists `firmware-marvell-prestera`. It is never installed, but upstream stage2
names it as a removal marker, so apt has to be able to locate it.

**Debs are never committed.** `.gitignore` keeps any `*.deb` staged here out of git.

## Getting the bytes

The full set is 178,122,788 bytes, about 170 MiB. prestera's 61 MB is included.

For each deb, the verify helper searches:

1. `$ARLOWE_PI_ARCHIVE_DIR/<filename>`
2. `third_party/pi-archive/<filename>`
3. `/var/cache/arlowe-build/pi-archive/<filename>`
4. `${XDG_CACHE_HOME:-$HOME/.cache}/arlowe-build/pi-archive/<filename>`

Set `ARLOWE_PI_ARCHIVE_FETCH=1` to download the missing debs from their `url`. The `sha256`
is checked on every deb, whether it was fetched or found, so fetching never weakens the pin.
Without that variable the helper never touches the network.

## Mirror these somewhere you control

Pool retention is Raspberry Pi's policy. It isn't a contract with us. Once the pool drops a
pinned version, its `url` stops working, and the only surviving copies are the ones someone
kept. `ARLOWE_PI_ARCHIVE_DIR` is where a project-controlled mirror plugs in. A mirror changes
where the bytes come from. It never changes the digest.

**Open (p1, owner decision):** where the durable mirror lives. Until that is decided, the
pinned bytes exist only in the build host's `/var/cache/arlowe-build/pi-archive/` and in a
7-day CI cache.

## License

Most of these packages are freely redistributable. `raspi-firmware` (the closed GPU
bootloader) and the `firmware-*` packages carry their own, more restrictive terms. Read
`/usr/share/doc/<package>/copyright` for each one before publishing a mirror anywhere public.
