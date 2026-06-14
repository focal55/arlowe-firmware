# Phase 6 reproducibility posture and exception list

**Status:** Reference for ADR-0004 SC5 and IMAGE-03.

---

## Posture: best-effort, no hash gate

The arlowe v1 image build is **best-effort reproducible**. Build inputs are
pinned to maximise determinism, but residual sources of non-determinism prevent
bit-for-bit identical `.img` files across independent builds. As a result:

- There is **no image-hash CI gate** in v1.
- The build is verified for correctness (five partitions, slot A model-free,
  sanitize gate passing, slot-B recovery stub present, tryboot config correct)
  but not for byte-level hash identity.
- The decision to defer a hash gate is intentional and documented here rather
  than silently accepted.

---

## Pinned inputs

The following inputs are pinned to maximise reproducibility:

| Input | How pinned |
|-------|-----------|
| Debian base release | `RELEASE=bookworm` in `pi-gen/config` |
| Debian package versions | `SOURCE_DATE_EPOCH` set at build time (see below); package versions are frozen by pi-gen's apt resolver at the run date — further pinning requires a Debian snapshot repo URL |
| axcl host deb | SHA-256 pinned in `third_party/axcl/manifest.yml`; verified by `verify-third-party.sh` before build |
| ax-llm submodule | Pinned commit in `.gitmodules`; verified by `verify-third-party.sh` |
| Model artifacts (Qwen, Whisper, Piper) | SHA-256 pinned per-artifact in `third_party/models/manifest.yml`; verified by `verify-third-party.sh` |
| pi-gen version | `pi-gen-version: arm64` branch in `.github/workflows/build-image.yml` |

### SOURCE_DATE_EPOCH

Setting `SOURCE_DATE_EPOCH` causes tools that respect it (gzip, tar, ar,
dpkg-deb, Python) to use a fixed timestamp rather than `now`. The build sets
it to the commit timestamp of the tag being built:

```bash
export SOURCE_DATE_EPOCH="$(git log -1 --format=%ct)"
```

This is not applied automatically; the CI workflow passes it through the
environment. Local builds should set it manually for best reproducibility.

### Debian snapshot pinning (not applied in v1)

Full package pinning requires replacing the default Debian mirrors with
`snapshot.debian.org` URLs at a specific date, e.g.:

```
deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/20250101T000000Z/ bookworm main contrib non-free non-free-firmware
```

This is **not applied in v1** because snapshot.debian.org has rate-limit and
availability issues that make it unreliable in CI. If deeper reproducibility is
needed in a future phase, this is the mechanism.

---

## In-chroot non-determinism stripped

The pi-gen stage-arlowe chroot strips the following before the rootfs is
exported:

| Item | Why stripped |
|------|-------------|
| `/etc/machine-id` | Regenerated unique per device on first boot |
| `/var/log/**` | Log timestamps are non-deterministic |
| `apt` package cache (`/var/cache/apt/archives/*.deb`) | Not needed in the image; removed by pi-gen's cleanup stage |
| `__pycache__/` and `*.pyc` | Python compile timestamps are non-deterministic |
| SSH host keys | Regenerated unique per device on first boot |
| `/etc/arlowe/config.yml` | Factory image ships without founder identity (Phase 8 pairing writes it) |

---

## Residual exception list (defeats bit-for-bit hashing)

The following are **known, accepted** sources of non-determinism that make
bit-for-bit `.img` comparison unreliable. They are not bugs; they are
properties of the tools and formats used.

### 1. ext4 filesystem internals

`mkfs.ext4` and `resize2fs` embed the creation timestamp, a random filesystem
UUID (unless overridden), and inode allocation order that can vary by kernel
version and filesystem feature flags. Even with `mkfs.ext4 -E hash_seed=...
-U <fixed-uuid>`, block-level inode bitmaps can differ between runs if
directory entries are created in a different order.

**Impact:** All three ext4 partitions (slot A, slot B, models) will not be
byte-identical across independent builds.

**Mitigation:** Use a fixed `-U` UUID (currently not applied in v1). Apply if
a hash gate is introduced in a later phase.

### 2. dpkg installation order

Even with a fixed package list and `SOURCE_DATE_EPOCH`, `dpkg` may install
conffiles in a non-deterministic order depending on the resolver. The resulting
`/var/lib/dpkg/info/` state varies.

**Impact:** Slot A rootfs filesystem content can vary at the byte level.

**Mitigation:** None applied in v1. Acceptable at current scale.

### 3. First-boot-regenerated material

The following are intentionally absent from the image and regenerated on first
boot:
- SSH host keys (`/etc/ssh/ssh_host_*`)
- `/etc/machine-id`
- `/var/lib/arlowe/.models-grow-done` sentinel (written by `arlowe-grow-models.sh`)
- `/etc/arlowe/config.yml` (written by Phase 8 pairing)

These files make a freshly booted device non-identical to the raw image at the
filesystem level, by design.

### 4. Grow-to-fill on first boot

The models partition (p5) grows to fill the card on first boot. After first
boot, the filesystem is a different size than in the raw `.img`. This is
intentional and documented in `docs/operations/phase-6-partitions.md`.

---

## Summary: what is and is not verified

| Verified in CI | Not verified in CI |
|---------------|-------------------|
| Five partitions assembled, correct labels and sizes | Byte-for-byte `.img` hash |
| Slot A is model-free (sanitize gate) | Cross-build filesystem identity |
| Slot B recovery stub present | Package version pinning below `RELEASE=bookworm` |
| tryboot boot config correct (ADR-0005) | Snapshot-date-locked Debian packages |
| Third-party dependency SHAs match manifest | |
| shellcheck clean on all build/provision scripts | |

---

## Future: introducing a hash gate

If a hash gate is introduced in a later phase, the prerequisites are:
1. Switch Debian packages to a snapshot.debian.org URL pinned by date.
2. Pin `mkfs.ext4` UUID and creation timestamp via `-U` and `-E`.
3. Fix `dpkg` install order (possibly via a sorted package list and
   `--no-triggers` with a replay pass).
4. Canonicalise `SOURCE_DATE_EPOCH` to the tag commit timestamp in both CI and
   local builds.
5. Strip any remaining non-deterministic metadata via `debugedit` or equivalent.

This is out of scope for v1.
