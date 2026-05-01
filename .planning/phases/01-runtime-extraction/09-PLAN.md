---
phase: 01-runtime-extraction
plan: 09
type: execute
wave: 2
depends_on: ["01"]
files_modified:
  - .gitmodules
  - third_party/ax-llm  # submodule
  - third_party/axcl/manifest.yml
  - third_party/axcl/INSTALL.md
  - third_party/axcl/DISTRIBUTION-RIGHTS.md
  - third_party/README.md
  - scripts/verify-third-party.sh
  - .planning/phases/01-runtime-extraction/01-09-SUMMARY.md
autonomous: true

requirements:
  - "EXTRACT-09: ax-llm vendored as a git submodule under third_party/ax-llm/ (not copied)"
  - "EXTRACT-10: axcl_host_aarch64_V3.10.2.deb pinned by version + checksum; hash verified at image build"

must_haves:
  truths:
    - "third_party/ax-llm is a git submodule pointing at https://github.com/AXERA-TECH/ax-llm.git, branch axcl-context, pinned at commit df75c34c"
    - "third_party/axcl/manifest.yml pins axcl_host_aarch64_V3.10.2.deb by SHA-256 = 1d6bd551644df30e39e3adbe3f32ab9b1d4cdc9c9d12752c27ebc99b35725b94"
    - "third_party/axcl/DISTRIBUTION-RIGHTS.md records the investigation into whether the .deb can be re-hosted (research Q3)"
    - "scripts/verify-third-party.sh exits 0 only if the .deb on disk matches the pinned SHA-256 (or, if .deb is fetched, fetches and verifies before exiting 0)"
  artifacts:
    - path: ".gitmodules"
      provides: "Submodule registration"
      contains: "ax-llm"
    - path: "third_party/axcl/manifest.yml"
      provides: ".deb pin (version + sha256 + URL or hosting note)"
      contains: "1d6bd551644df30e39e3adbe3f32ab9b1d4cdc9c9d12752c27ebc99b35725b94"
    - path: "third_party/axcl/INSTALL.md"
      provides: "How to obtain the .deb if not committed"
      min_lines: 20
    - path: "third_party/axcl/DISTRIBUTION-RIGHTS.md"
      provides: "Research Q3 resolution: can we re-host or not?"
      min_lines: 20
    - path: "third_party/README.md"
      provides: "Overview of vendored deps + bump procedure"
      min_lines: 30
    - path: "scripts/verify-third-party.sh"
      provides: "Hash-check gate for image build"
      min_lines: 30
  key_links:
    - from: ".gitmodules"
      to: "https://github.com/AXERA-TECH/ax-llm.git"
      via: "submodule URL"
      pattern: "AXERA-TECH/ax-llm"
    - from: "scripts/verify-third-party.sh"
      to: "third_party/axcl/manifest.yml"
      via: "reads sha256 pin"
      pattern: "sha256\\|manifest\\.yml"
---

<objective>
Vendor `ax-llm` as a git submodule and pin `axcl_host_aarch64_V3.10.2.deb` by SHA-256. Resolve research Q3 (distribution rights for re-hosting the `.deb`) by writing `DISTRIBUTION-RIGHTS.md`. Provide `scripts/verify-third-party.sh` as the hash-check gate the image build (Phase 6) will run.

Purpose: Land EXTRACT-09 + EXTRACT-10. These do NOT affect the Phase 1 smoke test (the binaries are already installed system-wide on arlowe-1) but they DO block Phase 6 image build, so they need to be in place.

Output: submodule + manifests + verification script + provenance docs.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/REQUIREMENTS.md
@.planning/phases/01-runtime-extraction/01-RESEARCH.md
@.planning/phases/01-runtime-extraction/01-01-SUMMARY.md
</context>

<tasks>

<task type="auto">
  <name>Task 1: Add ax-llm as a git submodule pinned at axcl-context @ df75c34c</name>
  <files>
    .gitmodules
    third_party/ax-llm
  </files>
  <action>
Per research §EXTRACT-09 — verified state on arlowe-1:
- Origin: `https://github.com/AXERA-TECH/ax-llm.git`
- Branch: `axcl-context`
- HEAD: `df75c34ca2ed8fe55e7576204e4da9c5b5f88ad8`
- License: BSD-3-Clause

First, remove the placeholder `third_party/ax-llm/.gitkeep` from plan 01:
```bash
rm third_party/ax-llm/.gitkeep
rmdir third_party/ax-llm  # remove empty dir so submodule can take its place
```

Then add the submodule:
```bash
git submodule add -b axcl-context https://github.com/AXERA-TECH/ax-llm.git third_party/ax-llm
cd third_party/ax-llm
git checkout df75c34ca2ed8fe55e7576204e4da9c5b5f88ad8
cd ../..
git add .gitmodules third_party/ax-llm
```

Confirm `.gitmodules` looks like:
```
[submodule "third_party/ax-llm"]
    path = third_party/ax-llm
    url = https://github.com/AXERA-TECH/ax-llm.git
    branch = axcl-context
```

DO NOT migrate to the upstream `axllm` branch (research warned: that's a future capability decision and risks breaking the working build).
  </action>
  <verify>
```bash
test -f .gitmodules && \
  grep -q 'ax-llm' .gitmodules && \
  grep -q 'AXERA-TECH/ax-llm' .gitmodules && \
  cd third_party/ax-llm && \
  git rev-parse HEAD | grep -q '^df75c34c' && \
  echo OK
```
  </verify>
  <done>Submodule registered, pinned at the verified commit, on the verified branch.</done>
</task>

<task type="auto">
  <name>Task 2: Pin axcl deb by SHA-256 + investigate distribution rights</name>
  <files>
    third_party/axcl/manifest.yml
    third_party/axcl/INSTALL.md
    third_party/axcl/DISTRIBUTION-RIGHTS.md
  </files>
  <action>
Remove the placeholder `third_party/axcl/.gitkeep` from plan 01:
```bash
rm third_party/axcl/.gitkeep
```

**Investigate distribution rights** (research Q3):
- Search for the `.deb`'s public download URL: search Axera's website (`axera-tech.com` or similar) and GitHub releases for AXERA-TECH org
- Check the `.deb`'s metadata: SSH to arlowe-1 and run `dpkg-deb --info ~/axcl/axcl_host_aarch64_V3.10.2.deb` — look for license/copyright in the control file
- Check Axera's website for redistribution terms

**Author `third_party/axcl/DISTRIBUTION-RIGHTS.md`** with findings:
- Vendor: Axera (which company exactly — capture from package metadata)
- Public download URL (if any)
- License terms (whatever the package's `copyright` file says)
- **Decision** — pick one of:
  - **(a) Commit the .deb to repo** with Git LFS — only if redistribution is explicitly permitted
  - **(b) Host on a release asset / S3** — fetch by URL + sha256 at image build — preferred default unless we KNOW we have redistribution rights
  - **(c) User-supplies-file** at image build (no redistribution) — fallback if rights are unclear
- Recommendation if rights unclear: **(b) or (c)**, never default to (a)

**Author `third_party/axcl/manifest.yml`**:
```yaml
# axcl host driver pinning
# Phase 1 plan 09; references Q3 resolution in DISTRIBUTION-RIGHTS.md.

axcl:
  version: "V3.10.2"
  filename: "axcl_host_aarch64_V3.10.2.deb"
  sha256: "1d6bd551644df30e39e3adbe3f32ab9b1d4cdc9c9d12752c27ebc99b35725b94"
  # url: <set if hosted; null if user-supplies>
  url: null  # or actual URL after Q3 resolution
  install_to_image: true
  notes: "See third_party/axcl/INSTALL.md for sourcing instructions."
```

**Author `third_party/axcl/INSTALL.md`**:
- How to obtain the `.deb` (per the chosen strategy a/b/c)
- Where it lives in the image (`/opt/arlowe/third_party/axcl/` or wherever the image build wants it)
- Verification command (calls `scripts/verify-third-party.sh`)

20-50 lines.
  </action>
  <verify>
```bash
test -f third_party/axcl/manifest.yml && \
  python3 -c "import yaml; m = yaml.safe_load(open('third_party/axcl/manifest.yml')); assert m['axcl']['sha256'] == '1d6bd551644df30e39e3adbe3f32ab9b1d4cdc9c9d12752c27ebc99b35725b94'" && \
  test -f third_party/axcl/INSTALL.md && \
  test -f third_party/axcl/DISTRIBUTION-RIGHTS.md && \
  test "$(wc -l < third_party/axcl/DISTRIBUTION-RIGHTS.md)" -ge 20 && \
  grep -qi 'decision\|strategy' third_party/axcl/DISTRIBUTION-RIGHTS.md && \
  echo OK
```
  </verify>
  <done>manifest.yml validates with the expected SHA-256; INSTALL.md and DISTRIBUTION-RIGHTS.md exist; Q3 has a recorded decision.</done>
</task>

<task type="auto">
  <name>Task 3: Author scripts/verify-third-party.sh hash-check gate</name>
  <files>scripts/verify-third-party.sh</files>
  <action>
Author `scripts/verify-third-party.sh` (executable bash) that the image build (Phase 6) calls before proceeding:

Behaviour:
1. Read `third_party/axcl/manifest.yml` (parse with `python3 -c "import yaml; ..."` since pi-gen builds may have python3 but not necessarily `yq`).
2. Resolve the `.deb` path:
   - If env `AXCL_DEB` is set, use that.
   - Else look for `third_party/axcl/axcl_host_aarch64_V3.10.2.deb` (committed-strategy).
   - Else look for `/var/cache/arlowe-build/axcl_host_aarch64_V3.10.2.deb` (fetch-strategy default cache).
   - If none exist, error with message pointing at INSTALL.md.
3. Compute `sha256sum` and compare to manifest pin.
4. Verify ax-llm submodule is initialized and at the expected commit:
   ```bash
   git -C third_party/ax-llm rev-parse HEAD
   ```
   compare to `df75c34ca2ed8fe55e7576204e4da9c5b5f88ad8` (or read from a separate pin file if we want to externalize).
5. Print summary table: `[OK] axcl_host V3.10.2 sha256 matches`, `[OK] ax-llm @ df75c34c`.
6. Exit 0 only if all checks pass.
7. `set -euo pipefail` and clear error messages.
8. `--help` flag shows usage.

Make executable: `chmod +x scripts/verify-third-party.sh`.

Note: do NOT actually run the script in this task with a real `.deb` (the `.deb` may not be in the repo yet depending on the strategy). The verifier role tests the script with a constructed temp file matching the pinned hash.
  </action>
  <verify>
```bash
test -x scripts/verify-third-party.sh && \
  bash -n scripts/verify-third-party.sh && \
  scripts/verify-third-party.sh --help 2>&1 | grep -qi 'usage' && \
  grep -q '1d6bd551644df30e39e3adbe3f32ab9b1d4cdc9c9d12752c27ebc99b35725b94\|sha256' scripts/verify-third-party.sh && \
  echo OK
```
  </verify>
  <done>Script is executable, syntactically valid, has usage; references the SHA-256 pin (directly or via manifest read). The verifier gates the image build.</done>
</task>

<task type="auto">
  <name>Task 4: Author third_party/README.md (overview + bump procedure)</name>
  <files>third_party/README.md</files>
  <action>
Author `third_party/README.md`:

```markdown
# Vendored Third-Party Dependencies

This directory contains pinned external dependencies the runtime requires.

## Layout

| Path | Type | Pin |
|---|---|---|
| `ax-llm/` | Git submodule | branch `axcl-context` @ `df75c34c` |
| `axcl/` | .deb manifest | V3.10.2, sha256 1d6bd551... |
| `whisplay-driver/` | Provenance + decision (no source yet) | See `whisplay-driver/PROVENANCE.md` |

## ax-llm

Upstream: https://github.com/AXERA-TECH/ax-llm.git
License: BSD-3-Clause
Why pinned at `axcl-context` branch: the AX8850 over PCIe (M.2) uses the AXCL split-build path. Upstream's primary `axllm` branch is for a different deployment mode and risks breaking the working build. See research file at `.planning/phases/01-runtime-extraction/01-RESEARCH.md` §EXTRACT-09.

### Bump procedure
1. Test the new commit on a Pi 5 dev unit:
   ```bash
   cd third_party/ax-llm
   git fetch origin
   git checkout <new-commit>
   bash build_aarch64.sh  # confirm it builds
   ```
2. If build passes, run the smoke test (plan 13's procedure).
3. Commit the submodule pointer update + a SUMMARY entry recording the verified commit and the test result.

## axcl_host driver

`.deb` package providing the AXCL kernel modules + userspace runtime that the AX8850 needs.
- Pinned by SHA-256 in `axcl/manifest.yml`
- Distribution strategy: see `axcl/DISTRIBUTION-RIGHTS.md`
- Install path on image: see `axcl/INSTALL.md`

### Bump procedure
1. Obtain the new .deb from Axera.
2. `sha256sum` it; update `axcl/manifest.yml`.
3. Test installation on a Pi 5 dev unit; confirm `axcl-smi` reports the device.
4. Commit manifest update with the new pin.

## Verification gate

`scripts/verify-third-party.sh` runs at image build time. Returns 0 only if all pins match.
```

30-80 lines.
  </action>
  <verify>
```bash
test -f third_party/README.md && \
  test "$(wc -l < third_party/README.md)" -ge 30 && \
  grep -q 'ax-llm' third_party/README.md && \
  grep -q 'axcl' third_party/README.md && \
  grep -qi 'bump procedure' third_party/README.md && \
  echo OK
```
  </verify>
  <done>third_party/README.md documents what's vendored, why, and how to bump.</done>
</task>

</tasks>

<verification>
Phase-level checks for this plan:

```bash
# Submodule wired
grep -q 'AXERA-TECH/ax-llm' .gitmodules
git -C third_party/ax-llm rev-parse HEAD | grep -q '^df75c34c'

# axcl pin matches research SHA-256
grep -q '1d6bd551644df30e39e3adbe3f32ab9b1d4cdc9c9d12752c27ebc99b35725b94' third_party/axcl/manifest.yml

# Provenance + distribution rights resolved
test -f third_party/axcl/DISTRIBUTION-RIGHTS.md && wc -l < third_party/axcl/DISTRIBUTION-RIGHTS.md

# Verification script is executable + valid bash
bash -n scripts/verify-third-party.sh
```

PR size: ~10 lines `.gitmodules` + ~30-line manifest + ~30-line INSTALL + ~30-line DISTRIBUTION-RIGHTS + ~50-line README + ~50-line shell script ≈ 200 net new lines. Well under 400.
</verification>

<success_criteria>
- ax-llm submodule pinned at branch `axcl-context` @ `df75c34c`
- axcl manifest pins SHA-256 1d6bd551... matching live arlowe-1
- DISTRIBUTION-RIGHTS.md resolves Q3 with a decision
- INSTALL.md describes how to source the .deb
- third_party/README.md documents bump procedures
- scripts/verify-third-party.sh exists, executable, valid
- EXTRACT-09 + EXTRACT-10 complete (verification scriptable, ready for Phase 6 image build to run)
</success_criteria>

<output>
After completion, create `.planning/phases/01-runtime-extraction/01-09-SUMMARY.md` documenting:
- ax-llm submodule details (URL, branch, commit)
- axcl SHA-256 pin
- Distribution-rights decision (a/b/c)
- Verification gate readiness
</output>
