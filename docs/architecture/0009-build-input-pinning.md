# ADR-0009: Build input pinning — a tracked pi-gen overlay, and Debian from a snapshot

<!-- status: accepted -->
**Status:** Accepted
**Date:** 2026-09-20
**Phase:** 7.2 (Build input pinning)
**Closes:** Plan 07.2-01; feeds SC2 and SC4

This ADR is **Accepted**. Every claim below was measured, either on the arm64 build host or in a
native arm64 `debian:bookworm` container, and the measurements are quoted inline. Nothing here
rests on inference from documentation.

## Context

IMAGE-03 claims the image's build inputs are pinned. Three of its four components were not
implemented. The consequence arrived as a kernel drifting `6.12.96` -> `6.12.109` underneath a
vendored `axcl` driver, which then failed to compile. Nobody changed a version number; a rolling
index changed underneath one.

The inputs that float live in files upstream pi-gen owns:

| Input | Where it is declared | What it was pinned to |
|---|---|---|
| debootstrap mirror | `stage0/prerun.sh` | nothing — a rolling mirror |
| apt sources for the rootfs | `stage0/00-configure-apt/files/sources.list` | nothing — a rolling mirror |
| Raspberry Pi firmware/kernel | `stage0/02-firmware/01-packages` | nothing — a rolling archive |

`scripts/build-image.sh` re-clones upstream pi-gen at `PIGEN_REF` and restores only `config/` and
`stage-arlowe/`. Editing any of the three files in place is therefore erased on the next
re-provision — and erased *silently*. That is the same failure shape as F7 #18: a mechanism that
stops working without producing a single line of output.

## Decision

### 1. The overlay source lives at `overlays/pi-gen/`, not under `pi-gen/`

This is not cosmetic. Two independent facts make `pi-gen/overlay/` unusable:

- `.gitignore:81` is `/pi-gen/*`, re-including only `/pi-gen/config` and `/pi-gen/stage-arlowe`.
  `git add pi-gen/overlay` is a silent no-op. The PR would carry zero overlay files, CI would
  check out a tree without them, and every "diff under 400 lines" gate would pass *because the
  deliverable is invisible*. A green gate measuring nothing is precisely the defect this phase
  exists to eliminate.
- `scripts/build-image.sh` runs `sudo rm -rf "${PI_GEN_DIR}"` on the re-provision path, two
  statements before the applier would try to read the overlay.

`overlays/pi-gen/` clears both at once: outside the ignore rule, outside the `rm -rf` blast
radius. Every verification in plan 07.2-01 couples the tracked-file count to the MANIFEST record
count, so an invisible deliverable fails loudly rather than passing quietly.

### 2. Whole-file copies with digest assertions, not a `sed` patch step

A `sed -i` against upstream text becomes a silent no-op the day upstream's text changes — the
same silent-green defect in a new costume. A whole-file copy plus a digest assertion cannot
no-op: either the bytes are there or the build stops.

`scripts/lib/pigen-overlay.sh` exports `apply_pigen_overlay <pi_gen_dir> <overlay_dir>`. It reads
`overlays/pi-gen/MANIFEST`, one tab-separated record per entry:

    path<TAB>mode<TAB>upstream_sha256<TAB>overlay_sha256

and hard-fails, naming the path, on four distinct conditions:

1. **Upstream drift** — the target hashes to neither `upstream_sha256` nor `overlay_sha256`.
2. **NEW collision** — the MANIFEST records `NEW` but a differing file already exists.
3. **Copy did not land** — the installed bytes do not match `overlay_sha256`.
4. **Mode did not land** — `stat -c %a` on the installed file does not equal `mode`.

### 3. Recording `upstream_sha256` — and when its alarm can actually fire

The failure this guards is not "the copy failed" (rare) but "someone bumped `PIGEN_REF`, the
upstream file now means something different, and our overlay quietly reverted their change"
(likely, and otherwise invisible). Recording the upstream digest turns a `PIGEN_REF` bump into a
build failure that names the file and demands a human re-read it.

**Be precise about when it fires.** The upstream digest is only meaningful on a tree freshly
cloned at `PIGEN_REF`. On a cached tree the pi-gen directory already carries our overlay, so the
applier sees `overlay_sha256` and must accept it. Rules 1 and 2 both tolerate an already-overlaid
tree for exactly this reason — the build host's pi-gen tree persists, so every build after the
first overlays our own previous output. An applier that demanded pristine upstream digests would
pass its first run and fail every single one after it.

So: **this is a re-clone-path alarm.** A `PIGEN_REF` bump trips it. An ordinary build does not
re-check upstream, and the ADR says so rather than implying otherwise.

### 4. Failure mode 4 exists because pi-gen fails silently on a lost exec bit

`run_stage` guards `prerun.sh` with `if [ -x prerun.sh ]`, and `run_sub_stage` guards
`NN-run.sh` with `if [ -x ${i}-run.sh ]`. An overlay entry that lands without its exec bit is
skipped in total silence — pi-gen logs nothing at all for a non-executable run script. The
MANIFEST therefore records a mode per entry, the applier passes it to `install -m`, and asserts
it afterwards. The mode comes from the MANIFEST rather than from the source file's own bits, so
a checkout that loses the exec bit still produces an executable run script. `tests/phase-07.2/
test-pigen-overlay.sh` pins that behaviour with a fixture whose overlay source is deliberately
`644`.

### 5. The applier is called OUTSIDE the `PIGEN_MARKER` branch

`build-image.sh` has exactly two branches on the marker test, and the cached branch does nothing
but print `pi-gen pinned at ...`. An overlay applied only inside the clone branch would stop
applying the moment a build reuses a cached tree — which is the common case, not the rare one.
The call therefore sits after the `fi`. Plan 07.2-01's verification asserts the *ordering*, not
merely that the call exists, and that assertion was negative-controlled: moving the call inside
the branch in a throwaway copy makes it fail.

### 6. Debian resolves from snapshot `20260915T000000Z`

Both the debootstrap mirror and the rootfs `sources.list` name one fixed
`snapshot.debian.org` timestamp, so bootstrap and every later apt resolution draw from the same
frozen archive.

Mid-September 2026 was chosen because the known-good reference rootfs — the flashed card carrying
`6.12.96+rpt-rpi-2712` — came out of the September rebuild. A snapshot from that window
reproduces the closest thing to a rootfs already proven to boot.

All three suite `Release` URLs return HTTP 200. Note the security suite lives under a **different
archive root** (`archive/debian-security/`, not `archive/debian/`); getting that wrong yields a
404 mid-bootstrap.

### 7. `http://`, not `https://` — deliberately

Measured in a native arm64 `debian:bookworm` container: that base image ships no
`ca-certificates`, so every `https://snapshot.debian.org` index fetch fails TLS verification — and
`apt-get update` **still exits 0**. A downstream drift-detection job comparing two such runs would
compare two empty package lists, find them byte-identical, and report success. The job whose only
purpose is to notice drift passes hardest when it is broken.

Inside the real pi-gen build the https form would probably work, since `bootstrap()` passes
`--include=ca-certificates`. That is the worst of both worlds: survivable in one environment and
silently broken in the other. `http://` everywhere.

Content authenticity is unaffected. It comes from the gpg signature on `Release`/`InRelease`, not
from the transport, and `http` is snapshot.debian.org's documented usage.

### 8. `Acquire::Check-Valid-Until "false"` ships with the pin, in the same change

A snapshot's `Release` file carries a `Valid-Until` in the past by construction. Without this the
build works today and fails roughly a week out with `Release file ... is expired`, which reads
like a network fault rather than a consequence of pinning.

This was verified rather than assumed. With the snapshot sources and the `Release` forced stale:

- without `overlays/pi-gen/stage0/00-configure-apt/files/99arlowe-pinned`, `apt-get update` exits
  **100** and names all three suites as expired;
- with it installed, `apt-get update` exits **0**.

The fragment also raises `Acquire::Retries` and the http timeout: snapshot.debian.org is a single
archival host rather than a CDN, and a bootstrap pulling thousands of index and pool files needs
more patience than apt's defaults allow.

### 9. The rootfs is the evidence; the overlay is only the declaration

Reading the timestamp back out of `overlays/pi-gen/.../sources.list` proves only that we wrote
what we wrote. `build-image.sh` therefore gates on the **built** rootfs, reading nothing from
`overlays/`:

1. an **active** `deb` line in `${PIGEN_ROOTFS}/etc/apt/sources.list` names the snapshot, and
   nothing under `sources.list.d/` declares the rolling mirror;
2. at least one file in `${PIGEN_ROOTFS}/var/lib/apt/lists/` is named for the snapshot host;
3. **zero** files there are named for the rolling mirror.

Assertion 3 is the real check — a rolling-mirror list file present means something resolved
off-pin, and it is the only one of the three that catches a partially-applied overlay.

Three details make these measurable rather than decorative:

- The gate matches `^deb ` rather than the bare hostname. The overlay files carry explanatory
  header comments, and a substring match would be satisfied by a comment.
- For the same reason the rolling mirror's hostname is kept out of the two overlay files that get
  copied into the rootfs, comments included.
- `${WORK_DIR}/stage-arlowe/rootfs` retains its populated `/var/lib/apt/lists`. The only place
  pi-gen deletes them is `export-image/02-set-sources`, which operates on its own copied rootfs.
  This was confirmed against the real rootfs from the previous build, which holds 35 list files.

The expected timestamp is a constant in `build-image.sh`, deliberately an independent copy of the
one in the overlay. Deriving it from the overlay would make the gate agree with whatever the
overlay happens to say, which is not a measurement. If the two drift, the gate fails and a human
reconciles them.

## Scope boundary

**This ADR pins the Debian side only.** The Raspberry Pi archive has no snapshot service —
`snapshot.raspberrypi.com` and `snapshot.raspberrypi.org` both return HTTP 000 from the build
host — and is handled by pool-URL-plus-checksum in plan 07.2-02. Splitting them is deliberate:
different mechanism, different blast radius, and a snapshot outage should not be
indistinguishable from a kernel hash mismatch.

**Why the Pi side uses pool URL plus checksum — stated correctly.** Three reasons, and only
these three:

1. **The digest is the pin.** An index entry is whatever the archive serves today; a recorded
   digest is a claim that can be falsified.
2. **The local cache makes a rebuild independent of the archive** still being reachable, and of
   what it still retains.
3. **There is no Raspberry Pi snapshot service**, so the mechanism this ADR uses for Debian is
   unavailable on the Pi side.

An earlier draft justified the pool fetch by claiming the Pi index retains just one version per
package. **That was measured and refuted** in plan 07.2-02:
`dists/bookworm/main/binary-arm64/Packages.gz` carries eleven `linux-image-*-rpt-rpi-2712`
versions, 6.12.19 through 6.12.109, including every version pinned here. What carries exactly
one version is the **meta** package, which is why the four meta packages are *removed* rather
than version-constrained — there is no older candidate to pin them to. Do not reintroduce the
refuted claim; the risk that is real is **pool retention of 6.12.96**, which is Raspberry Pi's
policy and not a guarantee to us.

**Image-hash equality remains out of scope**, per the existing Phase 6 ADR. What is gated here is
*input* reproducibility: the same inputs resolve on every build. Two builds from the same inputs
are not expected to produce byte-identical images, and nothing in this phase asserts that they do.

## Consequences

- A `PIGEN_REF` bump now fails the build until a human re-reads each overlaid upstream file and
  re-records its digest. That is the intended cost, and it is the entire point.
- There is deliberately **no** regenerate-the-digests helper. One would be reached for to silence
  the drift alarm rather than to investigate it.
- The snapshot timestamp is a maintenance obligation. Advancing it is a deliberate, reviewable
  edit to `overlays/pi-gen/stage0/00-configure-apt/files/sources.list`,
  `overlays/pi-gen/stage0/prerun.sh`, and `PIGEN_SNAPSHOT` in `scripts/build-image.sh` — plus the
  MANIFEST digests. Forgetting any one of them fails the build rather than silently unpinning it.
- Builds are slower. snapshot.debian.org is not a CDN.
- **The build work dir must be destroyed before every full build.** This is a direct
  build-procedure consequence of the prevent-don't-downgrade design above, not incidental
  housekeeping. pi-gen guards its expensive steps on the rootfs already existing
  (`stage0/prerun.sh` wraps bootstrap in `[ ! -d "${ROOTFS_DIR}" ]`), and `build-image.sh` only
  `mkdir -p`s the work dir and never cleans it. Against a surviving tree, debootstrap is skipped
  — defeating the snapshot pin, since the base system stays whatever it previously rolled to —
  and, because the pinned and unpinned kernels are differently-*named* packages, apt has no
  reason to remove the old one, so **both** remain installed.
  `stage-arlowe/01-runtime/00-run-chroot.sh` then selects `IMG_KVER` with `sort -V | tail -1`,
  picks the *newer* kernel, and the axcl compile fails ~25 minutes in with a log that reads
  exactly like "the pin did not work". The property that makes the pin un-driftable is the same
  property that makes an unclean tree accumulate rather than replace. Procedure in
  `docs/operations/phase-07.2-build-pinning.md`.
- Adding a fifth overlay entry means copying the upstream file, making the minimum change, and
  recording both digests by hand. The self-test's `real-manifest` case fails on a stale digest, so
  a forgotten re-record surfaces in CI rather than hours into a build.

## Outcome — what the build actually showed

An ADR that records only the plan teaches the next reader nothing. Plan 07.2-04 ran the
phase's one full build on the arm64 build host at commit `2d57b8b` (2026-09-20), against a
work dir destroyed first. Results:

- **The mechanism worked as designed, first try.** All six overlay entries applied and
  mode-asserted on a *cached* pi-gen tree; debootstrap ran for 3m35s against
  `snapshot.debian.org/archive/debian/20260915T000000Z`; the rootfs carried exactly
  `6.12.96+rpt-rpi-2712` and `6.12.96+rpt-rpi-v8` and nothing else; and the build log contains
  **zero** references to the four kernel meta packages, so nothing resolved a kernel.
- **SC6 — the thing that caused this phase — is fixed.** Five axcl `.ko` files built, all with
  `vermagic: 6.12.96+rpt-rpi-2712`. Zero `too few arguments to function` and zero
  `pci_resize_resource` hits. The `00-run-chroot.sh` line
  `axcl driver build targeting image kernel 6.12.96+rpt-rpi-2712` is the direct counterpart of
  the `6.12.109+rpt-rpi-2712` that broke it.
- **The reference manifest holds 658 packages** and 10 pinned artifacts — noticeably more than
  the ~220 the resolve-twice CI job sees, because that job resolves the declared package set
  while this records everything actually installed in the finished rootfs.
- **Measured rootfs size, for issue #135:** 2,758,905,768 B = **2.57 GiB**, model-free
  (`/usr` 2.0 G, `/opt` 715 M of which venvs 434 M and vendored Node 204 M, `/boot` 102 M).
  This is the first whole-rootfs measurement taken on a real build rather than in a container
  or against an empty directory, and the first that includes `/opt/arlowe/venvs` at all.
  ADR-0004's "≈2-3 GB per slot" survives contact with measurement.

**Three surprises, all worth recording.**

1. **`scripts/build-image.sh` was tracked with a non-executable mode** (`100644`) and had been
   since Phase 6. It ran on the build host only because that working copy carried a stray local
   exec bit. A fresh checkout could not execute the documented invocation at all. Fixed in the
   same plan. This is the same failure shape as decision 4 above — a lost exec bit is silent —
   arriving through version control rather than through the overlay.

2. **The Phase 7.1 unit substrate gates read the build host, not the rootfs.** They glob
   `/etc/systemd/system/*.service` and read the results without chroot. Seven of those entries
   are dbus alias symlinks whose targets are *absolute* (`/lib/systemd/system/...`), so the read
   escapes the rootfs. Demonstrated on `dbus-org.freedesktop.nm-dispatcher.service`: the gate
   reported `ExecStart=/usr/libexec/nm-dispatcher` (the trixie host's NetworkManager 1.52.1) and
   failed the build for a missing binary, while the rootfs's own unit declares
   `ExecStart=/usr/lib/NetworkManager/nm-dispatcher`, which is present. This is a Phase 7.1
   defect and is not patched here, but it belongs on this page because it is the same lesson
   decision 9 states for *this* phase's gates — **the rootfs is the evidence** — violated in a
   neighbouring one. A gate that reads the host can return a false pass as easily as this false
   failure.

3. **`apt-get install ./*.deb` re-downloads the pinned debs from the archive.** The build log
   reads `Need to get 119 MB of archives` and carries `Get:` lines pointing at
   `http://archive.raspberrypi.com/...` for all six pinned kernel debs, even though those exact
   files had just been copied into the chroot. Verified in a native arm64 `debian:bookworm`
   container: with the Pi archive index present, `apt-get install --print-uris ./*.deb` resolves
   every one of the six to an `http://archive.raspberrypi.com/debian/pool/...` URI rather than a
   `file:` URI. (A first attempt at this test appeared to show `file:` URIs, but its
   `apt-get update` had failed, so apt had no archive candidate to prefer — the test was
   measuring an empty index, not apt's preference. Worth stating, because it is the same
   measuring-nothing trap this ADR warns about elsewhere.)

   **What this does and does not weaken.** The *version* pin is untouched and remains
   un-driftable: `linux-image-6.12.96+rpt-rpi-2712` is a distinct package name, so only 6.12.96
   can install, and the rootfs assertion confirms it did. What is weaker than it looks is the
   *digest* pin and the *cache* rationale. `verify-third-party.sh` hashes the cached debs, but
   those bytes are then not the bytes installed — so reason 1 above ("the digest is the pin")
   currently covers the cache rather than the installation, and reason 2 ("the local cache makes
   a rebuild independent of the archive") is **not realised**: a build would fail today if the
   archive stopped serving 6.12.96, populated local cache notwithstanding. That is precisely the
   pool-retention risk the manifest names, left unmitigated by the mechanism meant to mitigate
   it. Closing it means changing how `stage0/02-firmware/00-run.sh` installs; it is recorded
   here rather than patched inside a verification plan.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| Edit `pi-gen/` in place | Erased by `rm -rf` + re-clone on the next re-provision, silently. |
| `pi-gen/overlay/` as the source tree | Swallowed by `.gitignore:81`; the deliverable would be untracked and absent from CI. |
| `sed -i` patch step against upstream files | Becomes a silent no-op when upstream's text changes. |
| Fork pi-gen | Whole-repo maintenance burden for four files, and upstream drift becomes invisible instead of loud. |
| Vendor a full Debian mirror | Storage and maintenance cost far beyond the problem. |
| `https://` to snapshot.debian.org | No `ca-certificates` in a stock bookworm environment; index fetches fail TLS and `apt-get update` still exits 0. |
| Derive the gate's expected timestamp from the overlay | The gate would then agree with the overlay by construction, measuring nothing. |
