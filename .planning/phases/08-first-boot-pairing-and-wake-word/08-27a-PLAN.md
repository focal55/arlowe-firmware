---
phase: 08-first-boot-pairing-and-wake-word
plan: 27a
type: execute
wave: 6
depends_on: ["08-17", "08-19", "08-22", "08-24", "08-25", "08-26", "08-29"]
files_modified:
  - docs/operations/phase-07.2-inputs.reference
  - docs/operations/phase-8-pairing.md
autonomous: true

must_haves:
  truths:
    - "An image is built from main with every Phase 8 change and emitted, and its inputs diff against the recorded reference moved exactly the new Phase 8 package rows (python3-qrcode, python3-png, python3-typing-extensions, python3-argon2) and nothing else."
    - "The re-recorded inputs reference is committed, so the next build passes the diff gate without an accept."
    - "The built rootfs, inspected read-only, contains every Phase 8 unit, link, polkit rule and NetworkManager file, and the two new packages are installed."
    - "/etc/arlowe is 770, owner 0, group = the image's own arlowe GID, in both slot A (p2) and slot B (p3) of the emitted image (08-29's fix survived step 4b)."
  artifacts:
    - path: "docs/operations/phase-07.2-inputs.reference"
      provides: "reference re-recorded with the Phase 8 package rows"
      contains: "python3-argon2"
  key_links:
    - from: "build/logs/phase-08-build.log"
      to: "docs/operations/phase-07.2-inputs.reference"
      via: "ARLOWE_INPUTS_ACCEPT=1 re-record"
      pattern: "reference re-recorded"
---

<objective>
Build the Phase 8 image on the build host, re-record the inputs reference once for all of Phase 8's package additions, and prove the rootfs carries the phase before any card is flashed.

Purpose: the build loop is the only test of chroot-level changes (memory). Four of nine past builds died on chroot-only defects that shellcheck passed. Inspecting the rootfs here costs minutes; finding a missing file on a booted unit costs a rebuild and a reflash.

**Honest PR size: ~55 lines.**
- inputs reference: ~8 changed rows (4 new `pkg` rows, `source_date_epoch`, `worktree_clean`, plus any rows the diff shows; generated, counted)
- runbook: 46 (a "Phase 8 build" evidence block: commit, date, diff-gate output, rootfs checks, the two-slot `/etc/arlowe` mode lines)

8 + 46 = 54.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@docs/operations/phase-07.3-pi-archive-pinning.md
@docs/operations/phase-6-build-flash-deploy.md
@docs/operations/phase-8-pairing.md
@.planning/phases/07.3-pi-archive-snapshot/07.3-09-PLAN.md
</context>

<execution_notes>
- **Task 1 is a gate that can end the session WAITING.** Do not build until it passes.
- Build-host rules (memory and 07.3-08): refer to the build host by role; rsync the tree from the Mac, never clone (the build host has no GitHub auth); clean worktree; `sudo rm -rf build/pi-gen-work` before the build; watch with `pgrep -f 'build-image[.]sh'`, never the bare pattern (it matches its own poll); never `echo pw | sudo -S … | tee` (it wrote a password into `/etc/fstab` once); loop-mount the image **read-only** (`-o ro`), because a rw mount rewrites the ext4 superblock and desyncs the `.bmap`. Card sizing: `CARD_SIZE_GB` is GiB, so use the value 07.3-08 used for the test card.
- Read the diff before accepting it. If anything other than the four expected `pkg` rows (and the environment rows) moves, stop and report it; do not accept an unexplained change.
</execution_notes>

<tasks>

<task type="auto">
  <name>Task 1: Preconditions (gate; may end WAITING)</name>
  <files>(none; evidence only)</files>
  <action>
All must hold; record each with its evidence:
1. PR #201 (the fix for #200) is merged on main: `grep -c FIRST_USER_PASS pi-gen/config` is 0 and #201's build gate exists (name it from #201's merged diff).
2. Plans 08-01 through 08-26, including 08-07b, 08-15b and 08-29, are merged to main (each SUMMARY exists; `git log main --oneline` shows each plan's commits).
3. N10: either 07.3-09 is closed (its SUMMARY exists and ADR-0010 is Accepted), or 07.3-09 was amended to build from `c008e84` and that amendment is on main. If neither, report `WAITING: 07.3-09 build B has not run and is not pinned to c008e84` and stop.
4. `bash tests/phase-8/test-*.sh` all pass and `pytest runtime/pair/tests tests/phase-8` passes in the bookworm container on main's head.
  </action>
  <verify>
    grep -c FIRST_USER_PASS pi-gen/config   # expect: 0
    ls .planning/phases/08-first-boot-pairing-and-wake-word/08-2[0-6]-SUMMARY.md .planning/phases/08-first-boot-pairing-and-wake-word/08-07b-SUMMARY.md .planning/phases/08-first-boot-pairing-and-wake-word/08-15b-SUMMARY.md .planning/phases/08-first-boot-pairing-and-wake-word/08-29-SUMMARY.md
  </verify>
  <done>Every precondition is proven, or the plan stopped WAITING with the reason.</done>
</task>

<task type="auto">
  <name>Task 2: Build with accept, re-record, inspect the rootfs</name>
  <files>docs/operations/phase-07.2-inputs.reference, docs/operations/phase-8-pairing.md</files>
  <action>
- rsync main's head to the build host; `sudo rm -rf build/pi-gen-work`; `ARLOWE_INPUTS_ACCEPT=1 scripts/build-image.sh 2>&1 | tee build/logs/phase-08-build.log`.
- Read the printed inputs diff. Expected: `+pkg python3-qrcode 7.4.2-2`, `+pkg python3-png 0.20220715.0-1`, `+pkg python3-typing-extensions 4.4.0-1`, `+pkg python3-argon2 21.1.0-2`, and environment rows. Anything else: stop.
- Copy the re-recorded reference back and commit it as `chore(08): record the Phase 8 packages in the inputs reference`.
- Loop-mount the image's system slot **read-only** and check, recording each result:
  - `etc/systemd/system/multi-user.target.wants/` links `arlowe-pair.service`, `arlowe-radio-init.service`, `arlowe-factory-reset-resume.service`, and still the six runtime units and `arlowe-identity-init.service`;
  - `etc/systemd/system/arlowe-pair-commit.service` and `arlowe-factory-reset@.service` exist and are not linked into any target;
  - `etc/polkit-1/rules.d/51-arlowe-networkmanager.rules`, `etc/NetworkManager/dnsmasq-shared.d/arlowe-captive.conf`, `etc/modprobe.d/arlowe-wifi-regdom.conf`;
  - `var/lib/dpkg/status` has `python3-qrcode` and `python3-argon2` `install ok installed`;
  - `opt/arlowe/runtime/pair/__main__.py`, `opt/arlowe/runtime/cli/{pair-commit,factory-reset,radio-init}`;
  - `etc/arlowe/config.yml` absent.
  - **`/etc/arlowe` mode in both slots (08-29).** Loop-mount p2 and p3 each **read-only** and, for each: `gid=$(awk -F: '$1=="arlowe"{print $3}' "$mnt/etc/group")` (the image's own GID; the build host has no `arlowe` name, so never use `%G` or a host lookup); `stat -c '%a %u %g' "$mnt/etc/arlowe"` must print `770 0 $gid`. Record both lines. A `755` in either slot means a post-build script reset it again: stop, do not hand the image to 08-27b.
- Add the evidence block to the runbook.
  </action>
  <verify>
    grep -c 'Build complete' build/logs/phase-08-build.log                       # expect: 1
    grep -cP '^pkg\tpython3-(qrcode|png|typing-extensions|argon2)\t' docs/operations/phase-07.2-inputs.reference   # expect: 4
    git diff --shortstat main -- . ':(exclude).planning/**'                        # expect: ~55
  </verify>
  <done>An image with all of Phase 8 exists, its rootfs is proven to carry the phase, and the reference is re-recorded.</done>
</task>

</tasks>

<verification>
- A second build from the same commit without the accept would pass the diff gate (not run here; 08-27b's rebuild, if one is needed, proves it).
</verification>

<success_criteria>
08-27b has a proven image to flash.
</success_criteria>

<output>
After completion, create `.planning/phases/08-first-boot-pairing-and-wake-word/08-27a-SUMMARY.md`.
</output>
