# Build input pinning — where the pins live and how to bump one

Decision record: `docs/architecture/0009-build-input-pinning.md`.
Phase 7.2 exists because an unpinned input moved and broke a build nothing in this
repo had touched (issue #137). This page is how that stays fixed.

**The one rule.** Every bump below has a re-verification obligation attached to it.
A pin whose bump procedure is "change the number" is not a pin — it is a comment.
If you are in a hurry and read only one section, read
[Bumping the kernel](#bumping-the-kernel).

---

## Where each pin lives

| Input | Pinned in | Mechanism |
|---|---|---|
| Raspberry Pi kernel | `third_party/kernel/manifest.yml` | six pool URLs + sha256, fetch-at-build |
| Debian packages | `overlays/pi-gen/stage0/00-configure-apt/files/sources.list`, `overlays/pi-gen/stage0/prerun.sh`, `PIGEN_SNAPSHOT` in `scripts/build-image.sh` | `snapshot.debian.org` timestamp |
| pi-gen itself | `PIGEN_REF` in `scripts/build-image.sh` | git tag |
| Overlay integrity | `overlays/pi-gen/MANIFEST` | upstream + overlay sha256 per file |
| axcl host driver | `third_party/axcl/manifest.yml` | sha256, `url: null` (rights unresolved) |
| Node | `third_party/node/manifest.yml` | sha256, fetch-at-build |
| ax-llm | git submodule | gitlink commit |
| Models | `third_party/models/manifest.yml` | sha256 (three are still `TODO` placeholders) |

Everything that merely *resolves* — roughly 220 Debian packages nobody chose
individually — is not pinned but is **recorded**, in
`docs/operations/phase-07.2-inputs.reference`, and diffed on every build. See
[Reading an input manifest diff](#reading-an-input-manifest-diff).

---

## Bumping the kernel

**A kernel bump is never just a number.** That is the entire lesson of issue #137:
`pci_resize_resource` gained a fourth `exclude_bars` parameter between 6.12.96 and
6.12.109, the vendored axcl 3.10.2 driver passes three, and the out-of-tree module
stopped compiling at `ax_pcie_dev_host.c:220`. No change on our side. You must
re-prove the axcl compile before you can trust a new kernel.

1. Find the new version's six debs in the pool under
   `https://archive.raspberrypi.com/debian/pool/main/l/linux-<version>/`. All six
   are required: `linux-image` and `linux-headers` for **both** flavours
   (`rpi-2712`, `rpi-v8`), plus `linux-headers-<v>-common-rpi` and
   `linux-kbuild-<v>`.

   Both flavours are non-negotiable. Pinning only `rpi-2712` leaves
   `linux-headers-rpi-v8` to resolve, which drags the *other* version's common
   headers back into `/usr/src` and re-creates the ambiguity the pin removes.

2. Record each `url`, `sha256` and `size` in `third_party/kernel/manifest.yml`,
   and update `version` and `expected_module_dirs`. Do not transcribe digests from
   a plan document or a chat message — fetch each deb and hash it yourself, and
   cross-check against the archive's own `SHA256:` field in
   `dists/bookworm/main/binary-arm64/Packages.gz`.

3. Verify the fetch and the digests:

   ```
   ARLOWE_KERNEL_FETCH=1 scripts/verify-third-party.sh
   ```

   This writes `build/.arlowe-kernel-cache`, the pointer `build-image.sh` requires.
   It deletes that pointer on any failure rather than leaving it aimed at an
   unverified directory, so a failure here aborts the next build instead of
   quietly feeding it the wrong debs.

4. **Re-prove the axcl compile.** Destroy the work dir (see
   [Before any full build](#before-any-full-build)) and run a complete image build.
   Then confirm the module exists and was built against the new kernel:

   ```
   sudo find "${WORK_DIR}/stage-arlowe/rootfs" -name '*.ko' -path '*ax*'
   sudo modinfo <that .ko> | grep vermagic
   ```

   `vermagic` must name the new version. A `.ko` built against a different
   `vermagic` will refuse to load on the device — a silent failure that a green
   build will not catch. `00-run-chroot.sh` treats a missing `.ko` as a hard
   failure for this reason.

5. Expect an input manifest diff on the `pin` rows and on `kernel_version`, and
   accept it deliberately (see below).

### Why the Pi side uses pool URL plus checksum

Three reasons, and only these three:

1. **The digest is the pin.** An index entry is whatever the archive serves today;
   a recorded digest is a claim that can be falsified.
2. **The local cache makes a rebuild independent of the archive** still being
   reachable, and of what it still retains.
3. **There is no Raspberry Pi snapshot service.** `snapshot.raspberrypi.com` and
   `snapshot.raspberrypi.org` both return HTTP 000 from the build host, so the
   Debian-side mechanism is simply unavailable here. That is why the two halves of
   this phase use different mechanisms.

**Do not justify this by claiming the Pi archive index retains just one version per package.**
That premise was measured and refuted: `dists/bookworm/main/binary-arm64/Packages.gz` carries eleven
`linux-image-*-rpt-rpi-2712` versions, 6.12.19 through 6.12.109, including every
version pinned here. What carries exactly one version is the **meta** package
(`apt-cache madison linux-headers-rpi-2712` → `1:6.12.109-1+rpt1`). That is why the
four meta packages are *removed* from the overlay's `stage0/02-firmware/01-packages`
rather than version-constrained — there is no older candidate to pin them to — and
it is **not** the reason we fetch by pool URL.

**What can actually change, and therefore what to watch: pool RETENTION of
6.12.96.** The pool retains 6.12.19 through 6.12.109 today, but that is Raspberry
Pi's retention policy and not a guarantee to us. The `url` field is how to obtain
each deb the *first* time; the sha256 is the pin and the local cache is what makes a
rebuild durable. **Mirror the six pinned debs somewhere the project controls** —
when retention lapses it will lapse without notice, and a project that has only the
pool URL has only a 404.

---

## Bumping the Debian snapshot

The timestamp lives in **three** production locations, not two. Change them together:

1. `overlays/pi-gen/stage0/00-configure-apt/files/sources.list` — six lines (three
   active, three commented `deb-src`).
2. `overlays/pi-gen/stage0/prerun.sh` — the `bootstrap` URL. This is what
   **debootstrap** uses. Missing this one is the dangerous case: apt would resolve
   from the new snapshot while the base system came from the old one, and nothing
   would look wrong.
3. `PIGEN_SNAPSHOT` in `scripts/build-image.sh` — the post-build gate's expected
   value. This is deliberately an independent copy rather than something derived
   from the overlay: a gate that derived its expectation from the thing it checks
   would agree with it by construction and measure nothing. Missing this one fails
   the build loudly, which is the intended behaviour.

Then re-record the MANIFEST digests for the two changed overlay files (by hand —
see [Bumping PIGEN_REF](#bumping-pigen_ref) for why there is no helper), re-run the
resolve-twice check, and accept the resulting input diff:

```
tests/phase-07.2/resolve-twice.sh
ARLOWE_INPUTS_ACCEPT=1 scripts/record-build-inputs.sh \
    --diff build/arlowe-inputs.manifest \
    --reference docs/operations/phase-07.2-inputs.reference
```

**The snapshot is a maintenance obligation, not a set-and-forget.** A pin nobody
ever advances becomes an image full of unpatched packages. Decide and record an
advance policy; see the open question at the foot of this page.

---

## Bumping `PIGEN_REF`

`PIGEN_REF` is pinned to a bookworm tag deliberately: pi-gen master targets trixie,
whose `debian.sources` names the keyring `.pgp` (bookworm ships `.gpg`) and whose
stage2 pulls trixie-only `rpi-*` packages. Both break a `RELEASE=bookworm` build.

When you bump it, the overlay's `upstream_sha256` assertions **will fail by design**
— but only **on the re-clone path**. This distinction matters more than it looks:

> On a cached pi-gen tree the applier sees its own prior output (`overlay_sha256`)
> and accepts it. An ordinary build therefore does **not** re-check upstream. The
> alarm is a `PIGEN_REF`-bump alarm, not a per-build one.

An operator who expects otherwise will read its silence as reassurance that upstream
has not moved. It is not that. To actually re-check upstream you must force the
re-clone (remove `pi-gen/.arlowe-pigen-ref`, or the `pi-gen/` tree).

The failure you will see names the file and all three digests:

```
[FAIL] Upstream pi-gen changed under the pin: stage0/prerun.sh
[FAIL]   expected upstream: <old upstream sha256>
[FAIL]   or our overlay:    <our sha256>
[FAIL]   found:             <what the new ref ships>
```

The correct response, in order:

1. **Read the new upstream file.** Diff it against the old upstream content.
2. **Decide whether our change still makes sense** against it. Upstream may have
   restructured the thing we were overriding, or fixed the reason we overrode it.
3. **Re-record** `upstream_sha256` in `overlays/pi-gen/MANIFEST`, and re-make our
   change against the new content if it moved.

Explicitly: **do not delete the assertion**, and **do not blindly re-record without
reading**. There is deliberately no regenerate-the-digests helper — one would be
reached for to silence the alarm rather than to investigate it. That absence is the
feature.

Two neighbouring failures worth recognising:

- `Unexpected pre-existing file: <path>` — the MANIFEST records the entry as `NEW`
  but upstream now ships something there. Read it before overwriting; record its
  upstream digest instead of `NEW`.
- `Overlay target missing from the pi-gen tree: <path>` — upstream removed or moved
  a file we override. Re-read the upstream tree and re-record.

---

## Before any full build

**Destroy the work dir.** This is not housekeeping; it is correctness.

```
sudo rm -rf "${WORK_DIR:-build/pi-gen-work}"
ls build/pi-gen-work 2>&1        # must report: No such file or directory
```

pi-gen guards every expensive step on the rootfs already existing —
`stage0/prerun.sh` wraps bootstrap in `[ ! -d "${ROOTFS_DIR}" ]`, and
`stage1`/`stage-arlowe` guard `copy_previous` the same way. `build-image.sh` only
`mkdir -p`s the work dir and never cleans it. So a build against a surviving tree:

1. **Skips debootstrap entirely**, defeating the Debian snapshot pin — the base
   system stays whatever it previously rolled to.
2. **Leaves both kernels installed.** Because the pinned and unpinned kernels are
   differently-*named* packages (`linux-image-6.12.96+rpt-rpi-2712` versus
   `linux-image-rpi-2712`), apt has no reason to remove the old one. This is the
   direct build-procedure consequence of the prevent-don't-downgrade design: the
   property that makes the pin un-driftable also means an unclean tree accumulates
   rather than replaces.
3. **Selects the wrong kernel.** `stage-arlowe/01-runtime/00-run-chroot.sh` picks
   `IMG_KVER` with `find /lib/modules -name '*-rpi-2712' | sort -V | tail -1` — the
   *newest* present. The axcl compile then fails roughly 25 minutes in, and the log
   reads exactly like "the pin did not work" when in fact the pin was never given a
   clean tree.

That third failure is indistinguishable from a real defect in the pinning mechanism.
Budget the debootstrap time; it is the thing being tested.

A full build takes ~30 minutes on the arm64 build host and requires loop devices and
privileged mounts. It cannot run on macOS.

---

## Reading an input manifest diff

`scripts/record-build-inputs.sh --rootfs` writes
`build/arlowe-inputs.manifest` from the **built rootfs**, and the build diffs it
against the committed reference. Exit codes: `0` identical, `1` differs (build
aborts, diff already printed), `2` no reference committed yet (warn and continue).

Row types, and what a change in each means:

| Row | Source | A change means |
|---|---|---|
| `pkg <name> <version>` | observed in the rootfs | Something we do **not** pin moved. Either the snapshot advanced, or a pin bump pulled different dependencies. Explainable by an accompanying change, or it is drift worth investigating. |
| `pin <artifact> <digest>` | declared in this repo | Someone changed a manifest. **A `pin` change with no corresponding manifest edit in the same diff means a cache was tampered with** — the recorder read a digest the repo does not declare. Treat it as a supply-chain event, not a merge conflict. |
| `debian_snapshot`, `kernel_version` | observed in the rootfs | The pin bump landed. Expected alongside a deliberate bump; alarming alone. |
| `pigen_ref` | declared | `PIGEN_REF` bump. |
| `source_date_epoch`, `worktree_clean` | environment | See the caveat below. |

Accept a deliberate bump, and commit the re-recorded reference **in the same change
as whatever caused it**:

```
ARLOWE_INPUTS_ACCEPT=1 scripts/record-build-inputs.sh \
    --diff build/arlowe-inputs.manifest \
    --reference docs/operations/phase-07.2-inputs.reference
```

Never hand-edit the reference. It is a baseline a gate diffs against; an edited
baseline asserts something no build ever produced. The recorder refuses three
specific poisonings for the same reason: zero `pkg` rows, an unpinned
`sources.list`, and a missing epoch.

**Caveat — the gate is currently strict about environment rows.**
`source_date_epoch` is derived from the commit, and the diff is a whole-file
`diff -u`, so **every commit changes it and therefore every build from a new commit
reports a difference** even when nothing about the resolved inputs moved. Until that
is narrowed, expect to re-accept the reference routinely, and read the *body* of the
diff rather than its exit code — a diff whose only changed lines are
`source_date_epoch` / `worktree_clean` carries no information about build inputs.
This is a known sharp edge, not the intended steady state; see the open question
below.

Likewise `worktree_clean false` in a recorded reference means that baseline was
captured from a dirty tree. Do not freeze one.

---

## Open questions

These are deliberately recorded rather than silently decided:

- **Snapshot advance policy.** `20260915T000000Z` is fixed until someone moves it.
  Scheduled bump, or move only when a security update forces it? A pin nobody
  advances becomes an unpatched image.
- **Environment rows in the diff gate.** Narrowing the diff to the observed/declared
  rows would stop the gate firing on every commit. Widening a gate's silence is
  usually wrong; this is the rarer case where the noise itself is the risk, because
  a gate that fires on noise gets switched off.
- **Pool mirroring, and the cache that is not yet load-bearing.** The six pinned
  kernel debs currently exist only in Raspberry Pi's pool and the build host's
  cache. Neither is a project-controlled archive. Worse, the cache is not
  actually used at install time: `apt-get install ./*.deb` in
  `stage0/02-firmware/00-run.sh` prefers the archive when its index carries the
  same version, and the build log confirms all six were re-downloaded
  (`Need to get 119 MB of archives`). So today the sha256 pin verifies the cache
  while the archive supplies the installed bytes, and a build would fail if the
  pool dropped 6.12.96 even with a full local cache. The version pin is
  unaffected — the package name is version-specific — but closing this is what
  would make reasons 1 and 2 above true in practice.
- **`rpi-v8` flavour.** The device is Pi 5 only. Keeping v8 costs image size and
  doubles the kernel pin surface; it was kept so this phase reproduces the
  known-good rootfs rather than changing what ships.
