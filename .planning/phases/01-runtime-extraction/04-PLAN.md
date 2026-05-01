---
phase: 01-runtime-extraction
plan: 04
type: execute
wave: 2
depends_on: ["01"]
files_modified:
  - runtime/stt/stt_server.py
  - runtime/stt/requirements.txt
  - runtime/stt/README.md
  - runtime/tts/tts_sync.py
  - runtime/tts/tts_config.json
  - runtime/tts/manifest.yml
  - runtime/tts/requirements.txt
  - runtime/tts/README.md
  - .planning/phases/01-runtime-extraction/01-04-SUMMARY.md
autonomous: true

requirements:
  - "EXTRACT-03: stt_server.py extracts to runtime/stt/; faster-whisper HTTP server on tcp/8082 preserved"
  - "EXTRACT-04: TTS invocation extracts to runtime/tts/ with a Piper voice asset manifest"

must_haves:
  truths:
    - "runtime/stt/stt_server.py exists and is the faster-whisper HTTP server on tcp/8082"
    - "runtime/tts/tts_sync.py exists with the cross-package contamination removed (no longer reads ~/iol-monorepo/packages/arlowe-dashboard/.env.local)"
    - "runtime/tts/manifest.yml pins Piper binary + voice file by SHA-256 (research §EXTRACT-04 schema)"
    - "ElevenLabs cloud TTS is disabled by default in tts_config.json (local-first principle)"
  artifacts:
    - path: "runtime/stt/stt_server.py"
      provides: "tcp/8082 faster-whisper HTTP STT"
      min_lines: 70
    - path: "runtime/stt/requirements.txt"
      provides: "Pinned PyPI deps (faster-whisper, etc.)"
      contains: "faster-whisper"
    - path: "runtime/stt/README.md"
      provides: "Documents tcp/8082 contract, model loading"
      min_lines: 20
    - path: "runtime/tts/tts_sync.py"
      provides: "TTS playback with face lip-sync"
      min_lines: 350
    - path: "runtime/tts/tts_config.json"
      provides: "TTS backend selection + voice config"
    - path: "runtime/tts/manifest.yml"
      provides: "Piper binary + voice asset pinning by SHA-256"
      contains: "sha256"
      min_lines: 20
    - path: "runtime/tts/requirements.txt"
      provides: "Pinned PyPI deps"
    - path: "runtime/tts/README.md"
      provides: "Documents Piper invocation, lip-sync stream, ElevenLabs opt-in"
      min_lines: 30
  key_links:
    - from: "runtime/tts/tts_sync.py"
      to: "runtime/face/audio_sync.py"
      via: "from face.audio_sync import ..."
      pattern: "from face\\.audio_sync|from face import audio_sync"
    - from: "runtime/tts/tts_sync.py"
      to: "config-driven ElevenLabs key"
      via: "reads from /etc/arlowe/config.yml or env, NOT from sibling-package .env.local"
      pattern: "ELEVENLABS_API_KEY"
---

<objective>
Extract STT (`stt_server.py`) and TTS (`tts_sync.py`, `tts_config.json`, plus a NEW Piper asset manifest) from the live whisplay tree into `runtime/stt/` and `runtime/tts/`. Critically: rewrite the TTS module's read of `~/iol-monorepo/packages/arlowe-dashboard/.env.local` (research R4 — this breaks the moment the dashboard moves) to come from `/etc/arlowe/config.yml` or env vars instead. Disable ElevenLabs by default (local-first).

Purpose: Land EXTRACT-03 + EXTRACT-04. STT and TTS are both on the smoke-test data path. The TTS / dashboard cross-coupling is the highest-risk hidden gotcha in Phase 1; this plan resolves it.

Output: `runtime/stt/` and `runtime/tts/` populated, the dashboard `.env.local` traversal removed, Piper manifest authored.
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
  <name>Task 1: Extract STT — copy stt_server.py, write requirements + README</name>
  <files>
    runtime/stt/stt_server.py
    runtime/stt/requirements.txt
    runtime/stt/README.md
  </files>
  <action>
Assumes plan 01's `dev-pull-from-pi.sh --apply` has populated `.dev-stash/arlowe-1/whisplay/`.

1. Copy `.dev-stash/arlowe-1/whisplay/stt_server.py` → `runtime/stt/stt_server.py` verbatim (~87 LOC).
2. Sanitize:
   - Search for any `/home/focal55` paths or `sys.path.insert` lines. Per research, stt_server.py is "self-contained" so this should be a clean file. Verify and fix anything found.
   - The model is `base.en`, downloaded by faster-whisper on first run. Confirm by reading the file. Add a comment at the top:
     ```python
     # faster-whisper downloads base.en on first run to ~/.cache/huggingface/.
     # In the image build, pre-populate /var/lib/arlowe/models/whisper/ to skip the download.
     ```
3. Author `runtime/stt/requirements.txt` with pinned deps. Seed from arlowe-1's voice venv:
   ```bash
   ssh arlowe-1 '~/venvs/voice/bin/pip freeze | grep -iE "faster-whisper|ctranslate2|tokenizers|huggingface-hub|onnxruntime"'
   ```
   Pin those with `==`. Plus `flask` if stt_server uses it.
4. Author `runtime/stt/README.md`:
   - Module purpose: "faster-whisper HTTP server on tcp/8082"
   - Endpoint: `POST /transcribe` (verify by reading the file) — body format, response format
   - Endpoint: `GET /health` (research notes returns `{"status":"ok","model":"base.en"}`)
   - Model: `base.en`, downloaded on first run
   - How to run on arlowe-1
   - Known: works today (verified by research §EXTRACT-03)
  </action>
  <verify>
```bash
test -f runtime/stt/stt_server.py && \
  python3 -c "import ast; ast.parse(open('runtime/stt/stt_server.py').read())" && \
  ! grep -n 'focal55\|iol-monorepo\|/home/focal55' runtime/stt/stt_server.py && \
  grep -q 'faster-whisper' runtime/stt/requirements.txt && \
  grep -q '==' runtime/stt/requirements.txt && \
  test "$(wc -l < runtime/stt/README.md)" -ge 20 && \
  grep -q '8082' runtime/stt/README.md && \
  echo OK
```
  </verify>
  <done>STT server file extracted, no founder literals, deps pinned, README documents the tcp/8082 contract.</done>
</task>

<task type="auto">
  <name>Task 2: Extract TTS — copy tts_sync.py + tts_config.json, sanitize the .env.local traversal</name>
  <files>
    runtime/tts/tts_sync.py
    runtime/tts/tts_config.json
  </files>
  <action>
1. Copy `.dev-stash/arlowe-1/whisplay/tts_sync.py` → `runtime/tts/tts_sync.py` verbatim (~429 LOC).
2. Copy `.dev-stash/arlowe-1/whisplay/tts_config.json` → `runtime/tts/tts_config.json` verbatim.

3. **Critical sanitization — the dashboard cross-coupling (research R4)**:

In `runtime/tts/tts_sync.py`, find the block near L70-81:
```python
env_path = Path.home() / "iol-monorepo/packages/arlowe-dashboard/.env.local"
if env_path.exists():
    with open(env_path) as f:
        for line in f:
            if line.startswith("ELEVENLABS_API_KEY="):
                ...
```

Replace with a config-overlay-aware loader:
```python
def _load_elevenlabs_key():
    """Load ElevenLabs API key from (in order):
       1. ELEVENLABS_API_KEY env var
       2. /etc/arlowe/config.yml (Phase 4 overlay; key under tts.elevenlabs.api_key)
       3. None (ElevenLabs disabled)
    NOTE: ElevenLabs is opt-in cloud TTS. Local Piper is the default.
    """
    import os
    key = os.environ.get("ELEVENLABS_API_KEY")
    if key:
        return key
    overlay = Path("/etc/arlowe/config.yml")
    if overlay.exists():
        try:
            import yaml  # PyYAML — add to requirements.txt
            with open(overlay) as f:
                cfg = yaml.safe_load(f) or {}
            return cfg.get("tts", {}).get("elevenlabs", {}).get("api_key")
        except Exception:
            return None
    return None

ELEVENLABS_API_KEY = _load_elevenlabs_key()
```

Update the rest of the file so the variable that previously held the key now references `ELEVENLABS_API_KEY` from this loader. Search for any other reads from `iol-monorepo/packages/arlowe-dashboard/.env.local` and remove them.

4. Other sanitization in `tts_sync.py`:
   - Strip `sys.path.insert(0, '/home/focal55/...')` lines if present.
   - Replace `Path.home() / "models/piper/piper"` with `Path("/opt/arlowe/runtime/tts/bin/piper")` (or whatever Piper invocation pattern the file uses). If the file shells out to `~/bin/speak`, redirect to `/opt/arlowe/runtime/cli/speak`.
   - Update `from audio_sync import ...` to `from face.audio_sync import ...` (canonical copy lives in plan 03).
   - Strip any `/home/focal55` / `~/iol-monorepo` paths.
   - HTTP target `localhost:8080/mouth` for lip-sync stream — leave as-is (single-host assumption).

5. **`runtime/tts/tts_config.json`** — set the default backend to `piper` (NOT `elevenlabs`) per local-first principle. The exact JSON shape depends on the file; if there's a `default_backend` or `enabled` field for ElevenLabs, set it to `false` / `piper`. Add a comment-style key if the JSON allows: `"_elevenlabs_note": "opt-in only; requires API key from /etc/arlowe/config.yml or ELEVENLABS_API_KEY env"`.

After edits, file must parse as valid Python (and JSON for tts_config.json).
  </action>
  <verify>
```bash
test -f runtime/tts/tts_sync.py && \
  python3 -c "import ast; ast.parse(open('runtime/tts/tts_sync.py').read())" && \
  ! grep -rn 'iol-monorepo\|/home/focal55\|focal55' runtime/tts/ && \
  ! grep -n '\.env\.local' runtime/tts/tts_sync.py && \
  grep -q '/etc/arlowe/config.yml' runtime/tts/tts_sync.py && \
  python3 -c "import json; json.load(open('runtime/tts/tts_config.json'))" && \
  echo OK
```
  </verify>
  <done>tts_sync.py no longer reads `~/iol-monorepo/packages/arlowe-dashboard/.env.local`. ElevenLabs key loads from env or config overlay. tts_config.json defaults to Piper. R4 closed.</done>
</task>

<task type="auto">
  <name>Task 3: Author Piper voice asset manifest (NEW artifact)</name>
  <files>runtime/tts/manifest.yml</files>
  <action>
This artifact does NOT exist today (research §EXTRACT-04). Author it fresh.

Steps:
1. SSH to arlowe-1 and capture pins:
   ```bash
   ssh arlowe-1 'sha256sum ~/models/piper/piper'
   ssh arlowe-1 'sha256sum ~/models/piper-voices/en_US-lessac-medium.onnx 2>/dev/null || sha256sum ~/models/en_US-lessac-medium.onnx 2>/dev/null'
   ssh arlowe-1 '~/models/piper/piper --version 2>&1 | head -3'
   ```
   (If voice path differs from research, use whatever path actually exists.)

2. Author `runtime/tts/manifest.yml`:
   ```yaml
   # runtime/tts/manifest.yml
   # Pinned Piper assets that the image build verifies before packaging.
   # Update procedure: bump in a follow-up PR with both URL and sha256 changed.

   piper:
     binary:
       version: "1.2.0"  # whatever ssh check returned
       url: "https://github.com/rhasspy/piper/releases/download/v1.2.0/piper_linux_aarch64.tar.gz"
       sha256: "<from ssh sha256sum>"
       install_to: "/opt/arlowe/runtime/tts/bin/piper"

     voices:
       - id: en_US-lessac-medium
         url: "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx"
         config_url: "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json"
         sha256: "<from ssh sha256sum>"
         install_to: "/opt/arlowe/models/piper-voices/en_US-lessac-medium.onnx"
         default: true
   ```

3. Use real values from the SSH probes — no placeholder hashes. If Piper version on arlowe-1 differs from upstream URL availability, use the closest matching upstream release version and document the discrepancy in a comment.
  </action>
  <verify>
```bash
test -f runtime/tts/manifest.yml && \
  python3 -c "import yaml; m = yaml.safe_load(open('runtime/tts/manifest.yml')); assert 'piper' in m and 'binary' in m['piper'] and 'voices' in m['piper'] and m['piper']['binary'].get('sha256'), 'manifest invalid'" && \
  grep -E '^\s*sha256:\s*[a-f0-9]{64}' runtime/tts/manifest.yml && \
  echo OK
```
  </verify>
  <done>manifest.yml validates as YAML, contains a Piper binary + at least one voice, both with real 64-char SHA-256 pins.</done>
</task>

<task type="auto">
  <name>Task 4: Author runtime/tts/requirements.txt + runtime/{stt,tts}/README.md</name>
  <files>
    runtime/tts/requirements.txt
    runtime/tts/README.md
  </files>
  <action>
**`runtime/tts/requirements.txt`**: Pin from arlowe-1's voice venv. Likely deps:
- `pyyaml` (NEW — added by Task 2 for the config overlay loader)
- `requests` (HTTP to face/mouth stream)
- (anything tts_sync.py imports)

If the file shells out to `piper` and `aplay` and `sox`, those are system binaries, not pip deps — note them in the README, not requirements.

**`runtime/tts/README.md`**:
- Module purpose: TTS playback with face lip-sync, supports Piper (local, default) and ElevenLabs (opt-in cloud)
- Backends:
  - **Piper (default)**: shells out to `piper` binary at `/opt/arlowe/runtime/tts/bin/piper`, voice file at `/opt/arlowe/models/piper-voices/en_US-lessac-medium.onnx`. See `manifest.yml` for asset pinning.
  - **ElevenLabs (opt-in)**: cloud HTTP. Disabled by default. Requires `ELEVENLABS_API_KEY` env var or `/etc/arlowe/config.yml` overlay key `tts.elevenlabs.api_key`.
- Lip-sync stream: TTS streams audio to `face_service` at `http://localhost:8080/mouth` for mouth-shape animation in sync with playback.
- System binary deps: `piper`, `aplay`, `sox` (installed via pi-gen at image build).
- How to run/test on arlowe-1
- Known limitations:
  - Cloud TTS path requires owner-provisioned key (Phase 4 + 7 wire this fully)
  - `PLAY_DEVICE` hardcoded to `plughw:2,0` (Phase 5 fix)
- Reference research R4 in a one-line note: "Cross-package coupling to arlowe-dashboard's .env.local was removed in plan 04."

30-80 lines.
  </action>
  <verify>
```bash
test -f runtime/tts/requirements.txt && \
  grep -q 'pyyaml\|PyYAML' runtime/tts/requirements.txt && \
  test -f runtime/tts/README.md && \
  test "$(wc -l < runtime/tts/README.md)" -ge 30 && \
  grep -qi 'piper' runtime/tts/README.md && \
  grep -qi 'elevenlabs' runtime/tts/README.md && \
  grep -q '8080/mouth\|/mouth' runtime/tts/README.md && \
  echo OK
```
  </verify>
  <done>requirements.txt pins TTS deps including pyyaml; README documents backends, lip-sync, system bins, limitations.</done>
</task>

</tasks>

<verification>
Phase-level checks for this plan:

```bash
# Files exist and parse
python3 -c "import ast; [ast.parse(open(f).read()) for f in ['runtime/stt/stt_server.py','runtime/tts/tts_sync.py']]"
python3 -c "import json; json.load(open('runtime/tts/tts_config.json'))"
python3 -c "import yaml; yaml.safe_load(open('runtime/tts/manifest.yml'))"

# No founder literals or cross-package traversal
! grep -rn 'focal55\|/home/focal55\|iol-monorepo\|\.env\.local\|joe@focal55' runtime/stt/ runtime/tts/

# ElevenLabs is loaded from config, not sibling package
grep -q '/etc/arlowe/config.yml' runtime/tts/tts_sync.py
grep -q 'ELEVENLABS_API_KEY' runtime/tts/tts_sync.py

# Piper manifest has real SHA-256s
grep -E '^\s*sha256:\s*[a-f0-9]{64}' runtime/tts/manifest.yml | wc -l  # expect >= 2
```

PR-size: stt_server.py (~87 LOC) + tts_sync.py (~429 LOC) + JSON + manifest + 2 READMEs + 2 requirements ≈ 700 raw lines. Sanitization edits are surgical (~30 net new lines from the ElevenLabs loader). Diff for review is the new code (~100 lines) plus file copies. If hard-cap-conscious, this can be split into 04a (STT) and 04b (TTS); STT is small enough to be a quick PR on its own.
</verification>

<success_criteria>
- runtime/stt/ + runtime/tts/ extracted, sanitized, parse cleanly
- Zero founder literals, zero `iol-monorepo`, zero `.env.local` traversal
- ElevenLabs key loader reads from env or `/etc/arlowe/config.yml` only
- Piper manifest exists with real SHA-256 pins
- ElevenLabs disabled by default in tts_config.json
- README docs cover endpoints, backends, lip-sync, limitations
</success_criteria>

<output>
After completion, create `.planning/phases/01-runtime-extraction/01-04-SUMMARY.md` documenting:
- STT extraction (LOC, deps)
- TTS extraction with the cross-package coupling fix (research R4) — record the specific edit
- Piper manifest pins (SHA-256s)
- Open dependencies on plan 03 (face.audio_sync) for tts_sync.py imports
</output>
