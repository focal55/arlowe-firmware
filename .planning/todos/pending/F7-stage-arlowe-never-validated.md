# F7 — stage-arlowe was never validated; commit fixes + revisit Phase 6 completion

**Origin:** 2026-07-09, Phase 6 hardware checkpoint. The first-ever image build to get past upstream pi-gen (after the bookworm re-pin, [[F6]]) revealed that **`pi-gen/stage-arlowe/` — arlowe's own Phase-6 image provisioning — had never executed end-to-end** and carried multiple latent bugs. Phase 6 was marked "6/6 plans complete in code," but its final and most important stage never ran.

## Bugs found (all fixed in the repo on the Mac, rsynced to arlowe-1 for the checkpoint build; NOT yet committed)

1. **Missing `stage-arlowe/prerun.sh`** — every upstream pi-gen stage has a `prerun.sh` that runs `copy_previous` to populate its rootfs from the prior stage. stage-arlowe had none → `stage-arlowe/rootfs` never created → `00-run-chroot.sh` failed with "Unable to chroot". Fix: added `prerun.sh` (standard `if [ ! -d "${ROOTFS_DIR}" ]; then copy_previous; fi`).

2. **WhisPlay driver never reached the image** — `01-runtime/00-run.sh` rsyncs `third_party/whisplay-driver/` from the *repo*, which only ships `INSTALL.md`/`PROVENANCE.md`. The actual `WhisPlay.py`+`LICENSE` live wherever `ARLOWE_WHISPLAY_SRC` points (`~/whisplay-staging`), which the staging script ignores → chroot vendoring warns-and-skips → **no driver in the image**. Checkpoint workaround: copied `WhisPlay.py`+`LICENSE` into the repo `third_party/whisplay-driver/`. Proper fix: make `01-runtime/00-run.sh` honor `ARLOWE_WHISPLAY_SRC` (fall back to the repo dir) so the env-var path that `verify-third-party.sh` uses is the same one the image staging uses.

3. **`03-firstboot/files/` never staged into the chroot** — pi-gen does NOT auto-copy a sub-stage's `files/` into the rootfs. `00-run-chroot.sh` looked for the firstboot service + `arlowe-grow-models.sh` at `/files/…`; the service had an inline fallback but the grow script did not → **SC2 "models grow-to-fill on first boot" would silently not install.** Fix: rewrote `03-firstboot/00-run.sh` (was a no-op placeholder) to stage `files/` into the chroot `/files/`.

4. **Host `*-run.sh` scripts lack the execute bit (SYSTEMATIC — the smoking gun).** pi-gen runs a host script only `if [ -x ${i}-run.sh ]`, but runs the chroot script `if [ -f ${i}-run-chroot.sh ]`. Every `stage-arlowe` host script is committed `100644` (non-exec: `00-run.sh`, `01-runtime/00-run.sh`, `02-models/00-run.sh`, `03-firstboot/00-run.sh`, and the new `prerun.sh`). So pi-gen **silently skipped all host-side staging** while running the chroot steps → `01-runtime/00-run-chroot.sh` failed ("staged repo not found at /tmp/arlowe-build/repo"), and `02-models` (host-side) would have staged no models. This alone proves the stage never ran. Fix: `chmod +x` all `stage-arlowe` host `*-run.sh` + `prerun.sh` and **commit the mode change** (git tracks the exec bit; a plain content commit won't fix it).

5. **Repo staged into `/tmp`, which pi-gen masks with tmpfs (design flaw, UNFIXED).** `01-runtime/00-run.sh` stages the repo tree to `${ROOTFS_DIR}/tmp/arlowe-build/repo`; but pi-gen's `on_chroot` (scripts/common:100-101) unconditionally does `mount -t tmpfs tmpfs "${ROOTFS_DIR}/tmp"` before running any `*-run-chroot.sh`. So the chroot sees an empty `/tmp` → `00-run-chroot.sh` fails "staged repo not found." Same for the `.axcl-deb-path` marker and 03-firstboot's `/tmp/...` fallback candidate. **Fix (not yet applied):** stage the repo to a path pi-gen does NOT mount over (e.g. `/var/lib/arlowe-build/repo` or `/root/arlowe-build/repo`); update `01-runtime/00-run.sh` (STAGING/CHROOT_REPO), `01-runtime/00-run-chroot.sh` (REPO_ROOT + marker), and `03-firstboot/00-run-chroot.sh` candidates; add cleanup of that path at the end of chroot provisioning (else it ships in the image). This is arlowe provisioning plumbing — belongs in a proper DEV/QA fix, not a 2am hot-patch.

6. **axcl deb maintainer scripts modprobe in the build chroot (fixed).** The `axcl_host_aarch64_V3.10.2.deb` preinst/postinst `modprobe`/`modprobe -r` the Axera PCIe modules (`ax_pcie_p2p_rc`, `ax_pcie_mmb`, ...), which can't load in a chroot → preinst returns 1 → `dpkg -i` fails. The deb ships `/etc/modules-load.d/axcl_pcie.conf`, so runtime loading on a real Pi is independent of these calls. Fix: `dpkg-divert` + symlink `/usr/sbin/modprobe → /bin/true` around the `dpkg -i`, then restore. **Caveat: this guarantees a clean install, NOT a working NPU** — AX module load + inference is still deferred to on-hardware validation (matches the checkpoint's stated AX/LLM deferral). The axcl `.ko` modules' compatibility with the shipped Pi-OS kernel is unverified.

7-9. **axcl vendor deb is chroot-hostile (fixed via env overrides + tolerate).** The `axcl_host_aarch64_V3.10.2.deb` postinst (`set -e`) COMPILES the Axera driver at install time and does runtime module ops — all assuming it runs on live target hardware. In the build chroot this fails in a cascade, fixed in `01-runtime/00-run-chroot.sh` around the `dpkg -i`:
   - #7: postinst builds against `/lib/modules/$(uname -r)/build`, but `uname -r` = BUILD HOST kernel (6.12.47), not the image's (6.12.93, whose headers + gcc/make ARE in the chroot). Fix: divert `/usr/bin/uname` to a shim returning the image's `-rpi-2712` kernel → driver builds correctly ("Install driver success!!").
   - #8: `depmod -a` uses the `uname()` SYSCALL (not the command), so the PATH shim misses it → `depmod: could not open /lib/modules/6.12.47...`. Fix: divert `/usr/sbin/depmod` to a wrapper that always `depmod -a ${IMG_KVER}`.
   - #9: after a successful build, the postinst's runtime-load tail (cp .ko / modprobe the modules) still exits non-zero (254) in-chroot. Fix: neuter `modprobe`→`/bin/true`; and when the postinst exits non-zero BUT the driver `.ko` built, install the built modules to `/lib/modules/${IMG_KVER}/extra` + `depmod` ourselves and TOLERATE the failure (modules load at boot via `/etc/modules-load.d/axcl_pcie.conf`).
   - **Caveats (documented):** leaves `axclhost` in a half-configured dpkg state; NPU runtime unvalidated (deferred to on-hardware); driver built for the shipped kernel only (kernel update → needs rebuild; DKMS is the robust answer). All deferred/acceptable for the checkpoint. **Consider whether the proper long-term answer is deferring the whole axcl driver build to a first-boot/DKMS hook instead of building in-chroot** — revisit during AX integration.

## ON-HARDWARE FINDINGS (2026-07-11, first boot of the flashed card)

11. **fstab: unsubstituted pi-gen BOOTDEV/ROOTDEV → emergency mode (fixed, commit 3d7b3bc).** First on-hardware boot dropped to emergency mode. `partition-image.sh` `_pimg_write_fstab` left pi-gen's literal `BOOTDEV`/`ROOTDEV` tokens (pi-gen's own export-image rewrites them; we `SKIP_IMAGES`), so those required mounts failed. Fixed in source (substitute ROOTDEV→p2, BOOTDEV→p1) AND hand-patched on the flashed card's slot-A fstab to re-test without a 77-min reflash. Slot B was already clean (recovery-stub writes fstab from scratch).

12. **No usable recovery console when a unit fails (root account locked).** When slot A hit emergency mode, `sulogin` refused: "Cannot open access to console, the root account is locked" — it just loops "Press Enter to continue". So ANY boot failure on a customer unit with no serial/Whisplay is unrecoverable at the console. Options: an emergency-mode fallback that doesn't require root (e.g. `sulogin --force` / a recovery getty), or ensure the A/B recovery slot is the failure path. Ties to F8 (root locked is otherwise correct for security — the fix isn't "unlock root"). Needs a design decision.

13. **`growpart` not installed → models grow-to-fill fails (SC2), fixed in source.** After the fstab fix the card booted clean to ready-to-pair (SC1 core PASS: `/etc/arlowe/config.yml` absent), but `arlowe-firstboot.service` FAILED (status=127): `arlowe-grow-models: line 113: growpart: command not found`. `growpart` (pkg `cloud-guest-utils`) and `sgdisk` (pkg `gdisk`, needed to relocate the GPT backup header when growing the last partition of a small-image-on-big-card) were never in the image package list. Added both to `stage-arlowe/00-packages-nr`. Result on the un-fixed card: models partition stayed at 24.5 GB with ~26 GB of the 64 GB card unallocated; no first-boot sentinels written.

14. **owner_state partition shadows the `/var/lib/arlowe` skeleton (IMPORTANT for Phase 7), fixed in source.** `install-arlowe-fs.sh` creates `/var/lib/arlowe/{identity,logs,conversations,state,...}` in the ROOTFS, but the empty `owner_state` partition (p4) mounts over `/var/lib/arlowe` at runtime → `ls -a /var/lib/arlowe` shows only `lost+found`. The skeleton (with `arlowe` ownership/perms) is invisible at runtime. **Phase 7 writes the device cert/key to `/var/lib/arlowe/identity/` — which won't exist**, so PKI would break on this substrate. **Fix applied:** added `_pimg_seed_owner_state` in `partition-image.sh` — mirrors `_pimg_seed_models`, mounts p4 and `rsync -aHAX --numeric-ids` the already-built rootfs skeleton (`${rootfs}/var/lib/arlowe/`) onto it so owner_state ships pre-seeded with correct `arlowe:arlowe` ownership. Single source of truth (the chroot's `install-arlowe-fs.sh` output); does NOT self-heal a factory-reset wipe (a separate Phase-8/reset concern). Not yet re-validated on hardware.

15. **system_a (root) is 97% full on-hardware, fixed in source** (`/dev/root` 2.0 G, 1.9 G used, 55 M free). The measured-slot + 25% headroom produced a 2 GB slot that the rootfs nearly fills — no margin for apt/updates/tmp. A percentage-only headroom collapses to near-nothing on a small (~1.6 GiB) rootfs. **Fix applied:** `build-image.sh` now treats ADR-0004's `_ADR_SLOT_REF_MIB` (3072 MiB) as a FLOOR, not just a starting point — measured wins only when larger. A ~1.6 GiB rootfs now gets a 3 GiB slot (~1 GB+ real headroom). Further lever if still tight: `mkfs.ext4 -m 1` on the system slots to reclaim the default 5% root-reserved blocks. Not yet re-validated on hardware.

## ON-HARDWARE FINDINGS ROUND 2 (2026-07-18, clean from-scratch cert build flashed + booted)

A full from-scratch build (all prior fixes in source) was loop-mount-validated ON THE IMAGE (fstab real PARTUUIDs; owner_state p4 seeded with identity/ at 995:992/0700; slot 3.0G/1.1G-free), flashed to a 58.2G card via bmaptool, and booted on arlowe-1 (HDMI+kbd).

- **SC1 PASS (from-scratch):** boots clean to a login shell (kernel 6.12.93+rpt-rpi-2712), `/etc/arlowe/config.yml` ABSENT = ready-to-pair, NO emergency mode. The fstab fix (#11) holds on a from-scratch image, not just the hand-patched card. system state = degraded (expected — NPU/display peripherals deferred).
- **SC2 layout PASS:** 5 partitions, correct 3G slots (floor #15 confirmed on-hardware: system_a/b = 3G).

16. **[ROOT-CAUSED 2026-09-08 — see #18; the L95 `parted` hypothesis below was WRONG]** **`arlowe-firstboot` unit FAILED on-hardware -> models NOT grown (SC2 grow still broken).** `systemctl` shows `arlowe-firstboot active=failed`; models still 22.5G on a 58.2G card. `arlowe-grow-models` runs as `ExecStartPre=`, so its failure fails the whole unit (boot-check + `.firstboot-done` sentinel never run). Failure is EARLY: models is still mounted at runtime, so it died BEFORE the L132 unmount — i.e. at the `sudo parted -s "${_disk_dev}" print` last-partition safety check (L95) or `growpart` (L113). Likely cause to check first: on a card whose GPT backup header sits at the 32-GiB image end (not the 58G card end), `parted -s print` emits a "fix the GPT?" warning; in script mode it may exit non-zero or the awk may misparse `_last_part_num` -> L96 abort. Or `sudo` misbehaves in the systemd (root) context. **Need the journal to confirm.** growpart/gdisk ARE installed now (#13), so this is a NEW failure mode, not the old "growpart: command not found".
17. **[CLOSED 2026-09-08 — NOT A BUG, see #19; this finding was a permissions misread and it wrongly blocked Phase 7 for seven weeks]** **owner_state `/var/lib/arlowe` is EMPTY at runtime — `identity/` MISSING — Phase 7 STILL blocked.** Despite the build-time seed (`2352231`) that was VERIFIED present on the image's p4 (identity/ at 995:992/0700) before flashing, the running system shows no identity/ at /var/lib/arlowe. Unexplained — the seed was on the image and flashed. Candidate causes to rule out with `findmnt /var/lib/arlowe` + `ls -la /var/lib/arlowe`: (a) owner_state mounted-but-empty = seed didn't reach the card's p4 (bmap/flash interaction — note the first flash aborted at p2 and a bmap regen happened; the second flash reported clean); (b) owner_state failed to mount and /var/lib/arlowe = system_a's (also missing identity? shouldn't be); (c) something at runtime formats/wipes owner_state (grep for mkfs on owner_state in firstboot/recovery — grow-models does NOT touch p4). This is the #14 gap re-appearing at the runtime layer even though the build-time seed is correct.

**Flash lesson:** generating the .bmap during the build then rw loop-mounting the image for inspection desyncs the .bmap (ext4 superblock rewrite) -> bmaptool checksum mismatch on flash. Mount `-o ro` for inspection, or regenerate the .bmap after any mount.

**Not yet re-validated end-to-end:** SC1 PASS from-scratch. SC2 grow (#16) + owner_state runtime (#17) FAIL on-hardware and are the active diagnosis. Findings 11, 13, 14 (build-time), 15 fixed in source; **#12 (locked-root recovery console) remains an open design decision** (ties to F8); SC3 (A/B recovery) untested. Resume: power arlowe-1 on (test card in; firstboot re-runs), capture the journal + mount table for #16/#17.

## FLASH-TIME FINDING (2026-07-09, checkpoint flash)

`flash-sd.sh` fell back to `dd` (no `bmaptool`/`.bmap` present) and wrote the FULL 32 GiB image even though only ~9.9 GB is real data. On the checkpoint card, sustained write collapsed to ~10 MB/s (SLC-cache burst then throttle), so a flash takes ~50 min instead of ~10. Fixes to consider: (a) generate a `.bmap` in `build-image.sh` so `flash-sd.sh`'s bmaptool path writes only used blocks; and/or (b) size the image to just past the pre-grow partitions instead of the full card — the models partition already grows-to-fill on first boot, so the full-card image is mostly empty space. Related to the CARD_SIZE_GB GiB-vs-GB latent bug. This is a runbook/UX issue, not a correctness bug.

## PROGRESS LOG (2026-07-09 morning — driving to green per owner request)

Iterating fast via pi-gen `SKIP` on stage0/1/2 (reuse validated rootfs) + wipe stage-arlowe each cycle (~2 min/iter). **FINAL build before the checkpoint MUST remove the SKIP files and do one clean full run.** Fixes 1-6 now applied. As of fix #6, provisioning reached: install-arlowe-user/fs/config/units(6)/cli(9 symlinks)/udev-polkit(4 rules) all PASS, /opt/arlowe/runtime populated, axcl deb install (with modprobe neutered) in progress. Expect possible further bugs in: WhisPlay vendor, WM8960, fstab, then build-image.sh partition-image.sh (plan 06-04, also never run end-to-end).

## ORIGINAL STOP POINT (2026-07-09 ~02:00, now superseded — owner approved driving to green)

Five structural bugs found, ALL in stage-arlowe plumbing — **none is the actual provisioning logic yet** (the repo has never even reached the chroot). `install-arlowe-*.sh` running in a clean image chroot, `dpkg -i` on the axcl deb, WM8960, and the models/partition steps are ALL still unexercised. Base rate of further bugs is high. Recommendation: **reopen Phase 6** and give stage-arlowe a real DEV/QA pass (build it green in a dev loop, commit every fix, then re-attempt the hardware checkpoint) rather than continue blind hot-patching that risks a build-passes-but-SC-fails image.

## Side gap

`third_party/whisplay-driver/WhisPlay.py` is **not** gitignored despite `INSTALL.md` claiming ".gitignore covers it". Add a `.gitignore` rule so the vendored driver can't be accidentally committed (the `third_party/` strategy is fetch-at-build, never commit the binary/driver). Related: [[F2]].

## Actions

- Commit the three fixes (`prerun.sh`, `01-runtime/00-run.sh` ARLOWE_WHISPLAY_SRC handling, `03-firstboot/00-run.sh`) + the `.gitignore` rule.
- Do NOT re-mark Phase 6 "passed" until a clean build produces a bootable image AND the checkpoint SCs run green.
- Expect this list to grow — stage-arlowe's chroot provisioning (`install-arlowe-*.sh` in a real chroot, axcl `dpkg -i`, WM8960) is running for the first time; further bugs may surface during the checkpoint build.
- Consider a proper DEV/QA pass on stage-arlowe rather than ad-hoc checkpoint patches. Related: [[F6]].
</content>

## ON-HARDWARE FINDINGS ROUND 3 (2026-09-08, journal + mount table captured from the paused test card)

The two round-2 findings were resolved by capturing what round 2 stopped short of capturing. One was real
and much larger than described; the other was never a bug.

18. **`stage-arlowe/00-packages-nr` sat at the STAGE ROOT, where pi-gen never reads it — the declared
    package set has been absent from every image ever built (FIXED).** Verified against upstream pi-gen
    at the pinned tag `2026-06-18-raspios-bookworm-arm64`: `run_stage()` executes only `prerun.sh` at the
    stage root and iterates **directories only** when looking for sub-stages; `NN-packages-nr` is read
    from inside `${SUB_STAGE_DIR}`. A package list at the stage root is silently ignored — no warning,
    no build failure.

    Confirmed on hardware. `dpkg -l` on the running cert image:
    - ABSENT: `cloud-guest-utils` (growpart), `nodejs`, `npm`, `ripgrep`, `python3-rpi.gpio`
    - PRESENT: `alsa-utils`, `gdisk`, `network-manager`, `python3-spidev`

    The present four are Raspberry Pi OS Lite base packages, not evidence the list ran. The proof is
    internal: `python3-spidev` (`ii`) and `python3-rpi.gpio` (`un`) are adjacent lines in the same list,
    and pi-gen installs a list with a single `apt-get install` — all-or-nothing. A partial result is
    impossible, so the list never executed.

    **This is the actual root cause of #16.** `growpart: command not found` at L113 was never fixed by
    `0a6015c`; that commit edited a file nothing reads. The `parted -s print` safety check at L95 passed
    cleanly (the GPT warning printed, `_last_part_num` parsed, execution continued) — #16's stated
    hypothesis was wrong. Also: "line 565" in the round-2 journal reading was the syslog PID, not a line
    number; source and installed script agree at 179 lines.

    **Blast radius beyond growpart:** no Node runtime for `arlowe-dashboard` (Phase 4/5 deliverable), no
    `python3-rpi.gpio` for the WhisPlay display driver, no `ripgrep`. Phase 6 is broken considerably
    wider than one failing first-boot unit, and Phases 4/5 "passed-with-notes" rest on a substrate that
    cannot run their services.

    **Fixes applied:**
    - Moved the list to `pi-gen/stage-arlowe/00-packages/00-packages-nr` (sorts before `01-runtime`, so
      packages install before chroot provisioning) and documented the placement constraint in its header.
    - Deleted `pi-gen/stage-arlowe/00-run.sh` — dead at the stage root for the same reason, and its
      comment asserted the false claim ("pi-gen calls this before entering the sub-stages") that produced
      this bug. Same wrong model caused F7 #1 (missing stage-root `prerun.sh`).
    - Added a post-pi-gen guard in `build-image.sh`: parses the declared list and asserts each package is
      `install ok installed` in the rootfs's `var/lib/dpkg/status`, failing the build otherwise. Matcher
      unit-tested against the four real on-hardware results. **This is the durable fix** — the class of
      failure here is a silent build-time no-op surfacing as a boot-time failure weeks later, and no
      amount of care in the package list prevents a recurrence without an assertion on the artifact.

19. **owner_state seeding WORKS — #17 was a permissions misread, not a substrate failure. Phase 7 is
    NOT blocked.** `findmnt /var/lib/arlowe` -> `/dev/mmcblk0p4 ext4 rw,noatime`, and `sudo ls -la`
    shows the full seeded skeleton: `identity/`, `conversations/`, `dashboard/`, `logs/`, `state/`,
    `wake-word/`, all `arlowe:arlowe`. The build-time seed (`2352231`) is verified end-to-end:
    image -> flash -> runtime.

    The round-2 "empty" reading came from a non-sudo `ls` as user `pi` against a `0750 arlowe:arlowe`
    directory. `pi` is not in the `arlowe` group, so the listing was empty by permission.

    **Process note worth keeping:** #17 was written as a confirmed substrate failure ("Phase-7 STILL
    blocked") on a single unprivileged `ls`, then the session paused *before* capturing the diagnostic
    that would have falsified it. That inverted claim sat in STATE.md as a Phase 7 blocker for seven
    weeks. Capture the disconfirming evidence before writing the finding, not after.

**Status after round 3:** SC1 PASS (from-scratch). SC2 layout PASS, SC2 grow still FAIL until a rebuild
carries the #18 fix. SC3 (A/B recovery) untested. #12 (locked-root recovery console) still an open design
decision. Next step is a clean rebuild on arlowe-1 with the corrected package sub-stage, then re-flash and
re-run SC2/SC3.
