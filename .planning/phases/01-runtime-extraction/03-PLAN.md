---
phase: 01-runtime-extraction
plan: 03
type: execute
wave: 2
depends_on: ["01"]
files_modified:
  - runtime/face/face_service.py
  - runtime/face/face.py
  - third_party/whisplay-driver/PROVENANCE.md
  - .planning/phases/01-runtime-extraction/01-03-SUMMARY.md
autonomous: true

requirements:
  - "EXTRACT-02 (part 1): face.py + face_service.py extract to runtime/face/; tcp/8080 face service preserved; WhisPlay driver provenance resolved"

must_haves:
  truths:
    - "runtime/face/face_service.py exists and serves the tcp/8080 face control surface"
    - "runtime/face/face.py exists and the WhisPlayBoard import is documented as a third-party dependency, with the driver path env-overridable via ARLOWE_WHISPLAY_DRIVER_PATH"
    - "third_party/whisplay-driver/PROVENANCE.md records driver source, license investigation, and a decision about vendoring vs image-build dependency (research Q2 / R3)"
  artifacts:
    - path: "runtime/face/face_service.py"
      provides: "tcp/8080 face HTTP service (face state setter, mouth lip-sync stream)"
      min_lines: 150
    - path: "runtime/face/face.py"
      provides: "WhisPlay rendering primitives"
      min_lines: 500
      contains: "WhisPlayBoard"
    - path: "third_party/whisplay-driver/PROVENANCE.md"
      provides: "WhisPlay vendor SDK provenance + license investigation + vendoring decision"
      min_lines: 30
  key_links:
    - from: "runtime/face/face.py"
      to: "WhisPlayBoard vendor driver"
      via: "imports WhisPlayBoard at module load"
      pattern: "from WhisPlay import|import WhisPlay"
---

<objective>
Extract `face_service.py` and `face.py` from `~/iol-monorepo/packages/whisplay/` into `runtime/face/`. Sanitize hardcoded `/home/focal55/...` paths. Resolve the WhisPlay vendor driver provenance (research Q2 / R3) — document source, license, and vendoring decision.

Purpose: Land the first half of EXTRACT-02 — the face service is the visual half of the smoke test (talking-blue / pink-flash / idle), and `face.py` is the largest source file in the phase (~667 LOC), so it is split out into its own plan to honor the atomic-PR cap.

The second half of EXTRACT-02 (sentiment_classifier.py + audio_sync.py + requirements.txt + README) lands in plan 03b. Splitting on driver-vs-helpers boundary keeps each PR reviewable.

Output: `runtime/face/face.py`, `runtime/face/face_service.py`, sanitized; `third_party/whisplay-driver/PROVENANCE.md` resolves R3.
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
  <name>Task 1: Copy face.py and face_service.py from Pi mirror; sanitize face.py driver loader</name>
  <files>
    runtime/face/face.py
    runtime/face/face_service.py
  </files>
  <action>
Assumes plan 01's `scripts/dev-pull-from-pi.sh --apply` has already populated `.dev-stash/arlowe-1/whisplay/`. If not, run it.

Copy verbatim from `.dev-stash/arlowe-1/whisplay/` to `runtime/face/`:
- `face_service.py` (~202 LOC)
- `face.py` (~667 LOC)

Then sanitize:

**`runtime/face/face.py` (L18 area)**:
The line is currently:
```python
sys.path.insert(0, '/home/focal55/Library/Whisplay/Driver')
from WhisPlay import WhisPlayBoard
```
Replace with:
```python
# WhisPlay vendor SDK lookup — see third_party/whisplay-driver/PROVENANCE.md
# At runtime, the driver is expected at /opt/arlowe/third_party/whisplay-driver/.
# For dev on arlowe-1 we honour an env override.
import os
_WHISPLAY_DRIVER_PATH = os.environ.get(
    "ARLOWE_WHISPLAY_DRIVER_PATH",
    "/opt/arlowe/third_party/whisplay-driver",
)
if _WHISPLAY_DRIVER_PATH not in sys.path:
    sys.path.insert(0, _WHISPLAY_DRIVER_PATH)
from WhisPlay import WhisPlayBoard
```

Strip any other `/home/focal55` paths in `face.py` if found.

**`runtime/face/face_service.py`**:
- Search for any HTML title or banner string referencing `arlowe-1` (research notes there is one). Replace with cosmetic-neutral `"Arlowe Face"`.
- Search for any `/home/focal55` paths and replace with `/var/lib/arlowe/...` equivalents.
- Search for any imports of `face` (without package prefix) and rewrite to `from face.face import ...` or `from .face import ...` depending on package style chosen (pick one and apply consistently across the file).

After edits, both files must still parse as valid Python.
  </action>
  <verify>
```bash
test -f runtime/face/face_service.py && \
  test -f runtime/face/face.py && \
  python3 -c "import ast; [ast.parse(open(f).read()) for f in ['runtime/face/face_service.py','runtime/face/face.py']]" && \
  ! grep -rn 'focal55\|iol-monorepo\|/home/focal55\|joe@focal55\|casa_ybarra\|arlowe-1' runtime/face/face.py runtime/face/face_service.py && \
  grep -q 'ARLOWE_WHISPLAY_DRIVER_PATH' runtime/face/face.py && \
  grep -q '/opt/arlowe/third_party/whisplay-driver' runtime/face/face.py && \
  echo OK
```
  </verify>
  <done>face.py and face_service.py extracted, sanitized, parsing cleanly. WhisPlay driver path env-overridable. Zero founder literals.</done>
</task>

<task type="auto">
  <name>Task 2: Resolve WhisPlay driver provenance and decision</name>
  <files>third_party/whisplay-driver/PROVENANCE.md</files>
  <action>
This task closes research Q2 / risk R3 — the WhisPlay vendor SDK provenance is currently unknown.

Investigation steps (run from a Mac terminal with arlowe-1 SSH):
```bash
ssh arlowe-1 'ls -la ~/Library/Whisplay/Driver/'
ssh arlowe-1 'cat ~/Library/Whisplay/Driver/install_wm8960_drive.sh 2>/dev/null | head -50'
ssh arlowe-1 'find ~/Library/Whisplay -name "*.md" -o -name "LICENSE*" -o -name "README*" 2>/dev/null'
ssh arlowe-1 'head -30 ~/Library/Whisplay/Driver/WhisPlay.py'
```
Plus a web search for "WhisPlay Pi 5 display board driver" / GitHub search for `WhisPlayBoard`.

Author `third_party/whisplay-driver/PROVENANCE.md` with these sections:
1. **Source** — vendor name, GitHub repo (if public), download URL, install script path on the Pi
2. **License** — captured license text or "license unknown — see decision below"
3. **Files needed** — concrete list (`WhisPlay.py`, any `.so` or kernel modules, the `install_wm8960_drive.sh` audio HAT installer)
4. **Vendoring decision** — pick one:
   - **(a) Vendor source under `third_party/whisplay-driver/`** if license permits
   - **(b) Image-build dependency** — driver is downloaded/installed via pi-gen at image build time, not committed
   - **(c) Block the smoke test on resolution** — record what's needed and from whom
5. **Phase 1 implication** — the smoke test on Joe's arlowe-1 already has the driver installed system-wide (via `~/Library/Whisplay/Driver/`); the smoke test passes regardless of the vendoring decision. The decision affects Phase 6 (image build), not Phase 1.
6. **Action items** — concrete TODOs (e.g., "email vendor for license", "PR to vendor a fork under MIT", "find an open-source replacement")

If license is unknown after investigation, recommend **(c) block** for image build but note Phase 1 smoke test is unaffected. Be honest in the doc.

Length target: 30-80 lines. Plain markdown, no emoji. Reference research file at `.planning/phases/01-runtime-extraction/01-RESEARCH.md` §R3.
  </action>
  <verify>
```bash
test -f third_party/whisplay-driver/PROVENANCE.md && \
  test "$(wc -l < third_party/whisplay-driver/PROVENANCE.md)" -ge 30 && \
  grep -qi 'license' third_party/whisplay-driver/PROVENANCE.md && \
  grep -qi 'decision' third_party/whisplay-driver/PROVENANCE.md && \
  grep -qi 'phase 1' third_party/whisplay-driver/PROVENANCE.md && \
  echo OK
```
  </verify>
  <done>PROVENANCE.md captures source, license investigation, vendoring decision (a/b/c), Phase 1 implication, and concrete next steps. Research R3 is no longer an unknown.</done>
</task>

</tasks>

<verification>
Phase-level checks for this plan:

```bash
# Files exist and parse
python3 -c "import ast; [ast.parse(open(f).read()) for f in ['runtime/face/face_service.py','runtime/face/face.py']]"

# No founder literals in the files this plan owns
! grep -rn 'focal55\|iol-monorepo\|/home/focal55\|joe@focal55\|casa_ybarra\|arlowe-1' runtime/face/face.py runtime/face/face_service.py

# WhisPlay driver loader is parameterized
grep -q 'ARLOWE_WHISPLAY_DRIVER_PATH' runtime/face/face.py

# PROVENANCE doc exists with the required sections
grep -qi 'license\|decision\|source' third_party/whisplay-driver/PROVENANCE.md
```

PR-size check: face.py (~667 LOC) is the bulk; face_service.py (~202 LOC) + ~30 LOC PROVENANCE.md = ~900 raw lines (mostly verbatim copies). Diff for review purposes is the ~30 lines of sanitization edits + ~50-line PROVENANCE.md ≈ 80 review-relevant lines, well under cap.
</verification>

<success_criteria>
- runtime/face/face.py and runtime/face/face_service.py exist, parse as valid Python
- Zero `focal55`, `iol-monorepo`, `casa_ybarra`, `arlowe-1` literals in those two files
- WhisPlay driver path is env-overridable (defaults to `/opt/arlowe/third_party/whisplay-driver`)
- `third_party/whisplay-driver/PROVENANCE.md` records source/license/vendoring decision (closes R3)
- Half of EXTRACT-02 complete; plan 03b finishes the rest
</success_criteria>

<output>
After completion, create `.planning/phases/01-runtime-extraction/01-03-SUMMARY.md` documenting:
- Files extracted and LOC
- Sanitization changes per file
- WhisPlay driver provenance findings + decision
- Open dependency on plan 03b for the rest of EXTRACT-02 (sentiment + audio_sync + requirements + README)
</output>
