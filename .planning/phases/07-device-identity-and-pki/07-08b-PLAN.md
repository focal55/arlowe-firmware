---
phase: 07-device-identity-and-pki
plan: 08b
type: execute
wave: 6
depends_on: ["07-08a"]
files_modified:
  - units/arlowe-identity-init.service
  - scripts/provision/install-arlowe-cli.sh
  - pi-gen/stage-arlowe/03-firstboot/00-run-chroot.sh
autonomous: true

must_haves:
  truths:
    - "A device that boots for the first time has a device-id, a private key and a CSR before any human touches it"
    - "Files created by the boot unit are 0600 even though systemd's default UMask would make them 0644"
    - "If the identity store is missing or unmounted, the unit FAILS visibly — it is never silently skipped"
    - "arlowe-identity resolves on the device PATH, with no dangling symlink"
  artifacts:
    - path: "units/arlowe-identity-init.service"
      provides: "first-boot oneshot that derives the ID and generates the keypair + CSR"
      contains: "UMask=0077"
  key_links:
    - from: "scripts/provision/install-arlowe-cli.sh"
      to: "/usr/local/sbin/arlowe-identity"
      via: "CLIS array entry 'identity' symlinking to /opt/arlowe/runtime/cli/identity"
      pattern: "identity"
    - from: "units/arlowe-identity-init.service"
      to: "/opt/arlowe/runtime/cli/identity init"
      via: "ExecStart"
      pattern: "runtime/cli/identity"
    - from: "pi-gen/stage-arlowe/03-firstboot/00-run-chroot.sh"
      to: "/etc/systemd/system/multi-user.target.wants/arlowe-identity-init.service"
      via: "wants symlink, because systemctl enable does not work in a chroot"
      pattern: "arlowe-identity-init"
---

<objective>
Make the CLI from plan 07-08a actually run on a device: the first-boot unit and the image wiring
that enables it.

Purpose: SC2 requires that a device boots and derives its ID with no human, no network and no
account. That only happens if the unit is enabled on the factory image and the CLI resolves on
PATH. Both are wiring this repo has gotten wrong before, in ways that failed silently.
Output: `units/arlowe-identity-init.service` plus the two wiring edits.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/STATE.md
@.planning/phases/07-device-identity-and-pki/07-08a-SUMMARY.md
@scripts/provision/install-arlowe-cli.sh
@scripts/provision/install-arlowe-fs.sh
@units/arlowe-face.service
@units/install-units.sh
@pi-gen/stage-arlowe/03-firstboot/00-run-chroot.sh
@pi-gen/stage-arlowe/03-firstboot/files/arlowe-firstboot.service
</context>

<tasks>

<task type="auto">
  <name>Task 1: The first-boot identity unit</name>
  <files>units/arlowe-identity-init.service</files>
  <action>
Create `units/arlowe-identity-init.service`. `units/install-units.sh` globs `units/*.service`, so the
file only needs to exist there; no installer edit is required.

```
[Unit]
Description=Arlowe device identity initialization
After=local-fs.target
Before=arlowe-firstboot.service multi-user.target
# The identity store lives on the owner_state partition (p4), mounted at
# /var/lib/arlowe. RequiresMountsFor pulls in that mount unit and FAILS this
# unit if the mount is not there.
#
# Deliberately NOT `ConditionPathExists=/var/lib/arlowe/identity`. A failed
# Condition* makes systemd SKIP the unit -- one journal line, no failure state,
# `systemctl is-failed` says "no". This unit is the SC2-critical one: if it is
# skipped, the device has no identity and nothing reports a problem. This repo
# has lost roughly seven weeks to exactly that failure class (F7 #18 stage-root
# package list, #21 dangling symlink, #25 A/B flip). `identity init` exits 5
# with a message if the directory is absent, so the loud path is already built;
# do not put a silent one in front of it.
RequiresMountsFor=/var/lib/arlowe

[Service]
Type=oneshot
RemainAfterExit=yes
User=arlowe
Group=arlowe
# systemd's default UMask is 0022, and Python's default file mode is 0666 & ~umask,
# which yields 0644 and fails SC3's exact-0600 check. write_secret() also opens with
# O_EXCL and chmods explicitly; both belts are deliberate.
UMask=0077
Environment=PYTHONUNBUFFERED=1
Environment=ARLOWE_LIB=/opt/arlowe/runtime/lib
ExecStart=/opt/arlowe/runtime/cli/identity init
StandardOutput=journal
StandardError=journal

# Sandbox hardening — mirrors the six Phase 3 units.
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ProtectKernelLogs=yes
ProtectClock=yes
ProtectHostname=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
LockPersonality=yes
RestrictNamespaces=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
# No network: `init` is entirely offline. AF_UNIX only, for the journal socket.
RestrictAddressFamilies=AF_UNIX
ReadWritePaths=/var/lib/arlowe/identity

[Install]
WantedBy=multi-user.target
```

Notes that must survive into the file as comments:
- `ProtectSystem=strict` makes the whole filesystem read-only except `ReadWritePaths`, so
  `/var/lib/arlowe/identity` is the only writable path — which is also a hard guarantee that `init`
  cannot drop key material under `/opt/arlowe`.
- The unit runs as `arlowe` (uid 995, nologin, HOME=/var/lib/arlowe), so files land `arlowe:arlowe`
  with no chown step. `/var/lib/arlowe/identity` already exists at `arlowe:arlowe` 0700 on a freshly
  flashed image — created in the pi-gen chroot by `scripts/provision/install-arlowe-fs.sh:71` and
  mounted over by the owner_state partition (p4) at runtime.
- `RestrictAddressFamilies=AF_UNIX` is deliberate and is a real check on scope: if someone later
  makes `init` phone home, the unit fails rather than silently gaining a network dependency at boot.
- Unlike `arlowe-face.service`, there is no `ExecStartPre=... arlowe_config_validate`: `init` does
  not read the config overlay, and on a factory image the overlay is intentionally absent.

**Prove the failure is loud, not silent.** In the Phase 3 Docker testbed (or any systemd host), run
the unit with `/var/lib/arlowe` absent and confirm `systemctl is-failed arlowe-identity-init` reports
`failed` and the journal names the missing path. If the testbed cannot express the missing mount,
approximate it by pointing `ARLOWE_IDENTITY_DIR` at a nonexistent path and confirm the unit enters
`failed` (exit 5) rather than `inactive`. Record which of the two you ran in the SUMMARY — do not
claim the stronger check if you ran the weaker one.
  </action>
  <verify>
`systemd-analyze verify units/arlowe-identity-init.service` reports no errors (run on a Linux host or in the Phase 3 Docker testbed; note the result in the SUMMARY if the host cannot run it)
`grep -q "UMask=0077" units/arlowe-identity-init.service`
`grep -q "RequiresMountsFor=/var/lib/arlowe" units/arlowe-identity-init.service`
`! grep -q "^Condition" units/arlowe-identity-init.service` — no silent-skip condition of any kind
`grep -q "RestrictAddressFamilies=AF_UNIX$" units/arlowe-identity-init.service`
`bash scripts/sanitize/check.sh` exits 0 (the units gate also scans this file)
  </verify>
  <done>The unit exists, runs `identity init` as `arlowe` with `UMask=0077`, can write only `/var/lib/arlowe/identity`, has no network access, and **fails visibly** rather than being silently skipped when the identity store is absent — demonstrated, not asserted.</done>
</task>

<task type="auto">
  <name>Task 2: Wire the CLI and the unit into the image</name>
  <files>scripts/provision/install-arlowe-cli.sh, pi-gen/stage-arlowe/03-firstboot/00-run-chroot.sh</files>
  <action>
**`scripts/provision/install-arlowe-cli.sh`**: add `identity` to the `CLIS` array. The script already
fails loudly when a target does not exist (the F7 #21 fix), and the symlink step now runs after the
runtime rsync, so a wrong name cannot ship silently.

**`pi-gen/stage-arlowe/03-firstboot/00-run-chroot.sh`**: enable `arlowe-identity-init.service` with a
wants symlink, following the pattern already in that file for `arlowe-firstboot.service`:

```
install -d -m 0755 /etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/arlowe-identity-init.service \
       /etc/systemd/system/multi-user.target.wants/arlowe-identity-init.service
```

`systemctl enable` does not work in a chroot without systemd as PID 1; the symlink is the
equivalent and is what this repo already does.

Add a guard that the unit file actually landed in `/etc/systemd/system/` (installed earlier in the
chain by `units/install-units.sh`) and **fail the chroot step if it did not**. Do not create a
dangling wants symlink: a wants symlink to a missing unit is silently ignored by systemd at boot,
which is exactly the silent-no-op failure class that cost this project seven weeks
(F7 #18, #21, #25). Print a clear error naming the expected path.

**Deliberately enabled, unlike the six runtime units.** Those are installed-but-disabled by design
because Phase 8's pairing daemon starts them after pairing. This one must run on a factory device
before any pairing, because SC2 requires that a device boots and derives its ID — no human, no
network, no account. State that in the comment so a future reader does not "fix" it to match its
siblings.

Also update the comment block at the top of `00-run-chroot.sh` so the list of what the step installs
matches what it does.
  </action>
  <verify>
`shellcheck scripts/provision/install-arlowe-cli.sh pi-gen/stage-arlowe/03-firstboot/00-run-chroot.sh` is clean
`grep -q "identity" scripts/provision/install-arlowe-cli.sh`
`grep -c "arlowe-identity-init" pi-gen/stage-arlowe/03-firstboot/00-run-chroot.sh` is at least 2 (the guard and the symlink)
Docker testbed (or a scratch rootfs): run `units/install-units.sh` then `install-arlowe-cli.sh` against a tree containing `runtime/cli/identity`, and assert `/usr/local/sbin/arlowe-identity` resolves to an existing file — `test -e "$(readlink -f <root>/usr/local/sbin/arlowe-identity)"`, evaluated with the rootfs prefix, not against the host root (resolving an absolute link against the host is a bad test that has produced a false alarm here before)
Delete the unit from the scratch rootfs and re-run the chroot step: it must exit non-zero naming the expected path, and must NOT leave a dangling symlink behind
  </verify>
  <done>`arlowe-identity` is on the device PATH as a resolving symlink, and `arlowe-identity-init.service` is enabled on the factory image with no possibility of a dangling wants symlink — the guard is demonstrated by deleting the unit and watching the step fail.</done>
</task>

</tasks>

<verification>
- `shellcheck` clean on both edited shell scripts; `systemd-analyze verify` clean on the new unit.
- `bash scripts/sanitize/check.sh` exits 0.
- The unit contains no `Condition*` directive.
- `bash tests/phase-7/test-identity-store-check.sh` still passes.
- Net diff under 250 lines.
</verification>

<success_criteria>
- A factory device boots, runs `identity init` before any pairing, and ends up with a device-id, a 0600 private key and a CSR — with no human, no network and no account.
- Trap 4 is closed on both sides — `UMask=0077` in the unit and `O_EXCL` + explicit chmod in the code.
- Trap 6 stays closed: neither the wants symlink nor the unit can fail silently. Both failure paths are loud and both were demonstrated, not reasoned about.
</success_criteria>

<output>
After completion, create `.planning/phases/07-device-identity-and-pki/07-08b-SUMMARY.md`.
Record: the unit's enablement decision with its reason, the `RequiresMountsFor` choice and why
`ConditionPathExists` was rejected, which loud-failure demonstration was actually run (real missing
mount vs. approximated), and the chroot guard's error path.
</output>

**Budget note.** `pr-checks.yml`'s `size-check` excludes lockfiles only, not `.planning/`, so this plan's `SUMMARY.md` (~60-90 lines) counts against the net diff. Budget accordingly.
