# F6 — Pin pi-gen version for reproducible image builds

**Origin:** 2026-07-08, Phase 6 hardware checkpoint (first-ever image build). The build failed at `stage0/00-configure-apt` with `NO_PUBKEY` on every `deb.debian.org` repo.

## Root cause

`pi-gen/` is **not pinned**. `scripts/build-image.sh` has no clone/checkout/version logic — pi-gen was manually cloned + overlaid onto arlowe-1 during checkpoint setup, from pi-gen's current **master, which targets trixie**. Our `pi-gen/config` correctly sets `RELEASE="bookworm"` (pi-gen even warns: "RELEASE does not match the intended option for this branch").

The trixie-era `pi-gen/stage0/00-configure-apt/files/debian.sources` references `Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp` (**`.pgp`** — trixie keyring naming). Bookworm's `debian-archive-keyring` package installs `/usr/share/keyrings/debian-archive-keyring.gpg` (**`.gpg`**). apt in the chroot can't find the `.pgp` keyring → signature verification fails → repos rejected. (The raspberrypi.com repo verified fine because pi-gen ships its own keyring file directly.)

## Checkpoint resolution (2026-07-09, LOCAL ONLY on arlowe-1)

The `.pgp`→`.gpg` sed patch (first attempt) only unblocked stage0 — build #2 then failed at `stage2/01-sys-tweaks/00-packages` on trixie-only `rpi-swap`/`rpi-loop-utils`/`rpi-usb-gadget`. Symptom-patching abandoned. **Proper fix applied:** re-pinned pi-gen to tag **`2026-06-18-raspios-bookworm-arm64`** (`d7a31c6`) on arlowe-1:

```
git clone --branch 2026-06-18-raspios-bookworm-arm64 --depth 1 https://github.com/RPi-Distro/pi-gen.git /tmp/pigen-bw
rm -rf pi-gen && cp -r /tmp/pigen-bw pi-gen && rm -rf pi-gen/.git
git checkout -- pi-gen/config pi-gen/stage-arlowe   # restore arlowe overlay
```

Confirmed: bookworm pi-gen uses plain `sources.list` (no `signed-by=` → keyring bug can't recur) and has no `rpi-*` trixie packages. RPi-Distro maintains bookworm + trixie tags in parallel, so bookworm is still current.

**Still LOCAL/untracked** — `scripts/build-image.sh` has no pin. This todo stays OPEN for the repo-level fix (option 1 below is now known-good: pin to `2026-06-18-raspios-bookworm-arm64`).

## Fix shape (proper)

Pick one, before the next reproducible build:

1. **Pin pi-gen to a bookworm release tag/commit** (preferred) — add the pinned ref to `build-image.sh` (clone `--branch <bookworm-era-tag>` or a submodule at a fixed SHA). This is the real reproducibility fix and matches `PART-05`/ADR intent.
2. **OR** commit the `debian.sources` `.gpg` patch into the arlowe pi-gen overlay so it survives re-provisioning, and document that we track pi-gen master with a compat patch.

Option 1 is correct; option 2 is a band-aid.

## Cross-references

- Blocks clean reproducibility claim in `docs/operations/phase-6-repro-exceptions.md` — update it to note pi-gen is currently unpinned.
- Phase 6 checkpoint STATE.md Session Continuity.
- Related bookkeeping: Phase 6 pipeline lives only on `feat/110-arm64-ci-flash`, not `main`.
</content>
</invoke>
