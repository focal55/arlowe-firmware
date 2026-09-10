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

## FOUND WHILE PREPARING THE ROUND-3 REBUILD (2026-09-08, repo inspection — not yet on hardware)

20. **`arlowe-dashboard.service` can never start: its `ExecStart` target is a build artifact nothing
    builds.** The unit runs `/usr/bin/node /opt/arlowe/runtime/dashboard/server.js`. That `server.js` is
    a Next.js *standalone* build output, and:
    - `runtime/dashboard/next.config.ts` does not set `output: 'standalone'`, so `next build` never
      emits a `server.js` at all;
    - `.next/` and `node_modules/` are gitignored (`runtime/dashboard/.gitignore`), so neither the build
      output nor the dependency tree can reach the image via the repo staging in `01-runtime/00-run.sh`;
    - nothing in `stage-arlowe` runs `npm`/`pnpm install` or `next build` — grep for node/npm/dashboard
      in `01-runtime/00-run-chroot.sh` returns nothing.

    Until now this was masked: `nodejs`/`npm` were never installed either (#18), so the unit would have
    failed on a missing interpreter before reaching the missing script. Fixing #18 installs the runtime
    and exposes this as the next failure in line.

    This is a distinct piece of Phase-6 work (decide where the dashboard is built — in-chroot at image
    build, or prebuilt on the host/CI and staged as an artifact — then wire it and stage `node_modules`),
    and it should get a proper DEV/QA pass rather than being patched during a hardware checkpoint. It
    does NOT block the SC2 grow / SC3 recovery re-run, which is the immediate objective.

    Note this is the same shape as #18 and #1: a Phase-6 deliverable declared complete whose code path
    had never once executed. That is now four instances, which makes it a property of how Phase 6 was
    verified rather than a run of bad luck.

## SC2 GROW VERIFIED ON HARDWARE (2026-09-08, boot of the rebuilt cert image)

**#16 CLOSED — SC2 grow-to-fill PASSES.** First boot of the image built with the #18 package fix:

    arlowe-firstboot.service - Active: inactive (dead)
      Process: 512 ExecStartPre=/opt/arlowe/runtime/cli/arlowe-grow-models (code=exited, status=0/SUCCESS)
      Process: 936 ExecStart=/opt/arlowe/runtime/cli/boot-check --first-boot (code=exited, status=0/SUCCESS)

    /dev/mmcblk0p5   48G  6.2G  40G  14%  /opt/arlowe/models

The models partition grew 22.5G -> 48G, filling the 58.2G card. Both unit processes exited 0.
`inactive (dead)` is the correct terminal state for this unit (`Type=oneshot`, `RemainAfterExit=no`);
`active (exited)` would require `RemainAfterExit=yes`. Do not read `inactive (dead)` as a failure here
-- the `status=0/SUCCESS` on both processes is the signal.

This confirms the whole #18 chain end-to-end: package list in a sub-stage -> `growpart` installed ->
first-boot grow succeeds. Every prior image failed here at exit 127.

**Checkpoint status:** SC1 PASS, SC2 layout PASS, SC2 grow PASS. SC3 (A/B tryboot flip + slot-B recovery
+ default reset to A) is the last untested criterion. Open non-hardware items unchanged: #12 (locked-root
recovery console, design decision, ties to F8) and #20 (dashboard has no build step).

21. **`arlowe-ab` shipped as a dangling symlink — SC3 was untestable, not merely untested (FIXED).**
    On the rebuilt image, `sudo arlowe-ab status` returns "command not found" even though
    `/usr/local/sbin/arlowe-ab` exists. It points at `/opt/arlowe/runtime/cli/ab`, which does not exist:
    the file in the repo was `runtime/cli/arlowe-ab`, the only CLI carrying the `arlowe-` prefix in its
    own filename. `install-arlowe-cli.sh` builds each link as
    `arlowe-${cli} -> ${TARGET_DIR}/${cli}` from a hardcoded `CLIS=(... ab)`, so the entry `ab` produced
    a link to a nonexistent target. `ln -sf` creates a dangling symlink without error, so the installer
    reported "installed 9 symlinks" and exited 0.

    This is independent of #18 and predates it — SC3 could never have passed on any image built so far.
    It also means every earlier plan to "run SC3 over serial" was blocked on something no amount of
    console access would have revealed.

    **Fixes applied:** renamed `runtime/cli/arlowe-ab` -> `runtime/cli/ab` to match the convention every
    sibling already follows (bare name in `cli/`, `arlowe-` prefix only on the symlink); updated the one
    doc line that recorded the source path; and made `install-arlowe-cli.sh` fail loudly when a `CLIS`
    entry has no matching file, instead of installing a dangling link.

    Fifth instance of the same pattern: a Phase-6 deliverable that was never executed, failing silently
    at build time and surfacing only on hardware.

## SC3 VERIFIED ON HARDWARE (2026-09-08) — ALL CHECKPOINT SCs NOW GREEN

**SC3 PASS.** After `arlowe-ab switch B`: device rebooted into slot B, ran `arlowe-recovery.service`
(console output visible on HDMI), reset the persistent default to slot A, and rebooted itself into
slot A without intervention. Two reboots, no emergency mode, no manual step. Verified on landing:

    Persistent default: slot A (root=PARTUUID=0fbbaf6a-4afc-4213-aa66-bdd45159fa6e)
    /  /dev/mmcblk0p2 ext4 rw,noatime

Both halves matter and agree: `arlowe-ab status` reads the STORED default (the self-heal wrote it),
`findmnt /` shows the RUNNING slot. Pre-flight checks that made this safe to attempt: the PARTUUID map
carried all five entries incl. `PARTUUID_B=e3d33191-dbf3-4cc9-b7d2-f6a79bfa0ac7`, and slot B's
`multi-user.target.wants/` genuinely contained `arlowe-recovery.service` — the first Phase-6
unit-enablement path found correctly wired.

**CAVEAT — SC3 ran on a hand-patched card.** `arlowe-ab` only worked because the dangling symlink was
repointed by hand (`ln -sf .../cli/arlowe-ab /usr/local/sbin/arlowe-ab`). The source fix (#21, renaming
`runtime/cli/arlowe-ab` -> `runtime/cli/ab`) has NOT been validated from a clean build. Same posture as
the July fstab hand-patch: the mechanism is proven, the build path that produces it is not.

**Checkpoint SC status: SC1 PASS, SC2 layout PASS, SC2 grow PASS, SC3 PASS.**

22. **No persistent journal — a recovery event leaves no forensic trace.** `journalctl -b -1` returns
    "no persistent journal was found", so the slot-B recovery run's log is gone the moment it rebooted.
    `arlowe-recovery.sh`'s `log_recovery()` writes only to stdout (journal) and `/dev/ttyAMA0`, so on a
    unit with no serial attached, a device that fell into recovery and healed itself records nothing an
    owner or a support session could later read. Recovery is precisely the event that needs forensics.

    `/var/lib/arlowe/logs/` sits on the owner_state partition and is shared across both slots, which
    makes it the natural place for a durable breadcrumb (timestamp, reason, slot, outcome). Ties to
    [[F3]] (persistent journald) — but a recovery breadcrumb is worth having independently of whether
    journald is made persistent, since it should survive a factory reset decision separately.

23. **ADR-0005 and the implementation disagree on which file holds the persistent default (doc-level).**
    `arlowe-ab`'s own help text on-device says "The persistent A/B default is the root= in
    /boot/firmware/cmdline.txt", and `docs/operations/phase-6-ab-recovery.md` agrees (`cmdline.txt` |
    Active root= line; edited by arlowe-ab). ADR-0005 instead says `arlowe-ab` rewrites the `root=` in
    `config.txt`. The implementation works and SC3 passed, so this is a documentation defect, not a
    behavioural one — but ADR-0005 is the artifact Phase 9 OTA will build against, so it should be
    corrected to match the code before OTA work starts.

## VALIDATION BOOT (2026-09-09) — #21 PROVEN FIXED AT SOURCE

Clean repo-built image, no hand-patching anywhere in the chain:

    sudo arlowe-ab status
    Persistent default: slot A (root=PARTUUID=8096e9f9-5ac4-44d2-afe5-3ebe979ba085)

    sudo df -h /opt/arlowe/models
    /dev/mmcblk0p5   48G  6.2G  40G  14%  /opt/arlowe/models

`arlowe-firstboot` shows all THREE processes at `status=0/SUCCESS`, including the `ExecStartPost` that
writes `.firstboot-done`. **#21 CLOSED**, and with it the ordering defect that caused it.

**Coverage caveat, stated so nobody overclaims later:** the SC3 flip mechanism was verified on the
hand-patched card (2026-09-08); the CLI shipping in working order is verified on this clean card. Both
halves hold, but no single card has run both. Re-running `arlowe-ab switch B` here would close it.

24. **`boot-check` reports a correctly-behaving device as broken.** First boot prints
    `Results: 0 passed, 14 failed` / `Some services need attention`. Every failure is expected: the
    Axera NPU and USB audio are deferred peripherals that are not attached, and the six runtime units
    are disabled by design until the Phase 8 pairing daemon starts them. The check has no notion of
    expected state, so a factory-fresh unit greets its owner by declaring total failure. `boot-check`
    should gate its expectations on whether `/etc/arlowe/config.yml` exists — the same pairing signal
    SC1 already uses — and report "ready to pair" rather than 14 failures in that state. Owner-facing,
    so it should land before any unit ships.

## FINDING #25 — THE A/B PERSISTENT FLIP DOES NOT WORK (2026-09-10, under investigation)

**SC3 cannot pass on any image built to date, for a reason unrelated to #21.** `arlowe-ab switch B`
returns success and reboots, but the device always comes back in slot A. Reproduced repeatedly over SSH
on the clean cert image (ethernet, key auth, hostname `arlowe`, 192.168.1.190).

**Established by direct measurement:**
- `arlowe-ab set B` writes correctly. `cmdline.txt` reads back as slot B's PARTUUID
  (`bb382f2e-c33b-4c73-bf03-f9ef11aa2d51`) after `umount` + `mount`, which discards the page cache —
  so the write genuinely reaches the card.
- After a reboot, `cmdline.txt` contains slot A (`8096e9f9-...`) **with a fresh mtime**, i.e. it was
  actively rewritten, not lost.
- Two runs, same shape: written 21:56:20 -> mtime 21:57:24; written 22:02:40 -> mtime 22:03:56. Both
  rewrites happened BEFORE the subsequent boot (boots at 21:58:45 and 22:05:20 respectively).
- `/proc/cmdline` always shows slot A, consistent with the file already being slot A at boot time.
- **Slot B has never mounted on this card**: `dumpe2fs -h /dev/mmcblk0p3` still reads `Mount count: 1`,
  `Last mount time: Wed Sep 9 03:03:55` (image creation), `Last mounted on: /tmp/tmp.exSximm7D5`.
- A sysrq hard reboot (`echo b > /proc/sysrq-trigger`), which skips all userspace shutdown, produced the
  same result — so a clean-shutdown path is not required for the revert.

**Ruled out by measurement, not reasoning:**
- Page cache (umount/mount forces a disk read).
- Firmware ignoring `cmdline.txt` (the file itself changes, with a new mtime).
- systemd shutdown hooks (`/lib/systemd/system-shutdown/` and `/usr/lib/systemd/system-shutdown/` are
  both empty).
- A scheduled job (no cron entries beyond `e2scrub_all`; no systemd timer on a short cadence).
- `arlowe-recovery.service` (not installed at all in slot A — `list-unit-files` shows only dashboard,
  face, firstboot, voice).
- `imager_fixup` (exits unless `systemd.run=/boot/firstrun.sh` is present), `wifi-check.sh` (read-only
  grep), `arlowe-grow-models` (reads `/proc/cmdline` only).

**The contradiction that remains:** a filesystem-wide search finds no writer of `cmdline.txt` other than
`arlowe-ab` itself and `arlowe-recovery.sh`, yet the file's mtime advances and its content reverts. One
of the measurements is being misinterpreted and the mechanism is not yet identified. Do NOT write a fix
until it is.

26. **`tryboot_a_b=1` is in `config.txt`, where the firmware does not read it.** That key belongs in
    `autoboot.txt`, which this image does not have. It is therefore inert, and ADR-0005's "Style 2 —
    file-level A/B" description rests on it doing something it is not doing. Independent of #25, this
    means the documented A/B mechanism is not the mechanism actually in effect; the image is relying on
    the plain default (`cmdline.txt` supplies the kernel command line). `include cmdline.txt` in
    `config.txt` is also wrong — `include` pulls in a *config* fragment, and the kernel command line is
    already read from `cmdline.txt` by default.

**Corrections to the record this forced:** the 2026-09-08 "SC3 PASS" on the hand-patched card is now
almost certainly wrong. It rested on two observed reboots plus the default reading slot A afterward —
both of which are equally consistent with the flip never taking effect. That card has been overwritten,
so it cannot be re-checked. SC3 has never been demonstrated to work.

### #25 FINAL STATE (2026-09-10, 22:30) — arlowe-ab EXONERATED, mechanism still unidentified

**The decisive test: a plain `sed -i` on `cmdline.txt`, with `arlowe-ab` not involved at all and
`/boot/firmware` left mounted rw, reverts exactly the same way.**

    22:25:02  sed writes root=PARTUUID=bb382f2e (slot B); sync; verified on disk
    22:25:03  systemctl reboot
    22:25:32  cmdline.txt rewritten to root=PARTUUID=8096e9f9 (slot A), fresh mtime

So the A/B flip failure is NOT in arlowe's code. Something in the platform rewrites `root=` in
`cmdline.txt` to the PARTUUID of the partition that actually booted. `arlowe-ab`'s remount rw/ro dance,
its temp-file+rename, and its sync are all irrelevant to the outcome.

**Additional evidence gathered:**
- **Only `cmdline.txt` is touched.** A marker file (`ARLOWE-TEST-MARKER.txt`) written to the same FAT
  partition in the same session survived the reboot with its original mtime, as did `config.txt.bak`.
  The partition is not being rolled back; one file is being rewritten by name.
- **It restores the BOOTED partition's PARTUUID**, which is "fix cmdline up to match reality" behaviour.
- **Nothing rewrites it while running.** A 200-second idle watch (polling mtime every 2s) showed zero
  change; the file sat on slot B untouched.
- **The rewrite lands in the shutdown/firmware window**, consistently 29-38s after the reboot command
  and always before the kernel's first journal entry.
- **`tryboot_a_b=1` is NOT the cause.** Commenting it out of `config.txt` changed nothing. (Note it also
  still exists in `tryboot.txt`, so that test disabled it only for the normal boot path.)
- **The PARTUUID map is correct.** `lsblk` confirms p2=8096e9f9, p3=bb382f2e, matching
  `/etc/arlowe/ab-partuuid-map` exactly. `arlowe-ab` writes a valid, resolvable root=.
- **Ruled out:** page cache (umount/mount re-read), systemd shutdown hooks (both `system-shutdown/`
  dirs empty), cron/timers (nothing on a short cadence), `arlowe-recovery` (not installed in slot A),
  `imager_fixup` (gated on `systemd.run=`, and no initramfs is unpacked — `local-bottom` contains only
  `firstboot_fstrim`, `imager_fixup`, `ntfs_3g`), `wifi-check.sh` (read-only), `arlowe-grow-models`
  (reads `/proc/cmdline` only), EEPROM config (`BOOT_ORDER=0xf461`, nothing A/B).

**Not yet checked (start here next session):** systemd units with an `ExecStop`/shutdown ordering that
touch `/boot/firmware` (I only checked the `system-shutdown/` drop-in dirs, not unit `ExecStop=` lines);
`raspberrypi-sys-mods` package contents in full; whether a *power-cycle* (rather than a reboot) behaves
differently; and enabling persistent journald ([[F3]]) so the shutdown sequence is actually observable —
every conclusion above had to be reconstructed from file mtimes because nothing is logged.

**Design implication if this proves to be platform behaviour:** editing a shared `cmdline.txt` is the
wrong persistence mechanism for the A/B default. The Pi-native approach is `autoboot.txt` with real
`[all] boot_partition=` / `[tryboot] boot_partition=` entries, which is the partition-level style
ADR-0005 explicitly rejected in favour of a single shared /boot. That rejection may need revisiting, and
it is an ADR-level decision, not a patch.

**Test card state left clean:** test artifacts removed, `cmdline.txt` on slot A, `config.txt` restored
with `tryboot_a_b=1` intact. The Mac's SSH key remains in slot A's `/home/pi/.ssh/authorized_keys` (a
deviation from the built image; the card is reachable at 192.168.1.190 over ethernet as user `pi`).

### #25 MECHANISM IDENTIFIED (2026-09-10 23:06) — THE PI BOOTLOADER REWRITES cmdline.txt

Enabling persistent journald (see #27) made the shutdown window observable for the first time. The
timeline is decisive:

    23:05:53          cmdline.txt written with slot B (bb382f2e), synced, verified
    23:05:54.557      systemd-journald[865]: Journal stopped   <- Linux fully down
    23:06:24          cmdline.txt mtime, content now slot A (8096e9f9)
    23:07:44          next boot's first kernel entry

**The rewrite happens 30s after Linux shut down and 80s before the next kernel started.** No Linux
process was alive at that moment, so no userspace or kernel code can be responsible. The only software
running in that window is the Raspberry Pi bootloader.

**Conclusion: the Pi firmware rewrites `root=` in `cmdline.txt` to the partition it actually booted.**
This explains every observation: why `arlowe-ab` and a plain `sed` behave identically, why the write
provably reaches disk and then reverts, why only `cmdline.txt` is touched while a marker file on the
same FAT partition survives, why nothing changes during a 200s idle watch, and why slot B has never
mounted (the firmware never boots it, so the recovery stub never gets a chance to run).

**Design implication — this is an ADR-level decision, not a patch.** Editing a shared `cmdline.txt` is
not a viable persistence mechanism for the A/B default on this platform; the firmware overwrites it.
The Pi-native mechanism is `autoboot.txt` with real `[all] boot_partition=` / `[tryboot] boot_partition=`
entries — the *partition-level* style that ADR-0005 explicitly rejected in favour of a single shared
/boot FAT partition. Options, in rough order of preference:
  1. Adopt `autoboot.txt` partition-level A/B. Requires two FAT boot partitions, so ADR-0004's layout
     and ADR-0005's "single shared /boot" decision both need revisiting, and SC2's five-partition
     layout changes.
  2. Keep one /boot and drive the flip from the bootloader's own config rather than `cmdline.txt`
     (needs research into what the Pi 5 bootloader honours and does not overwrite).
  3. Abandon in-place A/B for v1 and treat slot B purely as a recovery target reached by an explicit
     `reboot 0 tryboot`, which is the one path the firmware does not fight.

**Do not attempt to fix `arlowe-ab`.** It is correct. The mechanism it implements is the problem.

27. **`journald.conf` ships `Storage=volatile` while the image also creates `/var/log/journal`.** Those
    contradict: the directory is the conventional signal for persistence, and the explicit setting
    overrides it, so nothing survives a reboot. A fielded unit that misbehaves therefore keeps no record
    of why — the same gap as #22 but broader. It also cost several hours tonight: every conclusion had
    to be reconstructed from file mtimes until this was flipped, and flipping it identified #25's
    mechanism within one reboot. SD-card wear is the real tradeoff; `Storage=persistent` with a modest
    `SystemMaxUse=` cap is the usual middle ground. Related: [[F3]], which is filed as dev-env
    infrastructure but is actually a product decision about whether a shipped Arlowe is debuggable.
