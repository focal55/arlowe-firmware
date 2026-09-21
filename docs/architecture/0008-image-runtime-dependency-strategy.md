# ADR-0008: Image runtime dependency strategy — apt layer plus pinned venv residue

<!-- status: accepted -->
**Status:** Accepted
**Date:** 2026-09-12
**Phase:** 7.1 (Runtime substrate repair)
**Closes:** Plan 07.1-01; feeds SC2, SC3 and SC4

This ADR is **Accepted**, not Proposed. Unlike ADR-0007, nothing here waits on a staging
account or a bill: every claim below was measured in a `debian:bookworm` container on
`--platform linux/arm64` built from `pi-gen/stage-arlowe/00-packages/00-packages-nr`, and the
measurements are quoted inline.

## Context

Four of the six shipping units — `arlowe-voice`, `arlowe-face`, `whisper-stt`, `qwen-tokenizer` —
name an interpreter under `/opt/arlowe/venvs/{voice,llm,stt}/bin/python` across seven `Exec*`
stanzas. The image build never created any of them. `scripts/provision/install-arlowe-fs.sh`
recorded the deferral in its own comment ("venvs/ is empty in Phase 3; Phase 6 populates from
`runtime/*/requirements.txt`") and Phase 6 never did.

Part of why it never did is that nobody had written down what should go in them, and the obvious
answer is wrong. `runtime/*/requirements.txt` are dev pins captured from a development unit's
virtualenv. They are not installable against Debian bookworm's system layer, and the gap is not
marginal:

| Package | Dev pin in `runtime/*` | bookworm apt candidate |
|---|---|---|
| numpy | 2.3.5 | 1.24.2 |
| Pillow | 11.1.0 | 9.4.0 |
| scipy | 1.17.0 | 1.10.1 |
| scikit-learn | 1.8.0 | 1.2.1 |
| joblib | 1.5.3 | 1.2.0 |
| PyAudio | 0.2.14 | 0.2.13 |

Installing the dev pins into a venv would not merely bump versions — it would put a second numpy
in the image on top of the apt one. The system-python consumers (`arlowe-identity-init`,
`boot-check`) and the venv consumers would then disagree about array layout, and Phase 6 SC5
(input reproducibility) would break because an unpinned resolve floats to whatever PyPI served
that day.

There is also a second, unrelated defect in the same substrate, found while doing this work and
recorded here because it has the same shape: the dashboard's declared interpreter cannot run the
dashboard. See **Decision 4**.

## Decision

### 1. A `--system-site-packages` hybrid, with one declaration point per module

Each of the three venvs is created with `--system-site-packages`, so it *sees* the apt modules
rather than carrying private copies. The split rule:

> Anything with a compiled extension that Debian packages comes from **apt**. Everything Debian
> does not package is **pinned pip residue** in the venv.

Two reasons, in order of weight:

1. **It never has to build under the chroot.** The image is assembled in an emulated or
   cross-architecture chroot. A pip source build of scipy or PyAudio there is slow at best and a
   silent failure mode at worst. Debian already built these for arm64.
2. **One copy, shared.** The system-python consumers and the venv consumers resolve the same
   `numpy`, the same `Pillow`. There is no version to keep in sync because there is only one.

The single declaration point for every third-party module reachable from a unit entry point is
therefore exactly two places: `pi-gen/stage-arlowe/00-packages/00-packages-nr` and
`pi-gen/stage-arlowe/01-runtime/files/venv-requirements/{voice,llm,stt}.txt`. **Adding an import
to a unit's reachable graph without adding it to one of those two is the defect class this phase
exists to close.** It is the same defect that shipped `arlowe-identity-init` without
`python3-yaml` (F7 #18): the CI host and the CI test container both had the module, the rootfs
did not, and nothing compared them. Plan 07.1-05's `unit-import-bookworm` job is the recurring
check.

Two entries in the apt layer deserve calling out because no `import` line names them:

- **scipy** — nothing in `runtime/` imports it directly. It is a hard dependency of both
  `noisereduce` and `openwakeword`, which `voice_client.py` imports at module scope.
- **scikit-learn and joblib** — there is no `import sklearn` anywhere in the repo. `voice_client.py`
  loads the wake-word verifier with `pickle.load()`, and that pickle is a scikit-learn estimator
  produced by `openwakeword.custom_verifier_model`. Unpickling imports `sklearn` *from inside
  pickle*. A grep-for-imports audit finds nothing; the unit dies with `ModuleNotFoundError` raised
  from a `pickle.load` frame.

`fonts-dejavu-core` was considered and **rejected**. `runtime/recovery/arlowe-recovery.sh` imports
`ImageFont` but never calls it, and the `anchor="mm"` arguments its `draw.text` calls pass were
measured to work with Pillow 9.4.0's built-in bitmap font:

```
--- default-font anchor test (reproduces arlowe-recovery.sh:102) ---
anchor OK with default font
--- is any TTF present without fonts-dejavu-core? ---
(end ttf search)          # no TTF anywhere in base + python3-pil
--- fonts-dejavu-core installed size ---
2960 KiB
```

2.9 MB of unreferenced data. Noted as a follow-up, not a defect: the built-in bitmap font is
fixed at roughly 11px, so the recovery screen's text is small on the 240x280 display. Improving
that means editing `arlowe-recovery.sh` to load a TrueType face, and *that* change is what would
justify the font package.

### 2. numpy is pinned to the apt version; pip never shadows it

`constraints.txt` pins `numpy` to the apt candidate, and all three requirement files are installed
with `-c constraints.txt`. This is option (a).1 from the plan, and it **held** — no fallback to a
venv-local numpy was needed.

Evidence. A naive resolve floats numpy and drags a private copy in:

```
Would install ... numpy-1.26.4 ... onnxruntime-1.30.0 ... matplotlib-3.11.2
```

With `numpy==1.24.2` in the resolve, numpy disappears from the install set entirely in all three
venvs, and `pip freeze --local` (which lists only venv-local packages) contains no numpy in any of
them. onnxruntime 1.30.0 accepts numpy 1.24.2 at both resolve and import time — numpy 2.x-built
extensions retain runtime compatibility back to numpy 1.19, which is why the newest onnxruntime
did not need downgrading.

`constraints.txt` deliberately does **not** pin `huggingface_hub` or `tokenizers`. Measured, the
two venvs cannot agree on them:

| Package | llm venv | stt venv | Why |
|---|---|---|---|
| huggingface_hub | 0.36.2 | 1.31.0 | `transformers<5` caps it below 1.0; `faster-whisper` wants 1.x |
| tokenizers | 0.22.2 | 0.23.2 | pulled by the respective parent |

This overturns the plan's assumption that those two belong in the shared constraints file. They
are genuinely per-venv, and forcing either to a single version would break one of the two units.
Constraints are for what must not drift — the numpy ABI floor and the leaf utilities — not for
everything that happens to appear twice. Separate venvs exist precisely so this is allowed.

### 3. `noisereduce` is installed `--no-deps`

`noisereduce==3.0.3` declares `matplotlib`, which drags `contourpy`, `cycler`, `fonttools`,
`kiwisolver`, `pyparsing`, `python-dateutil` and `six`. `voice_client.py` uses noisereduce only as
`nr.reduce_noise(...)`, which touches none of it.

Measured, both ways, in the arm64 container:

| Voice venv | Size |
|---|---|
| `noisereduce` with declared deps (matplotlib chain) | **170 MB** |
| `noisereduce` `--no-deps`, real deps listed explicitly | **96 MB** |

and the functional check on the `--no-deps` venv:

```
--- functional check: reduce_noise without matplotlib ---
reduce_noise OK (16000,)
--- openwakeword import check ---
openwakeword OK
```

74 MB saved — twice over, since A and B are equal-sized slots and both carry this venv.
`reduce_noise` verified working on a synthetic 16 kHz array. `--no-deps` wins on measurement, not
assumption. Its real dependencies — numpy and scipy from apt, `tqdm` from pip — are listed
explicitly in `voice.txt` so the flag cannot silently drop something.

**This forced the voice venv into two files**, which the plan did not anticipate. `--no-deps` is a
command-line flag that applies to the whole invocation; it is **not** a valid requirements-file
directive. Measured:

```
$ cat r.txt
--no-deps
noisereduce==3.0.3
$ pip install -r r.txt
ERROR: Invalid requirement: --no-deps
pip: error: no such option: --no-deps
```

So the packages that need it must be installed separately from the packages that must keep their
resolver. The voice venv is therefore built in two steps, and `build-venvs.sh` (plan 07.1-04) must
run both:

```
pip install -r voice.txt        -c constraints.txt
pip install -r voice-nodeps.txt -c constraints.txt --no-deps
```

Running only the first yields a venv where `import noisereduce` fails. `llm.txt` and `stt.txt` need
no such split.

The cost of `--no-deps` is worth stating: pip will no longer notice if a future noisereduce bump
adds a dependency. That is why the version is pinned exactly, why its real needs are enumerated in
`voice-nodeps.txt`, and why plan 07.1-05's checker *imports* the module rather than trusting the
install to have succeeded.

### 4. Node comes from a SHA-pinned vendored tarball, and apt `nodejs`/`npm` are dropped

**The defect.** `units/arlowe-dashboard.service:18` runs `ExecStart=/usr/bin/node ...`.
`00-packages-nr` declared `nodejs`, whose bookworm arm64 candidate is **18.20.4**.
`runtime/dashboard` depends on `next@16.1.6`, whose `engines.node` is **>= 20.9.0**. So even once
plan 07.1-04 produces `server.js`, `/usr/bin/node` cannot execute it and `arlowe-dashboard` never
reaches `active`.

The comment that stood at `00-packages-nr:33` — *"nodejs from Debian bookworm is v18+;
dashboard/package.json targets >=18"* — was false twice over. `runtime/dashboard/package.json` has
no `engines` field at all; the floor that binds comes from `next`'s own metadata.

**Alternatives considered.**

*(iii) `nodejs` from bookworm-backports.* This would have been the cheapest option, so it was
checked first rather than dismissed:

```
# echo "deb http://deb.debian.org/debian bookworm-backports main" > /etc/apt/sources.list.d/bp.list
# apt-get update && apt-cache policy -t bookworm-backports nodejs
nodejs:
  Installed: (none)
  Candidate: 18.20.4+dfsg-1~deb12u2
  Version table:
     18.20.4+dfsg-1~deb12u2 500
        500 http://deb.debian.org/debian bookworm/main arm64 Packages
        500 http://deb.debian.org/debian-security bookworm-security/main arm64 Packages
```

The backports repository contributes **no nodejs entry at all** — the version table shows only
`bookworm/main` and `bookworm-security`. Rejected on evidence: apt cannot satisfy the floor at any
pinning.

*(i) The NodeSource apt repository.* Rejected. It adds a third-party package source with a
rotating signing key to a shipped consumer device, and an apt repo pins a *version range*, not
bytes. Phase 6 SC5 wants the same commit to install the same bytes.

*(ii) Downgrade `next` to 15.x to fit Node 18.* Rejected. It pushes a framework downgrade and a
lockfile churn into a substrate-repair phase, and forfeits Next 16 for the life of v1 to work
around a packaging problem.

**Decision: vendor the official Node tarball, SHA-256 pinned**, in `third_party/node/manifest.yml`,
in the shape `third_party/axcl/manifest.yml` and `third_party/models/manifest.yml` already use.
Unlike those two, its `url` is non-null — Node is MIT-licensed and publicly downloadable, so this
is a fetch-at-build pin rather than user-supplies-file. The tarball is never committed.

**Node 24, not Node 20.** The phase brief recommended "Node 20 LTS". Overturned. Node 20 "Iron"
reached **end-of-life on 2026-04-30**, four months before this ADR was written; shipping it would
bake a runtime that receives no further security patches into v1 for the life of the product. Node
24 "Krypton" is the Active LTS line and satisfies the same `>= 20.9.0` floor. From
`nodejs/Release/schedule.json`:

| Line | LTS from | Maintenance from | End |
|---|---|---|---|
| v18 Hydrogen | 2022-10-25 | 2023-10-18 | **2025-04-30** (dead) |
| v20 Iron | 2023-10-24 | 2024-10-22 | **2026-04-30** (dead) |
| v22 Jod | 2024-10-29 | 2025-10-21 | 2027-04-30 (maintenance) |
| **v24 Krypton** | 2025-10-28 | 2026-10-20 | **2028-04-30** (active) |

Pinned: `node-v24.21.0-linux-arm64.tar.xz`, sha256
`6ad1325edbdb5649c379b75a237147a666c95d4f9ae8d340fef2d1575d289ad2`, verified against
`https://nodejs.org/dist/v24.21.0/SHASUMS256.txt` and independently by hashing the downloaded
bytes.

**A pin with no route and no recurring gate is a decision that exists only on paper**, so three
things land with the manifest:

1. `scripts/verify-third-party.sh` grows a `third_party/node` stanza (Check 5) that hard-fails on
   hash mismatch or absence. It is a fourth near-identical hardcoded block — the gate has no
   generic manifest iteration, lines 19-22 name each manifest by hand — and that duplication is
   now worth a cleanup, but rewriting the build's hash gate is not substrate repair and is left
   for a later phase.
2. `pi-gen/stage-arlowe/01-runtime/00-run.sh` gains `third_party/node` in its staging loop, which
   previously listed only `third_party/axcl` and `third_party/whisplay-driver`.
3. `00-packages-nr` declares `curl`, `ca-certificates` and `xz-utils` — what the chroot needs to
   fetch and unpack the tarball. Lite's base set is not guaranteed to carry them, and an
   undeclared unpack dependency is the same shape as the missing `python3-yaml`.

**The fate of apt `nodejs` and `npm`: dropped.** Leaving bookworm's 18.20.4 at `/usr/bin/node`
while the unit's `ExecStart` points elsewhere is a live trap — see Consequences. The tarball
unpacks to the prefix the manifest declares (`/opt/arlowe/node`, interpreter at
`/opt/arlowe/node/bin/node`), `units/arlowe-dashboard.service` names that path explicitly (plan
07.1-04 applies it), and plan 07.1-03's interpreter-floor gate asserts its version. One Node in the
image, named by the unit, version-asserted by the gate. `npm` was unused either way: the dashboard
is pnpm (`pnpm-lock.yaml`, no `package-lock.json`).

## Consequences

### The SC1 gate's blind spot, stated plainly

Phase 7.1 SC1 adds a build-time gate that parses every unit's `ExecStart=` and `ExecStartPre=` and
fails if the named interpreter or script is absent from the built rootfs. That is the durable fix
for the venv class of defect, and it is worth having. But it proves **only that a path resolves**.
It never proves that the binary at that path is a version capable of running the thing it is
handed.

Node 18 versus `next@16` is the worked example. Had `nodejs` stayed in `00-packages-nr`,
`/usr/bin/node` would exist, the SC1 path gate would pass it **by construction**, and
`arlowe-dashboard` would still fail at runtime with an engines error. A gate that cannot fail on a
real defect in its own domain is worse than no gate, because it converts "unverified" into "green".

Two mitigations, both load-bearing:

- Plan 07.1-03 adds `verify_unit_runtime_versions` alongside the path gate, asserting an
  interpreter *version floor*, not just existence.
- Dropping apt `nodejs` removes the wrong-version binary from the image entirely, so there is
  nothing for a path gate to pass by accident. Removing the trap beats detecting it.

### Other consequences

- **Three venvs, ~552 MB total per slot**, against an empty directory before. Measured: voice
  96 MB, llm 174 MB, stt 282 MB. This is the cost of the units being able to start, and it is not
  optional. But it needs flagging against ADR-0004: that ADR's "model-free slot footprint ≈ 2–3 GB
  per slot" estimate, on which the "16 GB is VIABLE" conclusion rests, was made when
  `/opt/arlowe/venvs` was empty and "Python/ML deps" meant the apt layer only. Half a gigabyte per
  slot, twice, is ~1.1 GB of previously unaccounted weight. Plan 06-04's measure-then-set step
  should re-measure the assembled slot before the partition numbers are fixed, and the 16 GB
  viability claim should be re-checked rather than assumed to survive.
- **apt pins the Python floor.** `runtime/` code must stay within bookworm's numpy 1.24 and Pillow
  9.4 APIs. This is not new — the existing `python-floor-bookworm` CI job already enforces it for
  `cryptography` and `requests` — but it now extends to the numeric stack, and code written
  against numpy 2.x idioms will fail on device.
- **`runtime/*/requirements.txt` are now explicitly dev/CI-only.** Each carries an `IMAGE NOTE`
  header naming the image-side file that governs the device, in the shape
  `runtime/lib/requirements.txt` already used. The stale hand-sync instructions
  ("regenerate from pip freeze on the dev unit", "keep versions in sync if both import
  openwakeword") are deleted: they were manual-sync notes with nothing reading them, and the pins
  had already drifted. Enforcement moves to plan 07.1-05's `unit-import-bookworm` job, which
  resolves each import in a bookworm container and WARNs on drift.
- **Node security updates are now a manual bump.** A vendored tarball does not get `apt upgrade`.
  The manifest must be bumped and re-hashed when Node 24 releases a security patch. This is the
  price of pinning bytes, and it should be a recurring maintenance item rather than a surprise.
- **`RPi.GPIO` cannot be import-tested off-hardware.** It installs fine but raises
  `RuntimeError: This module can only be run on a Raspberry Pi!` at import. Plan 07.1-05's import
  checker must special-case it rather than treating the failure as a missing dependency.
- **`RPi.GPIO` on Pi 5 means `rpi-lgpio`, not apt `python3-rpi.gpio`.** apt's RPi.GPIO 0.7.1
  predates BCM2712 and raises `RuntimeError: Cannot determine SOC peripheral base address` at
  `GPIO.setup()`. That reads like absent hardware and is not: it fails with the HAT attached, and
  it is why `arlowe-face` restart-looped on the first flashed image. `rpi-lgpio` provides the same
  module name over lgpio, so the Apache-2.0 vendored driver stays unmodified. Off-hardware import
  behaviour is unchanged, so the special-case above still applies.

## The ledger

Every third-party top-level module reachable from a shipping unit's `Exec*` stanza, and the one
place it is declared. Derived by walking first-party imports transitively from the entry points in
`units/*.service`. Plan 07.1-05 consumes this.

| Module | Source | Reached from |
|---|---|---|
| numpy | apt `python3-numpy` | `voice_client.py`, `face/audio_sync.py`, `lib/arlowe_audio.py` |
| PIL | apt `python3-pil` | `face/face.py`; `recovery/arlowe-recovery.sh` |
| scipy | apt `python3-scipy` | transitive: noisereduce, openwakeword |
| sklearn | apt `python3-sklearn` | implicit: `voice_client.py` `pickle.load()` of the verifier |
| joblib | apt `python3-joblib` | transitive: sklearn persistence |
| pyaudio | apt `python3-pyaudio` | `voice_client.py`, `lib/arlowe_audio.py` |
| yaml | apt `python3-yaml` | `arlowe_config`, `tts/tts_sync.py` |
| jsonschema | apt `python3-jsonschema` | `arlowe_config` (all four `arlowe_config_validate` stanzas) |
| requests | apt `python3-requests` | `lib/arlowe_cloud.py` |
| cryptography | apt `python3-cryptography` | `lib/arlowe_pki.py` |
| RPi.GPIO | pip `voice-nodeps.txt` (`rpi-lgpio`, shim over apt `python3-lgpio`) | WhisPlay driver |
| spidev | apt `python3-spidev` | WhisPlay driver |
| openwakeword | pip `voice.txt` | `voice_client.py` |
| onnxruntime | pip `voice.txt`, `stt.txt` | openwakeword; faster-whisper VAD |
| noisereduce | pip `voice-nodeps.txt` | `voice_client.py` |
| transformers | pip `llm.txt` | `llm/qwen2.5_tokenizer_uid.py` |
| filelock | pip `llm.txt` | `llm/router.py` |
| faster_whisper | pip `stt.txt` | `stt/stt_server.py` |
| ctranslate2 | pip `stt.txt` | transitive: faster-whisper |
| WhisPlay | neither — vendored | `face/face.py`; `third_party/whisplay-driver/` |
| node / next | neither — vendored | `arlowe-dashboard.service`; `third_party/node/` |

Two modules that appear in `runtime/*/requirements.txt` but are **not** in the ledger, and why:

- **Flask** (`runtime/face/requirements.txt`) — `face_service.py` uses stdlib `http.server`. Flask
  is aspirational, not reachable, and is not installed on the device.
- **urllib3 / charset-normalizer / certifi / idna** — reachable, but as apt `python3-requests`
  dependencies. Declaring them separately would be noise.

## Regenerating these pins

The pins in `venv-requirements/*.txt` are not hand-maintained. To regenerate after a dependency
bump, resolve in the container and read back what pip actually chose:

```
docker run --rm --platform linux/arm64 -v "$PWD:/repo" debian:bookworm bash -c '
  apt-get update -qq >/dev/null 2>&1
  mapfile -t P < <(sed "s/#.*//" /repo/pi-gen/stage-arlowe/00-packages/00-packages-nr \
                   | tr -s "[:space:]" "\n" | grep -v "^$")
  apt-get install -y -qq --no-install-recommends "${P[@]}" >/dev/null
  python3 -m venv --system-site-packages /v
  /v/bin/pip install <top-level names> "numpy==1.24.2"
  /v/bin/pip freeze --local'
```

`pip freeze --local` is the important part: in a `--system-site-packages` venv it lists only what
the venv itself carries, which is exactly the set that belongs in the file. Never run this on a
development machine — the resolution depends on the apt layer underneath it.

## Alternatives considered (Python layer)

| Option | Verdict | Reason |
|---|---|---|
| **apt for compiled deps + pinned pip residue in `--system-site-packages` venvs** | **SELECTED** | No chroot builds; one copy of each compiled module; every version pinned. |
| Fully isolated venvs (no `--system-site-packages`), everything from pip | Rejected | Forces source builds of scipy/PyAudio under an emulated chroot, and puts a second numpy in the image alongside the apt one the system-python consumers use. |
| Install `runtime/*/requirements.txt` directly, as the original Phase 3 comment assumed | Rejected | Not installable against bookworm's system layer (see the table in Context). This is the assumption that produced the gap. |
| One shared venv for all four units | Rejected | `transformers<5` and `faster-whisper` demand mutually exclusive `huggingface_hub` versions (0.36.2 vs 1.31.0). A single venv cannot satisfy both. |
| System-wide `pip install --break-system-packages` | Rejected | Puts unpinned pip packages under the same prefix apt manages; the next `apt upgrade` fights it. |
