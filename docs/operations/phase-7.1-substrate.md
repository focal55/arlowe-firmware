# Phase 7.1 runtime substrate: reference and SC6 procedure

**Status:** Part A is reference and is true of the current branch. Part B (SC6)
is a **hardware checkpoint that has not been run**. Until it is, no claim in
this repo about a unit reaching `active` on a device has been observed.

This file has two halves:

- **Part A** — what the substrate is, where each piece comes from, and exactly
  where the three build-time gates stop. Read this before changing anything
  under `pi-gen/stage-arlowe/01-runtime/`.
- **Part B** — the SC6 procedure. Build, flash, boot, and record.

Build and flash mechanics are **not** duplicated here. They live in
`docs/operations/phase-6-build-flash-deploy.md`. Part B references that file and
adds only what is specific to 7.1.

---

# Part A — the substrate

## What the substrate actually is

Say this precisely or not at all. The imprecise version of this sentence is what
the phase's own checker caught.

**Six shipping runtime service units.** These are the units Phase 8's pairing
daemon starts after pairing. They ship **installed but disabled** — see
`pi-gen/stage-arlowe/03-firstboot/00-run-chroot.sh`, which deliberately enables
only `arlowe-identity-init` because a factory device must derive its identity
before any pairing.

| Unit | Interpreter it names | Where |
|---|---|---|
| `arlowe-voice` | `/opt/arlowe/venvs/voice/bin/python` | `units/arlowe-voice.service:23,24` |
| `arlowe-face` | `/opt/arlowe/venvs/voice/bin/python` | `units/arlowe-face.service:19,20` |
| `qwen-tokenizer` | `/opt/arlowe/venvs/llm/bin/python` | `units/qwen-tokenizer.service:15,16` |
| `whisper-stt` | `/opt/arlowe/venvs/stt/bin/python` | `units/whisper-stt.service:11` |
| `arlowe-dashboard` | `/opt/arlowe/node/bin/node` | `units/arlowe-dashboard.service:28` |
| `qwen-api` | none — execs `run_api.sh` | `units/qwen-api.service:15` |

So: **three distinct venv interpreter paths, across seven `Exec*` stanzas in
four units**, plus one Node entry point, plus one unit that touches no
interpreter this phase provisions. Four of the seven venv stanzas are
`ExecStartPre=... -m arlowe_config_validate`; `whisper-stt` has none.

**Do not write a count without the enumeration beside it.** The counts in this
phase differ depending on what is being counted, and every one of them is
correct in its own frame:

| Count | What it counts |
|---|---|
| **6** | shipping runtime *service* units — the six above, the SC6 subject |
| **7** | first-party units in `units/*.service` — the six plus `arlowe-identity-init` |
| **8** | first-party units installed into slot A's `/etc/systemd/system` — the seven plus `arlowe-firstboot` from `pi-gen/stage-arlowe/03-firstboot/files/` |
| **15** | units a *real built rootfs* actually contains — the eight plus **seven** `systemctl enable` dbus aliases apt leaves in `/etc/systemd/system`: `sshd`, `dbus-fi.w1.wpa_supplicant1`, `dbus-org.bluez`, `dbus-org.freedesktop.Avahi`, `dbus-org.freedesktop.ModemManager1`, `dbus-org.freedesktop.nm-dispatcher`, `dbus-org.freedesktop.timesync1`. This row said **9** until the 07.2 build was measured; it was a prediction from one apt unit, and the real number is seven |
| **5** | units with a Python entry point, which is what `unit-import-bookworm` covers — `arlowe-voice`, `arlowe-face`, `qwen-tokenizer`, `whisper-stt`, and `arlowe-identity-init` |

The 8-vs-15 gap is not cosmetic, and it is where the gates were wrong until the
07.2 build. Both gates glob the **rootfs's own** `/etc/systemd/system` rather
than the repo's unit source directory, which is the design — a gate that only
checks what the repo ships cannot see what apt adds. But the seven apt entries
are **symlinks with absolute targets**
(`sshd.service -> /lib/systemd/system/ssh.service`), and two things followed:

- **The gate read the build host.** Handing that absolute target to the kernel
  follows it outside the rootfs. The gate parsed the host's trixie unit files
  and failed the bookworm rootfs by them — it reported the host's
  `ExecStart=/usr/libexec/nm-dispatcher` (NetworkManager 1.52.1) missing, while
  the rootfs's own unit correctly names `/usr/lib/NetworkManager/nm-dispatcher`
  (1.42.4), present at 68024 bytes. The false FAIL was the visible half; a host
  that happens to carry what the image lacks would have produced a false **PASS**
  from the same bug, which is the class the gate exists to catch. Unit files now
  resolve through `_vue_resolve` exactly as executable paths always did.
- **The two gates need different scopes.** The path gate stays universal: a unit
  naming a binary the rootfs lacks is a real defect whoever shipped it. The
  version gate does not — a floor is a claim about software *we* chose, and
  demanding one of `sshd`'s `/bin/kill` produced six failures about nothing.
  Ownership is now derived per unit from the rootfs's own dpkg database
  (`_vue_unit_owner`), so apt-owned units are skipped by name and package. The
  alternative — pasting every OS interpreter into `EXPECTED_UNDECLARED` — would
  have converted a derived guard into a hand-maintained list, which is the F7 #18
  shape one layer up.

`EXPECTED_UNDECLARED` therefore covers **repo-shipped units only**, and an
undeclared interpreter in one of ours is still a FAIL. `nm-dispatcher` was
removed from it: the scoping makes the entry dead, and a dead allowlist entry is
the start of a list nobody can justify.

The 5 is the one the roadmap originally under-counted at four.
`arlowe-identity-init` runs `/opt/arlowe/runtime/cli/identity`, which is
`#!/usr/bin/env python3` and deliberately carries no `.py` extension so the CLI
symlink installer produces `arlowe-identity`. An entry-point rule keyed on
`-m` or `.py` skips it — and it is the single consumer whose missing `yaml` and
`jsonschema` were this phase's original motivating defect (F7 #18). The checker
keys on the **shebang** as well, so it is covered, under the system `python3`
the image contract gives it rather than under a venv.

## Where the venvs come from

`pi-gen/stage-arlowe/01-runtime/files/build-venvs.sh`, run in the chroot at step
7 of `00-run-chroot.sh`. It creates three venvs under `/opt/arlowe/venvs` with
`--system-site-packages`, so they *see* the apt layer in
`pi-gen/stage-arlowe/00-packages/00-packages-nr` rather than carrying private
copies of compiled modules.

The pinned inputs are five files, not three:

```
pi-gen/stage-arlowe/01-runtime/files/venv-requirements/
  constraints.txt      shared ABI floor; pins numpy to the apt candidate
  voice.txt            resolver on
  voice-nodeps.txt     installed --no-deps  (see below)
  llm.txt
  stt.txt
```

`voice` installs in **two passes**. `--no-deps` is a command-line flag, not a
valid requirements-file directive, so the set is split by file: `voice.txt` with
the resolver on, then `voice-nodeps.txt` with `--no-deps`. Running only the
first yields a venv where `import noisereduce` raises. The condition in
`build-venvs.sh` is on the **file name** (`<name>-nodeps.txt`), not on the venv
name, so a second one is a file drop rather than a code edit.

`ARLOWE_VENV_REQ_DIR` selects the requirement directory and its **default is the
chroot path**. The override exists so `tests/phase-07.1/docker/Dockerfile` can
invoke this same script instead of forking it; that container deliberately does
not set it, and instead stages the files at the default path, so the default is
what gets exercised. Do not invert that.

Why apt-over-pip at all, and the numpy and `noisereduce` decisions: **ADR-0008**
(`docs/architecture/0008-image-runtime-dependency-strategy.md`).

## Where `server.js` comes from

`pi-gen/stage-arlowe/01-runtime/files/build-dashboard.sh`.

`runtime/dashboard/next.config.ts` sets `output: "standalone"` and pins
`outputFileTracingRoot` to the dashboard directory. Without `output: "standalone"`,
`next build` emits **no `server.js` at all** and `arlowe-dashboard.service` names
a file that no build step could ever produce — which is what was actually
happening before this phase.

Next writes the standalone tree nested, and the nesting depth depends on the
tracing root, so `build-dashboard.sh` **locates** `server.js` and hard-fails
unless there is exactly one, rather than assuming a depth. It then relocates
`.next/static` and `public` beside it, because the standalone server does not
serve those from their build locations.

`pnpm` is pinned once, in `runtime/dashboard/package.json`'s `packageManager`
field. Both consumers derive from it: CI via `pnpm/action-setup`'s
`package_json_file`, and `build-dashboard.sh` via corepack. Neither restates the
version.

After relocation, `build-dashboard.sh` deletes pnpm's content-addressed global
store and corepack's cache. Those live under `/root`, outside both the directory
swap and `00-run-chroot.sh`'s reproducibility cleanup, and they are ~597 MB per
slot that a `du` of `/opt/arlowe` cannot see.

## Which Node, and why not bookworm's

**Vendored, SHA-256 pinned, `v24.21.0`**, from `third_party/node/manifest.yml`.
Installed to `/opt/arlowe/node`; the binary the unit names is
`/opt/arlowe/node/bin/node`. The digest is verified in the chroot at build time,
not only at fetch time.

apt `nodejs` and `npm` are **dropped** from `00-packages-nr`. Bookworm's
candidate is **18.20.4** and `next@16.1.6` declares `engines.node >= 20.9.0`, so
`/usr/bin/node` could never run the dashboard. Leaving an 18.20.4 sitting at a
path the unit no longer names is a trap the path gate passes by construction —
which is the whole reason the *version* gate exists.

Node **24** and not the Node 20 that earlier plan text and the roadmap named:
Node 20 "Iron" reached end of life on **2026-04-30**. Shipping it would bake a
permanently unpatched JS runtime into v1. The declared floor stays `>= 20.9.0`
because that number comes from `next`'s own `engines` metadata, and 24 clears
it. ADR-0008 owns this decision; `third_party/node/INSTALL.md` documents the
five fields that move together on a security bump.

## The three gates, and exactly where they stop

This is the section to read before assuming you are covered.

| Gate | Where | Proves |
|---|---|---|
| `verify_unit_execstart` | `scripts/lib/verify-unit-execstart.sh`, run from `scripts/build-image.sh` | Every `Exec*` executable and script argument named by **any** unit in the rootfs — apt's and ours alike — **resolves and is executable inside the rootfs** |
| `verify_unit_runtime_versions` | same file, same call site | For units **this repo ships** (ownership derived from the rootfs's dpkg database), the interpreter at that path **reports a version at or above a declared floor**, measured by a real `chroot ... --version`. apt-owned units are skipped by name and package: we did not choose their interpreters |
| `unit-import-bookworm` | `.github/workflows/ci.yml`, `tests/phase-07.1/` | Every Python import **reachable from a unit entry point resolves** under that unit's own interpreter, in an arm64 `debian:bookworm` container whose apt layer is derived from `00-packages-nr` |

**None of them proves the service does its job.** State that plainly, because
the next person to hit a gap needs to know where the gates stop, not to be
reassured that they are comprehensive.

The worked example is the reason the second gate exists at all. Before this
phase, `arlowe-dashboard.service` named `/usr/bin/node`. That path **existed** —
apt put bookworm's 18.20.4 there. `verify_unit_execstart` passed it, correctly
and uselessly: the binary is present, executable, and cannot run `next@16`. Path
existence is not capability. A gate that only asks "is it there" will pass an
image that cannot boot a single service.

Known gaps, all real today:

- **Transitive third-party imports are not walked.** The import gate walks
  *first-party* modules transitively and stops at the third-party boundary.
  `scipy`, `sklearn`, `joblib`, `onnxruntime` and `ctranslate2` are covered by
  `pip check` inside `build-venvs.sh` and by ADR-0008's ledger, not by the gate.
- **`sklearn` has no import statement anywhere in the repo.** It arrives through
  `pickle.load` of the wake-word verifier, so no AST walk can ever reach it. No
  gate will ever catch its removal.
- **Function-local imports run at call time, not start time.** Five exist today
  (`numpy`, `pyaudio`, `yaml` at five sites). All five currently also have a
  start-time import elsewhere in the same unit, which is the only reason they
  are safe. If a future change removes the start-time import, the failure moves
  from boot to first-use — much worse to discover.
- **Slot B is not gated, and would fail if it were.** `scripts/lib/recovery-stub.sh`
  clones slot A and prunes `/opt/arlowe/runtime/{voice,llm,stt,tts,dashboard,wake-word,face,lib}`
  but leaves every slot-A unit in `/etc/systemd/system`, including the
  `multi-user.target.wants` symlinks that enable them. A *correct* slot B
  therefore names targets that were deliberately deleted. That is a live defect
  in the recovery slot (issue #134), not a gate problem.
- **Version drift between dev pins and the image is a WARN, never a FAIL.**
  Divergence is often correct; the defect was that nothing compared the numbers.

## Adding a Python import to a unit-reachable module

The rule is ADR-0008's, stated as a procedure:

1. Work out whether the module is one Debian packages with a compiled extension.
   If yes it goes in `pi-gen/stage-arlowe/00-packages/00-packages-nr`. If Debian
   does not package it, it goes in one of
   `pi-gen/stage-arlowe/01-runtime/files/venv-requirements/{voice,llm,stt}.txt`,
   fully pinned with `==`.
2. **Exactly one of those two, never both, never neither.** Adding an import to
   a unit's reachable graph without adding it to one of them is the defect class
   this phase exists to close.
3. Pins are read back from `pip freeze --local` in an arm64 bookworm container.
   Never hand-written.
4. Push and let `unit-import-bookworm` confirm it. It takes ~80 seconds on the
   native arm64 runner.

The trap worth knowing: a unit can reach a first-party module that lives in
**another service's directory**. `arlowe-voice` imports `runtime/llm/router.py`
at module scope, which imports `filelock` — declared only in `llm.txt`, because
the obvious consumer of `runtime/llm` is `qwen-tokenizer`. The voice venv did
not have it, and `arlowe-voice` would have crash-looped on the first boot of
every device. Both path gates passed the whole time. Do not reason about which
venv needs a package from which directory the importing file sits in.

## On-device record of what was installed

`/opt/arlowe/venvs/<name>/FROZEN.txt` — `pip freeze --local` captured at build
time, `0644 root:arlowe`. When a device misbehaves and the question is "what is
actually installed on *this* unit", that file is the answer, and it does not
require the venv to be functional to read.

## The wake word needs no download step

Stated here so nobody re-derives it. `openwakeword==0.4.0` is a
`py3-none-any` wheel that **bundles its models**:

```
openwakeword/resources/models/hey_jarvis_v0.1.onnx      1271370
openwakeword/resources/models/melspectrogram.onnx       1087958
openwakeword/resources/models/embedding_model.onnx      1328103
```

`openwakeword/__init__.py` builds its `models` registry from
`os.path.dirname(os.path.abspath(__file__))`, so
`get_pretrained_model_paths()` — which `runtime/voice/voice_client.py:344`
calls, filtering for `'jarvis'` — resolves entirely from the installed package.
`openwakeword/model.py` imports `onnxruntime` and nothing else as a backend;
0.4.0 has no tflite path at all. A factory image needs no network fetch and no
model staging step for the generic wake word.

This also bounds a risk in the import gate: `unit-import-bookworm` resolves
module *specs*, so it could in principle pass on a package whose *data files*
were missing. For this package it cannot — the data ships in the wheel.

---

# Part B — the SC6 procedure

**SC6:** on a freshly flashed image, all six shipping runtime units reach
`active`.

This is the only criterion in Phase 7.1 that a container cannot satisfy. Phases
1, 3, 4, 5 and 6 all hit the same wall and all handled it the same way: a real
procedure, explicitly deferrable, recorded as unproven until run.

## What you need

- A **Pi 5** with the **AX accelerator** and the **Whisplay** attached.
- An SD card — **see the card-size trap below**.
- An **arm64 Linux build host**. The Mac cannot build: pi-gen needs loop devices
  and privileged mounts that Docker Desktop on macOS does not provide. In
  practice this is the dev Pi. The Mac *can* flash a `.img` it did not build.
- `AXCL_DEB` and a models cache. See `docs/operations/phase-6-build-flash-deploy.md`
  §Build §Prerequisites.

Which steps need which hardware:

| Step | Needs |
|---|---|
| `qwen-api` reaching `active` | the **AX accelerator** and the models partition |
| `arlowe-face` reaching `active` | the **Whisplay** |
| `arlowe-voice` reaching `active` | a capture device (`arlowe-voice` opens PyAudio) |
| `qwen-tokenizer`, `whisper-stt`, `arlowe-dashboard` | neither |

If part of the unit set cannot be brought up for a hardware reason unrelated to
this phase, **that is a partial result to record, not a failure of 7.1** — and
it must be written down as partial, not rounded up to a pass.

## Four traps that have already cost time on this hardware

Each of these was learned the hard way. They are here so they are not in
someone's memory.

**1. `CARD_SIZE_GB` is interpreted as GiB, not GB.**
`scripts/lib/partition-image.sh:137` computes `card_size_gb * 1024 * 1024 * 1024`.
`CARD_SIZE_GB=32` therefore produces a **34.36 GB** image, and a nominally-32 GB
SD card holds about 31.9 GB. **Use a 64 GB card for `CARD_SIZE_GB=32`.** A
same-nominal-size card always fails.

**2. Do not read-write loop-mount the image after the build.**
`build-image.sh` generates the `.bmap` at the end. A rw loop-mount — the obvious
way to inspect what got built — rewrites the ext4 superblock afterwards, and
`bmaptool` then aborts on a checksum mismatch mid-flash. Either mount `-o ro`,
or regenerate the map before flashing:

```bash
bmaptool create -o build/arlowe.img.bmap build/arlowe.img
```

**3. A build watcher using bare `pgrep -f "build-image.sh"` matches its own poll
command line** and reports RUNNING forever. Use a regex that cannot match
itself:

```bash
pgrep -f "build-image[.]sh"
```

**4. pi-gen must stay on its bookworm pin.** Unpinned master targets trixie,
whose keyring is a `.pgp` (bookworm ships `.gpg`) and whose stage2 pulls
trixie-only `rpi-*` packages. `build-image.sh` provisions the pin itself
(`PIGEN_REF="2026-06-18-raspios-bookworm-arm64"`) and records the ref in
`pi-gen/.arlowe-pigen-ref`. Do not check out a different pi-gen by hand.

## Step 1 — build, from a clean checkout of this branch

On the arm64 Linux build host:

```bash
AXCL_DEB=/path/to/axcl_host_aarch64_V3.10.2.deb \
ARLOWE_MODELS_DIR=/path/to/models-cache \
CARD_SIZE_GB=32 \
bash scripts/build-image.sh 2>&1 | tee build/sc6-build.log
```

`ARLOWE_VERSION_PROBE` must be **unset**. `build-image.sh` asserts this and
aborts if it is set, rather than unsetting it — an inherited value means someone
is either running the self-test's plumbing against a real build or trying to
make the gate lie, and both are events a build should announce.

**This is the first run of both gates against a real rootfs**, and the first
real test of whether plan 07.1-03's container fixtures matched reality. Two of
the three gate defects found in plan 07.1-04 were only visible against a real
rootfs; there may be more of that class. The version gate's `chroot` probe in
particular has only ever executed under emulation or against a fixture with
`ARLOWE_VERSION_PROBE` set — this is the first time it runs a real arm64 binary
on real arm64 silicon.

**Capture both gate blocks from the log.** They matter as much as the boot does.

```bash
grep -n "\[unit-execstart\]\|\[unit-versions\]" build/sc6-build.log
```

PASS for `verify_unit_execstart` looks like:

```
[unit-execstart] SKIP dbus-fi.w1.wpa_supplicant1: $MAINPID (env/specifier interpolation)
[unit-execstart] SKIP sshd: $SSHD_OPTS (env/specifier interpolation)
[unit-execstart] SKIP sshd: $MAINPID (env/specifier interpolation)
[unit-execstart] 15 unit(s), 28 target(s) checked, 0 failure(s), 0 warning(s), 3 skip(s)
[unit-execstart] OK   every Exec* target named by a unit resolves inside <rootfs>
```

That block is the measured 07.2 output, not an illustration. The unit count
should be **15** on a real rootfs, not 8 — see Part A — and this gate stays
universal, so all 28 targets across apt's units and ours are checked. It must
name all three venv interpreter paths across their seven stanzas and
`/opt/arlowe/runtime/dashboard/server.js`.

If the unit count reads 8, the apt aliases are being dropped rather than
checked, and the gate is measuring less than it claims.

PASS for `verify_unit_runtime_versions` looks like:

```
[unit-versions] OK   arlowe-dashboard: /opt/arlowe/node/bin/node reports 24.21.0 (floor 20.9.0)
[unit-versions] OK   arlowe-face: /opt/arlowe/venvs/voice/bin/python reports 3.11.2 (floor 3.11.0)
...
[unit-versions] SKIP dbus-fi.w1.wpa_supplicant1: shipped by wpasupplicant — apt owns its interpreter versions, not ARLOWE_RUNTIME_FLOOR
[unit-versions] SKIP sshd: shipped by openssh-server — apt owns its interpreter versions, not ARLOWE_RUNTIME_FLOOR
[unit-versions] UNDECLARED qwen-api: /opt/arlowe/runtime/llm/run_api.sh
[unit-versions] 2 interpreter(s) probed, 5 allowlisted undeclared, 0 failure(s), 7 skip(s)
[unit-versions] OK   every interpreter named by a unit meets its declared floor in <rootfs>
```

Three things to confirm rather than skim: the dashboard interpreter reports
**>= 20.9.0**; `qwen-api`'s `run_api.sh` appears as **UNDECLARED** rather than
being absent from the report; and each of the **7** apt units appears as a SKIP
**naming its owning package**. A target that silently drops out of a report is
this phase's own defect class, and a scope narrowing that cannot be seen in the
output is the same defect wearing a fix's clothes — so the skip prints the
package dpkg named, and a unit dpkg cannot account for is treated as ours and
gated in full.

## Step 2 — record the rootfs size for issue #135

Do this **before** flashing, on the build host, while the rootfs is still on
disk. This is the first chance to measure a real built rootfs; every figure
issue #135 has today was measured in a container or estimated against an empty
directory.

```bash
PIGEN_ROOTFS=$(find build/pi-gen-work -maxdepth 3 -name rootfs -type d | grep stage-arlowe | head -1)
sudo du -sh "$PIGEN_ROOTFS"
sudo du -sh "$PIGEN_ROOTFS/opt/arlowe" "$PIGEN_ROOTFS/opt/arlowe/venvs" \
            "$PIGEN_ROOTFS/opt/arlowe/node" "$PIGEN_ROOTFS/opt/arlowe/runtime/dashboard"
sudo du -sh "$PIGEN_ROOTFS/usr/include/boost" "$PIGEN_ROOTFS/usr/lib/gcc" 2>/dev/null
```

What the existing numbers are and why they are insufficient:

| Figure | Source | Why it is not the answer |
|---|---|---|
| 705 MB/slot for `/opt/arlowe` | plan 07.1-04, measured under emulation | `/opt/arlowe` is not the slot |
| ~271 MB/slot of Boost headers + gcc | plan 07.1-05, traced in a container | hard `Depends` of `python3-numpy` / `python3-scipy`, under `/usr`, invisible to a `du` of `/opt/arlowe` |
| "≈2–3 GB per slot", "16 GB is VIABLE" | ADR-0004 | estimated when `/opt/arlowe/venvs` was empty |

**Do not amend ADR-0004 from the container figures.** The whole-rootfs number
from this step is the first measurement that can settle it.

## Step 3 — flash

Mechanics: `docs/operations/phase-6-build-flash-deploy.md` §Flash. Re-read trap
1 (card size) and trap 2 (`.bmap` desync) before writing.

```bash
scripts/flash-sd.sh build/arlowe.img /dev/sdX --yes
```

**Before the card leaves the reader, provision a login.** The image ships no
account by design, so a card booted without one is unreachable: no SSH and no
console login. The only recovery is pulling power and moving the card again.
On the build host, with the card still at `/dev/sdX`:

```bash
sudo mount /dev/sdX1 /mnt
printf '%s:%s\n' <user> "$(openssl passwd -6)" | sudo tee /mnt/userconf.txt >/dev/null
sudo umount /mnt
```

`arlowe-userconf.service` creates the user from it on first boot and deletes the
file. Then `ssh-copy-id` with that password. Writing only the FAT partition keeps
the `.bmap`-flashed rootfs untouched.

## Step 4 — boot factory-fresh

Boot the Pi with **`/etc/arlowe/config.yml` ABSENT**. That absence is the
factory / ready-to-pair state (CONFIG-03) and it is the state SC6 is about.
Confirm it rather than assume it:

```bash
test -e /etc/arlowe/config.yml && echo "NOT FACTORY STATE" || echo "factory state confirmed"
```

## Step 5 — start the six units and record `is-active`

The six units ship **installed but disabled** — Phase 8's pairing daemon is what
starts them in production — so they must be started by hand here. Start in the
Phase 11 dependency order (`qwen-tokenizer` -> `qwen-api` -> `qwen-openai`,
`arlowe-face` -> `arlowe-voice`):

```bash
sudo systemctl start qwen-tokenizer qwen-api whisper-stt arlowe-face arlowe-voice arlowe-dashboard
sleep 15
systemctl is-active qwen-tokenizer qwen-api whisper-stt arlowe-face arlowe-voice arlowe-dashboard
```

**PASS = six lines of `active`.** Report all six verbatim.

If any unit is not `active`, capture it in full. Do not summarize:

```bash
for u in qwen-tokenizer qwen-api whisper-stt arlowe-face arlowe-voice arlowe-dashboard; do
  systemctl is-active --quiet "$u" || { systemctl status "$u" --no-pager; journalctl -u "$u" -n 50 --no-pager; }
done
```

A failure here is the most valuable output this phase can produce. Every defect
found in waves 1–3 was found by reading output, not by reading an exit code.

## Step 6 — SC5 on hardware: the verifier-absent wake path

```bash
test -e /var/lib/arlowe/wake-word/verifier.pkl && echo "PRESENT (not factory state)" || echo "absent, as expected"
journalctl -u arlowe-voice --no-pager | grep -i "wake gate"
journalctl -u arlowe-voice --no-pager | grep -i "FileNotFoundError"
```

**PASS =** the pickle is absent; the journal shows the **generic-mode** line with
base threshold **0.7**; and the `FileNotFoundError` grep returns **nothing**.

## Step 7 — SC3 on hardware: the dashboard serves unpaired

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:3000/
```

**PASS = `200`**, with no config overlay present.

## Step 8 — on-device sizing

```bash
du -sh /opt/arlowe/venvs
df -h /
df -h /opt/arlowe/models
```

Report all three against ADR-0004's card budget, alongside the whole-rootfs
figure from step 2.

## What to expect that is NOT a failure

Read this before concluding anything failed.

- **`boot-check --first-boot` reports failures for the six runtime units.** They
  are disabled by design until pairing, so `is-active` is false and `boot-check`
  counts each as a FAIL. It also reports the deferred NPU and audio checks as
  failures. This is finding #24 and it is expected on a factory device. The six
  units being down at *boot* is correct; the SC6 question is whether they come
  up when started, which is step 5.
- **`boot-check` exits 0 regardless.** It has no `set -e`, no explicit exit, and
  its last statement is an `echo`. So `arlowe-firstboot` succeeds even when
  `boot-check` prints FAIL lines. **A green `arlowe-firstboot` is not evidence
  that `boot-check` passed** — read the journal, not the unit state.
- **`arlowe-firstboot` ends `inactive (dead)`.** Correct. The unit is
  `Type=oneshot` with `RemainAfterExit=no`, so it returns to inactive after a
  successful run. `failed` would be the problem; `inactive (dead)` is not.
- **Slot B ships slot A's units enabled with their runtime deleted** (issue
  #134). It is a known-bad comparison target. **Do not run these gates or these
  commands against slot B** — it will fail, correctly, for a reason that has
  nothing to do with SC6.
- **Version-drift WARNs in CI** between `runtime/*/requirements.txt` and the
  image. Divergence between the dev unit and the image is often correct. The
  defect was that it was invisible, not that it exists.

## Recording the result

Whatever happens, write it down here in a new `## SC6 results` section:

- the six `is-active` values, verbatim;
- both gate blocks from the build log;
- the journal line from step 6 and the HTTP code from step 7;
- the sizing figures from steps 2 and 8, for issue #135;
- for anything not `active`: the full `systemctl status` and `journalctl -n 50`.

Then update `.planning/ROADMAP.md`'s Phase 7.1 status and the `## Progress` row
to match. If the run is partial, say partial. A phase closed on container
evidence reproduces exactly the mistake this phase exists to correct — a
document asserting a state the hardware had never confirmed.

---

## SC6 results — 2026-09-25

**SC6 is met: all six units reach `active`.** With one qualification stated up
front, because this runbook exists to stop a phase being closed on evidence the
hardware never produced.

### The qualification

Five of six reached `active` on a **clean flash, untouched**. The sixth,
`qwen-api`, needed a one-line unit change applied by hand on the running device.
That change is now on `main` (`0a4a1fb`) and will be in the next image, but **no
image has yet been built containing it**. So:

| | |
|---|---|
| verified from a clean flash | 5 of 6 |
| verified on hardware, fix now on `main`, not yet in an image | 6 of 6 |

The honest headline is the second line with the caveat attached, not either
number alone.

**Superseded the same afternoon:** an image built from the fix reached 6 of 6
from a clean flash with no hand changes. See [§SC6 re-run from a clean
image](#sc6-re-run-from-a-clean-image--2026-09-25-afternoon).

### The six, verbatim

```
qwen-tokenizer: active
qwen-api: active
whisper-stt: active
arlowe-face: active
arlowe-voice: active
arlowe-dashboard: active
```

Sampled twice 60 s apart with identical PIDs, and `systemctl list-units
--state=failed` reporting `0 loaded units listed.`

### Step 6 — SC5, the verifier-absent wake path

```
[2/4] Wake gate: generic model, base threshold 0.7
      (no verifier at /var/lib/arlowe/wake-word/verifier.pkl - device not personalized)
🎤 LISTENING FOR WAKE WORD
```

### Step 7 — SC3, the dashboard serves unpaired

`HTTP 200` on `localhost:3000`, with `/etc/arlowe/config.yml` absent — the
CONFIG-03 unpaired state, which is correct for a factory-fresh device.

### Step 8 — on-device sizing, for issue #135

```
/dev/root        3.5G  3.2G  278M  93%  /
/dev/mmcblk0p4   2.9G  142M  2.7G   5%  /var/lib/arlowe
/dev/mmcblk0p5    47G  6.2G   41G  14%  /opt/arlowe/models
```

Measured rootfs at build time: **2942 MiB**; slot: **3712 MiB**.

Before the sizing fix the same layout produced a 3.2 GB slot with **0 bytes
available**, which is not a near miss — it blocked `apt-get update` from writing
a package list, and so blocked diagnosing anything on the device at all. #135 is
closed on these figures.

### NPU

```
0  AX8850  V3.10.2 | 0001:03:00.0 |  182 MiB /  945 MiB
   46C               | 4983 MiB / 7040 MiB
```

The model is resident on the accelerator. `qwen-api` logs
`AXCLWorker start with devid 0`.

### What it took to get here

Nine builds and three flashes. Nine defects, **none of which a container can
reproduce**:

| defect | why no container finds it |
|---|---|
| units shipped disabled | the test asserted `test -f`, not the `.wants` symlink |
| `mbind` killed by seccomp | no `numa=fake=8` in a container |
| `whisper-stt` read-only HF cache | `ProtectSystem=strict` never exercised |
| lgpio read-only CWD | same |
| HAT device tree absent | no `config.txt` in a container |
| `DeviceAllow` granting nothing, ×3 | absent, nonexistent and unexpandable entries are all valid syntax |
| Piper never installed, pin wrong twice | nothing dereferenced the pin |
| ax-llm never built | a consumer with no producer |
| slots sized from apparent size | `du -sb` implies `--apparent-size` |

Four further builds died on defects in the build code itself — an unexported
`REPO_ROOT`, a staging allowlist, an inverted `ldconfig` guard, a missing gate
allowlist entry. `shellcheck` was clean on all four. Each was visible only
inside pi-gen's chroot, which is an argument for making that loop cheaper before
Phase 8 adds to it.

### Corrections to earlier claims in this document

- **The AX650 was never faulty.** This document previously implied `qwen-api`
  needed the accelerator in a way the other units did not. It needed
  `/dev/msg_userdev`, which its unit did not grant. `axcl-smi` talked to the card
  throughout, because it is not sandboxed.
- **`arlowe-voice` was not a hardware deferral.** It was recorded as needing a
  capture device that was absent. The device was attached; the image never
  enabled the HAT's device tree, so no soundcard existed.

### Still open

- **#146** — three Pi-archive inputs pinned by digest, install path still via apt
- **#134** — recovery slot B ships slot A's units enabled with the runtime deleted
- ~~`Storage=volatile`~~ — closed by #157; see the re-run below

---

## SC6 re-run from a clean image — 2026-09-25 (afternoon)

**6 of 6 `active` from a clean flash, no hand changes.** This removes the
qualification above.

Image built from `6a4c538` (tree-identical to `main` after #158) on the arm64
build host; kernel `6.12.96+rpt-rpi-2712`. It contains `0a4a1fb` (qwen-api
device nodes), #150 (DeviceAllow gate) and #157 (persistent journal). The card
was touched after flashing only to add `userconf.txt` to the FAT boot partition
(see Step 3).

### Build gates, first run against a real rootfs

```
[unit-devices] 15 DeviceAllow assertion(s), 0 failure(s)
[OK]   Unit substrate gates passed: every Exec* target resolves, every interpreter meets its floor,
[OK]   and every DeviceAllow entry grants a device the unit can actually open.
[journal] OK   Storage=persistent (last set by /etc/systemd/journald.conf.d/50-arlowe-persistent.conf)
[journal] OK   /var/log/journal is bind-mounted from owner_state
[journal] OK   /var/lib/arlowe/journal exists in the owner_state skeleton
[OK]   Sanitize gate passed.
[OK]   Identity-store gate passed.
```

The first build attempt stopped earlier, at the build-inputs gate: #151 added
three pins without re-recording the reference. Every `pkg` row matched; #158
re-recorded it.

### The six, verbatim

```
qwen-tokenizer: active pid=685 restarts=0
qwen-api: active pid=916 restarts=2
whisper-stt: active pid=644 restarts=0
arlowe-face: active pid=684 restarts=0
arlowe-voice: active pid=690 restarts=0
arlowe-dashboard: active pid=641 restarts=0
```

Identical 60 s apart; `0 loaded units listed.` for failed units. Factory state
confirmed (`/etc/arlowe/config.yml` absent).

`qwen-api restarts=2` is a startup race, not a fault: it is ordered after
`qwen-tokenizer` but only waits for the process to start, not for port 12345 to
listen. ax-llm's ten connect retries run within one second with no delay, so it exits
255 and `Restart=on-failure` recovers it on the third attempt, about 40 s after
boot. It happens on every boot: #159.

### SC5 and SC3

```
[2/4] Wake gate: generic model, base threshold 0.7 (no verifier at /var/lib/arlowe/wake-word/verifier.pkl - device not personalized)
```

Verifier absent, `FileNotFoundError` count `0`. Dashboard: `200`.

### Persistent journal

```
/dev/mmcblk0p4[/journal] /var/log/journal
IDX BOOT ID                          FIRST ENTRY                 LAST ENTRY
 -1 f54ec57b2a834372893cd3621168ae75 Fri 2026-09-25 19:00:48 UTC Fri 2026-09-25 19:03:31 UTC
  0 37e7b373c3014ca4a2b94e7e16a92334 Fri 2026-09-25 19:07:45 UTC Fri 2026-09-25 19:08:58 UTC
```

Boot -1 is the first boot, ended by pulling power, not by a clean shutdown. Its
journal survived that and remains readable, including its own wake-gate line.
That is a stronger result than the planned clean reboot.

### Sizing

Rootfs 2.9G (`/usr` 2.0G, `/opt/arlowe` 777M). Slots 3.5G: A 84% used, B 80%.
Models grew to 51.0 GB on first boot. Detail on #135.

---

## References

- Build / flash / deploy mechanics: `docs/operations/phase-6-build-flash-deploy.md`
- A/B selector and recovery: `docs/operations/phase-6-ab-recovery.md`
- Partition layout: `docs/operations/phase-6-partitions.md`
- ADR-0004 (card sizing): `docs/architecture/0004-shared-model-partition-sizing.md`
- ADR-0008 (apt-vs-pip, numpy, noisereduce, Node): `docs/architecture/0008-image-runtime-dependency-strategy.md`
- The gates: `scripts/lib/verify-unit-execstart.sh`, `tests/phase-07.1/`
