# ADR-0010: Pi archive pinning — a generated manifest installed from a local flat repo

<!-- status: proposed -->
**Status:** Proposed
**Date:** 2026-09-26
**Phase:** 7.3 (Pi archive snapshot)
**Supersedes in part:** ADR-0009, for the Raspberry Pi archive side only

This ADR is **Proposed**. The mechanism is fixture-tested and CI-tested, but no full pi-gen build
has yet run with it. Plan 07.3-09 moves it to Accepted with build evidence, or amends it.

## Context

Phase 7.2 pinned Debian to a snapshot and the kernel to six digest-checked debs. Everything else
the rootfs took from `archive.raspberrypi.com` still floated. Measured against the 07.2 reference
(a real build):

- **97 installed packages come only from the Pi archive** at their installed version: 6 kernel
  debs and 91 others (about 111 MiB), 55 arm64 and 42 all. 565 are Debian-only, none are in both
  archives at the same version, and one (`axclhost`) is in neither.
- **The Pi index carries one version per name for almost everything** (2103 names in 2113
  stanzas). Once Pi publishes a rebuild, the old version leaves the index, although the pool
  still holds its bytes. apt preferences therefore cannot select a superseded version.
- **There is no Pi snapshot service.** The Debian mechanism from ADR-0009 is unavailable.
- **The 07.2 diff gate only detected drift.** Every Pi publish changed a `pkg` row in the
  reference, so every publish forced a re-record, and the gate verified no bytes. A drift you
  must accept to keep building is a drift you learn to accept.

## Decision

1. **A generated manifest, one line per package.** `third_party/pi-archive/manifest.yml` holds
   91 packages and one `resolve_only` entry, each with name, version (epoch included), arch,
   filename, size, sha256 and pool URL. `scripts/lib/pi-archive-manifest.py` generated it from
   the 07.2 reference crossed with an apt-verified Pi index. Nothing in it is hand-typed.
2. **A host-side flat repo of verified bytes.** `verify-third-party.sh` check 8 fetches (opt-in,
   `ARLOWE_PI_ARCHIVE_FETCH=1`) and sha256-verifies every deb into a cache.
   `scripts/lib/pi-archive-repo.sh` copies them into `build/pi-archive-repo` and indexes them
   with `dpkg-scanpackages`.
3. **`[trusted=yes]`, because the trust anchor is the committed digest.** It is enforced twice:
   the repo builder cross-checks every `Packages` SHA256 against the manifest, and apt enforces
   that `Packages` SHA256 at install. A signing key would only prove that the build host signed
   what the build host generated.
4. **The stage0 overlay swaps the source.** `stage0/00-configure-apt/00-run.sh` copies the repo
   into `/var/local/arlowe-pi-archive`, re-verifies the copy and writes the only Pi source. pi-gen's
   `copy_previous` carries it through stage1, stage2 and stage-arlowe with no upstream edits.
5. **An in-build gate and a two-direction check.** `build-image.sh` asserts that no active Pi
   source is declared, that a flat-repo list exists and that no `archive.raspberrypi.com_*` list
   survives. The completeness check then proves every manifest package is installed at its pinned
   version (this catches silent substitution by a Debian version), and that every installed
   package is attributable to the flat repo, a snapshot list, the kernel manifest or the local
   allowlist.
6. **Two modes.** `ARLOWE_PI_ARCHIVE_MODE=pinned` is the default and the only mode that produces
   an image. `record` resolves from the live archive, writes `build/pi-archive.manifest.candidate`
   from the rootfs's own dpkg status and apt-verified lists, prints its diff and exits 3 before
   the Pi gate and partitioning. Record mode still verifies the current pins at Step 1, by
   design: a gate that a mode flag can switch off is a gate that gets switched off.
7. **Swap back before measurement.** After the gate, `pi_archive_swap_back` removes the repo and
   its source and installs pi-gen's stock `raspi.list` with `RELEASE` substituted, so the shipped
   file is byte-identical to stock Pi OS.

Bumping pins is record build, reviewed diff, commit, pinned build, per
`docs/operations/phase-07.3-pi-archive-pinning.md`. There is deliberately no regenerate-and-commit
helper for the pinned gate.

## SC3: what is folded and what stays separate

**rpt-packages is folded in.** Its three pins (`raspi-firmware`, `python3-lgpio`,
`python3-rpi-lgpio`) are rows of the generated manifest at the same bytes. `third_party/rpt-packages/`
and its bash check are deleted.

**The kernel keeps its own manifest.** `third_party/kernel/manifest.yml` and
`stage0/02-firmware/00-run.sh` stay. They share this phase's guarantees: no live Pi source during
the build, the same cache and verify pattern, and the same completeness check, which counts the
kernel manifest as a legitimate origin. They stay separate for three reasons:

- **The bump procedure differs.** A kernel bump needs the axcl driver compile re-proven against
  the new headers and `expected_module_dirs` updated. A Pi pin bump needs neither.
- **The meta packages are deliberately in no repo.** The kernel is installed from files by name,
  and the four meta packages are removed so that nothing resolves a kernel at all. The flat repo
  is an ordinary apt source; moving the kernel into it would mean installing by name through apt
  and changing `00-run.sh`, for no gain in what is pinned.
- **A wholesale Pi regeneration must not be able to move the kernel.** A record build rewrites
  every Pi row at once. Keeping the kernel out of that file means a routine bump cannot carry a
  kernel change past the axcl re-proof.

**Expected kernel side effect, to be confirmed in the 07.3-08/09 Outcome.** With no Pi source visible,
`apt-get install ./*.deb` should install the local kernel debs rather than download the archive
copies, closing ADR-0009's "Need to get 119 MB" open question. This is an expectation from the
mechanism, not an observation. The kernel install's download size in the checkpoint build log
confirms or refutes it.

## Device apt stance

The shipped rootfs has the stock `raspi.list` and the Raspberry Pi keyring, for four reasons:

1. It keeps the device identical to stock Pi OS for on-device debugging (`apt install i2c-tools`).
2. The update channel is the A/B image, not apt.
3. Shipping no Pi source breaks every on-device Pi package install for no gain.
4. Shipping the flat repo would cost about 170 MiB of the slot.

An on-device `apt upgrade` mixes the rolling Pi archive with the frozen Debian snapshot the image
ships. It is unsupported, not an update mechanism. Slot B is an rsync clone of slot A, so it
inherits the same stance.

## Consequences

- **(a) Security fixes to Pi-archive packages now arrive only through a pin bump.** Pi's `+rptN+deb12uM` rebuilds of
  glibc, pam, NetworkManager and bluez outrank every Debian `+deb12uN`, so a Debian advisory
  reaches the image only when Pi rebuilds and the pins move. openssl's `~deb12u2+rpt1` is the
  opposite: a newer Debian upload outranks it, and a snapshot bump alone would flip its origin to
  Debian, which the completeness check then fails. A Debian snapshot bump and a Pi pin bump must
  be evaluated together. The runbook has the watch list and procedure.
- **(b) An rpi-eeprom bump flashes the fleet.** `rpi-eeprom-update.service` runs at boot and
  writes the pinned package's `default` bootloader to any device with an older EEPROM. That write
  sits outside A/B rollback; slot B cannot undo it. Whether to mask the service is a separate
  product decision, and this phase does not change it.
- **(c) "Bytes the project controls" holds only in a weak sense until a durable mirror exists.**
  Today the only copies of the pinned debs are the build host's cache and a CI cache that GitHub
  evicts after 7 days unused. `pi-archive-retention.yml` probes the pool daily, so a prune is
  noticed, but noticing does not preserve anything. If Raspberry Pi prunes a pinned version and
  both caches are lost, the pinned image cannot be rebuilt. A durable mirror is a p1 follow-up;
  `ARLOWE_PI_ARCHIVE_DIR` makes it pluggable without code changes.
- **(d) CI determinism covers part of the package set.** `resolve-twice.sh` resolves the stage0
  firmware list and stage-arlowe's list against the flat repo. Upstream stage1 and stage2 lists
  are not in the checkout, so Pi packages that enter only there (gpiozero, pigpio, rpi-eeprom,
  raspi-utils) are covered by the full build's gate, not by CI.
- **(e) Two paths still resolve against the live Pi archive and carry none of these pins.**
  `.github/workflows/build-image.yml` drives an unpinned pi-gen action that bypasses the overlay
  entirely, and `tests/phase-07.1/docker/Dockerfile` declares
  `deb [trusted=yes] http://archive.raspberrypi.com/debian bookworm main` for the import-check
  container. Both are tracked as follow-ups. Neither produces a shipped image today.
- **(f) SKIP_IMAGES.** Believed a no-op at PIGEN_REF by code reading; 07.3-08 confirms or
  refutes it from a build log; the fix is tracked as a separate issue.
- **(g) The axclhost exemption.** stage-arlowe leaves `axclhost` half-configured on purpose,
  because its postinst cannot modprobe in a chroot. `PI_LOCAL_PACKAGES` in
  `scripts/lib/pi-archive-gate.sh` exempts it, and only it, from the dpkg-state check. That is
  safe because it is always attributed as local, never to an archive. Any other unfinished
  package fails the gate.
- **(h) Record mode is fixture-proven only.** It has never run inside pi-gen. The first real
  pin bump is its first end-to-end use, so a surprise there should be read as a defect in record
  mode before it is read as a change in the archive.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| apt preferences (`Pin: version`) against the live archive | The index drops superseded versions, so a preference cannot select them; it also verifies no bytes. |
| Signing the flat repo | Proves only that the build host signed its own output. The committed sha256 is the anchor, and apt already enforces it. |
| Bind-mounting the repo per stage | pi-gen unmounts everything at each stage boundary; re-mounting needs two more upstream overlay entries. A copy rides `copy_previous` for free. |
| A record build for the first manifest | The 07.2 reference already is a real build's resolution, and all 97 Pi rows still resolved in the live index. A second hardware build would have proven nothing more. |
| Overlaying `stage2/02-net-tweaks/00-packages` to drop the `firmware-marvell-prestera-` marker | Behaviour-preserving in pinned mode, but a record build would then install 61 MB of prestera firmware. A `resolve_only` entry keeps both modes honest. |
