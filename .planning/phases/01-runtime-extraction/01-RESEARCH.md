# Phase 1: Runtime Extraction — Research

**Researched:** 2026-05-01
**Domain:** Source-tree carve-out / firmware extraction from a contaminated monorepo
**Confidence:** HIGH for source mapping and topology; MEDIUM for sanitization scope (dashboard contamination is worse than docs imply); MEDIUM for the smoke-test pre-conditions (a known production bug already breaks the local-LLM path).

---

## Summary

Phase 1 is mechanical extraction of a working voice pipeline from `iol-monorepo` plus the founder's home directory on `arlowe-1.local`, into this repo's `runtime/` tree. The Python whisplay package (~4,600 LOC across 15 files) is **clean enough** to copy with sanitization. The Next.js dashboard (~9,600 LOC across 66 files) is **substantially contaminated** with founder/`openclaw`/IOL infrastructure — closer to a 50/50 keep/delete than a copy job.

Three pre-existing facts on Arlowe-1 that the planner needs to know up front:

1. **`qwen-openai.service` is currently broken** in a restart loop. It points at `/home/focal55/models/Qwen2.5-1.5B-Instruct/openai_wrapper.py`, which doesn't exist (the 1.5B model lives at `~/llm-models/`, and there's no `openai_wrapper.py` anywhere on the device). The roadmap requirement EXTRACT-05 mentions `openai_wrapper.py` as if it exists — it doesn't on this dev unit. Either the file was deleted, lives elsewhere, or the requirement needs to be re-scoped to "build/restore the wrapper as part of extraction." This is the **single biggest blocker** to the Phase 1 success criterion of an end-to-end smoke test, because `iol_router.py` calls the local model via port 8001 (the broken wrapper) — local LLM routing currently doesn't work.
2. **`iol_router.py` is misnamed.** The "IOL" label is historical residue. The current implementation routes between local Qwen (8001) and `claude` CLI subprocess. There's **no founder-only IOL infrastructure call** in the live file (the OpenClaw gateway path was retired during the Claude Code migration, per the docstring). It is, however, still tightly coupled to the founder's `~/.claude/.credentials.json` and `~/.claude/workspace/usage-stats.json`. The recommendation below is **extract-clean with a generic LLM-router abstraction**, not stub.
3. **`arlowe-scheduled-summary.service` is a placeholder.** Its `claude -p` invocation is documented in the script as "currently does nothing meaningful because the Arlowe memory system is mid-rebuild." It writes to `~/.local/state/arlowe/summaries/` and does no work. Recommendation: **strip from the firmware**; record the design intent (4×/day signed cron hook) as a placeholder in `docs/architecture/` if Joe wants to revive it post-v1, but it has no business shipping to customer units.

**Primary recommendation:** Plan Phase 1 as four loosely-coupled streams that converge on a smoke test. Stream A (whisplay Python copy) is mostly mechanical and unblocks the smoke test. Stream B (dashboard purge) is the highest-effort and highest-uncertainty work — treat it as a separate set of tasks, not "copy the directory." Stream C (third-party vendoring) is small but blocks the image build. Stream D (CLI helpers + wake-word + ADRs) is small and parallelizable. Save the smoke test for last and run it on Arlowe-1 with the *new* `runtime/` tree symlinked into place — do **not** disturb the live monorepo paths until the new tree boots.

---

## Source-of-Truth Inventory

These files exist on `arlowe-1.local` (verified 2026-05-01 via SSH). The Mac copy of `iol-monorepo` does **not** contain `packages/whisplay/` — only the dashboard. Extraction work needs to either pull from the Pi over SSH or push the Pi's tree to the Mac first. Recommend the planner scope a `scripts/dev-pull-from-pi.sh` task early so subsequent tasks have a local copy to operate on.

### EXTRACT-01: `runtime/voice/`

| Source | LOC | Confidence |
|---|---|---|
| `~/iol-monorepo/packages/whisplay/voice_client.py` | 540 | HIGH |
| `~/iol-monorepo/packages/whisplay/tts_sync.py` (used by voice_client) | 429 | HIGH |
| `~/iol-monorepo/packages/whisplay/audio_sync.py` (used by tts_sync) | 243 | HIGH |
| `~/iol-monorepo/packages/whisplay/voice_expression_controller.py` | 269 | HIGH |
| `~/iol-monorepo/packages/whisplay/voice_expression_config.json` | — | HIGH |
| `~/iol-monorepo/packages/whisplay/tts_config.json` | — | HIGH |
| `~/iol-monorepo/packages/whisplay/voice_log.py` (log retention helper) | 46 | HIGH |
| `~/iol-monorepo/packages/whisplay/wake_test.py` (debug utility) | 50 | HIGH |

**Imports voice_client.py makes (lines 30-39):**
```python
from iol_router import route as iol_route, reset_local        # → runtime/llm/
from rules_engine import get_engine                           # → runtime/voice/ (stub, see below)
from voice_expression_controller import get_controller        # → runtime/voice/
from action_executor import ActionExecutor                    # → runtime/voice/ (stub)
from tts_sync import TTSWithSync, TTSBackend                  # → runtime/tts/
import openwakeword                                           # PyPI
from openwakeword.model import Model as WakeWordModel         # PyPI
import pyaudio                                                # PyPI
from sentiment_classifier import Sentiment                    # → runtime/face/
```

**Hardcoded literals to parameterize (`voice_client.py`):**
- L18: `sys.path.insert(0, '/home/focal55/venvs/voice/lib/python3.13/site-packages')` — venv hack, must die. Fix: use a proper `pyproject.toml` + `venv` at build time.
- L40-42: `PIPER_PATH = Path.home() / "models/piper/piper"`, `PIPER_MODEL = ...`, `VERIFIER_MODEL = Path.home() / "wake_word/hey_arlowe_verifier.pkl"` — reroute under `/opt/arlowe/`.
- L43-44: `RECORD_DEVICE = "plughw:2,0"`, `PLAY_DEVICE = "plughw:2,0"` — must come from config (audio auto-detect is Phase 2+ scope; for Phase 1, accept config injection).
- L51: `FAN_PWM = "/sys/class/hwmon/hwmon2/pwm1"` — Pi 5 hwmon path is stable; OK to keep but document as Pi-5-specific.
- L52: `LOG_DIR = Path(__file__).resolve().parent / "logs"` — co-located logs in source tree. Fix: redirect to `/var/lib/arlowe/logs/`.
- L138-145 (`fan_off`/`fan_on`): `subprocess.run(f"echo 0 | sudo tee {FAN_PWM}", shell=True, ...)` — runs `sudo` from a service. Works today because `arlowe-voice.service` is a `--user` unit owned by `focal55`; will break when the service runs as a dedicated `arlowe` user without passwordless sudo on the fan PWM. Fix: install a polkit rule or use `chgrp` + `chmod g+w` on the hwmon PWM file at image-build time.

**Cross-component network coupling (all hardcoded `localhost`):**
- `http://localhost:8080` (face) — L48
- `http://localhost:3000` (dashboard) — L51 (`DASHBOARD_URL`)
- `http://localhost:8082/transcribe` (STT) — L319

These are fine for now (everything runs on the same Pi). For Phase 1 we keep the hardcodes; the config layer (Phase 4 in roadmap) replaces them.

### EXTRACT-02: `runtime/face/`

| Source | LOC | Confidence |
|---|---|---|
| `~/iol-monorepo/packages/whisplay/face_service.py` | 202 | HIGH |
| `~/iol-monorepo/packages/whisplay/face.py` | 667 | HIGH |
| `~/iol-monorepo/packages/whisplay/sentiment_classifier.py` | 292 | HIGH |
| `~/iol-monorepo/packages/whisplay/audio_sync.py` (shared with voice — single copy, not duplicated) | 243 | HIGH |

**Critical external dependency** (`face.py:18`):
```python
sys.path.insert(0, '/home/focal55/Library/Whisplay/Driver')
from WhisPlay import WhisPlayBoard
```

The Whisplay board driver lives at `~/Library/Whisplay/Driver/WhisPlay.py` on the Pi (with the WM8960 audio HAT install scripts alongside). This is a **third-party vendor SDK** that's not currently on GitHub or in any package manager Joe pointed at — it appears to be vendor-shipped code that came with the display. The planner needs a task to: (a) confirm the Whisplay driver's source/license, (b) decide whether to vendor it under `third_party/whisplay/` or treat it as an image-build dependency. Until then, **extraction blocks on this driver**: the face won't render without it.

**Sentiment classifier coupling:**
- `sentiment_classifier.py:13` — `QWEN_URL = "http://localhost:8001/v1/chat/completions"` — same broken endpoint as `iol_router`.
- `sentiment_classifier.py:16` — `CONFIG_PATH = Path.home() / ".claude/workspace/whisplay-config.json"` — reads from the founder's Claude Code workspace. **Must move** to `/etc/arlowe/config.yml` overlay.
- Has a heuristic fallback (`classify_sentiment_heuristic`) so the face service degrades gracefully when the NPU is unreachable. Confirmed — Phase 1 doesn't need to fix the broken NPU sentiment path to pass the smoke test.

### EXTRACT-03: `runtime/stt/`

| Source | LOC | Confidence |
|---|---|---|
| `~/iol-monorepo/packages/whisplay/stt_server.py` | 87 | HIGH |

Self-contained. `faster-whisper` PyPI dep, model `base.en` downloaded on first run. Listens on `localhost:8082`. **Currently working** on Arlowe-1 (verified `/health` returns `{"status":"ok","model":"base.en"}`). Lowest-risk extraction.

Dep: `faster-whisper` Python package. Note the `arlowe-1` systemd unit uses `/home/focal55/venvs/voice/bin/python` — there's a separate Python venv at `~/venvs/voice/` that holds STT + voice-client deps. Phase 1 task should capture that venv's `pip freeze` as the seed for `runtime/stt/requirements.txt` (and `runtime/voice/requirements.txt`).

### EXTRACT-04: `runtime/tts/`

| Source | LOC | Confidence |
|---|---|---|
| `~/iol-monorepo/packages/whisplay/tts_sync.py` | 429 | HIGH |
| `~/bin/speak` (wrapper script) | ~30 | HIGH |
| Piper voice manifest (NEW — must be authored) | — | — |

**Important:** Roadmap text says "TTS invocation extracts to `runtime/tts/` with a Piper voice asset manifest." The asset manifest does not exist today. Phase 1 task creates it. Recommended schema:
```yaml
# runtime/tts/manifest.yml
piper:
  binary:
    sha256: <pin from current ~/models/piper/piper>
    url: https://github.com/rhasspy/piper/releases/...
  voices:
    - id: en_US-lessac-medium
      sha256: <pin>
      url: https://huggingface.co/rhasspy/piper-voices/...
```

**`tts_sync.py` cross-package contamination (lines 70-81):**
```python
env_path = Path.home() / "iol-monorepo/packages/arlowe-dashboard/.env.local"
if env_path.exists():
    with open(env_path) as f:
        for line in f:
            if line.startswith("ELEVENLABS_API_KEY="):
```

The TTS module reads the **dashboard's** `.env.local` to get the ElevenLabs API key. This is a path-coupled dependency that will break the moment we move the dashboard. Fix during extraction: replace with reads from `/etc/arlowe/config.yml` (or env var) — the planner needs an explicit task for this, it's not a one-line sanitization.

**ElevenLabs is a cloud TTS path.** v1 scope says "local-first" — recommend the planner mark ElevenLabs as a future opt-in feature and ship Phase 1 with Piper-only. Keep the code path but disable ElevenLabs by default in `tts_config.json`.

### EXTRACT-05: `runtime/llm/`

| Source | LOC | Confidence |
|---|---|---|
| `~/models/Qwen2.5-7B-Instruct/run_api.sh` | 12 | HIGH |
| `~/models/Qwen2.5-7B-Instruct/qwen2.5_tokenizer_uid.py` | ~400 | HIGH |
| `~/iol-monorepo/packages/whisplay/iol_router.py` (rename → `runtime/llm/router.py`) | 452 | HIGH |
| `openai_wrapper.py` | **MISSING** | — |

**Critical finding: `openai_wrapper.py` does not exist on the device.** The roadmap requirement EXTRACT-05 lists it as a target for extraction, but `find / -name openai_wrapper.py 2>/dev/null` returns no hits. The systemd unit `qwen-openai.service` references `/home/focal55/models/Qwen2.5-1.5B-Instruct/openai_wrapper.py` — that directory is `~/llm-models/Qwen2.5-1.5B-Instruct/` (note `llm-models` vs `models`), and even there, there's no `openai_wrapper.py`. The 1.5B model directory has `gradio_demo.py` and the Axera-supplied `main_*` binaries, no OpenAI shim.

**Implication:** The local LLM path (port 8001) has been broken for some unknown duration. `voice_client.py` → `iol_router.route` → `query_local` → `http://localhost:8001/v1/chat/completions` → **fails** → falls through to cloud `claude -p` subprocess. **The end-to-end voice pipeline today is effectively cloud-only.**

Phase 1 has three options (planner picks; ADR'd):

1. **Restore the wrapper.** Find it in git history (`git -C ~/iol-monorepo log --all --diff-filter=D -- '**/openai_wrapper.py'`), or recover from `~/whisplay.archive-2026-04-05/` if present, or write a fresh ~50-line OpenAI-compat shim that translates `/v1/chat/completions` → ax-llm's native `/v1/chat/completions` on port 8000 (which already exists — see below).
2. **Eliminate the wrapper.** Point `iol_router` directly at port 8000 (ax-llm's native API). Verified live: `curl http://localhost:8000/v1/models` returns `{"status":"ok"}`. The wrapper exists as a translation layer but ax-llm 2024+ supports the OpenAI surface natively. This is the simpler fix and removes a moving part.
3. **Skip in Phase 1.** Smoke test passes with cloud-only routing; restore local in Phase 3. Documented as a known gap.

Recommend **option 2** (eliminate the wrapper, point router at 8000 directly). Lowest LOC delta, highest reliability. Verify with one test run on Arlowe-1 before committing to a plan.

**`run_api.sh` system prompt sanitization (line 13):**
```bash
--system_prompt "You are Arlowe, a friendly AI assistant with a calm, curious personality. Soft neon blue vibe. Be brief, conversational, and helpful. You live on a Raspberry Pi 5 with an Axera NPU. Your human is Joe."
```

`Your human is Joe` must die before customer ship. Replace with `Your human is the device owner.` or pull from owner-pairing config.

### EXTRACT-06: `runtime/dashboard/`

| Source | LOC | Confidence |
|---|---|---|
| `~/iol-monorepo/packages/arlowe-dashboard/` (Mac copy at `/Users/joeybarrajr/projects/iol-monorepo/packages/arlowe-dashboard/`) | ~9,600 | HIGH |

**The dashboard is 50%+ founder/openclaw/IOL contaminated. It is not a copy job.**

Routes that are KEEP (sanitize and ship):
- `app/api/health/route.ts` — system stats. References `axcl-smi` binary (kept) and standard Linux `/proc` paths (kept).
- `app/api/voice/route.ts` — `systemctl --user is-active arlowe-voice` toggle. Sanitize: `--user` → system, `arlowe-voice` path stays. Probably the most useful route for product units.
- `app/api/connectivity/*` — Wi-Fi management via NetworkManager. Need careful audit (does it leak founder SSID?), but the surface is product-relevant.
- `app/api/npu/*` — NPU benchmark/chat/status. Generally useful.
- `app/api/config/route.ts` — **partially**. Currently reads `/home/focal55/.openclaw/workspace`. Rewrite to read `/etc/arlowe/config.yml`. Keep the surface (config get/set), kill the implementation.
- `app/page.tsx` (homepage) — UI is generic ("system stats + voice toggle"). Keep.
- `app/components/StatusCard.tsx`, `RetroActivityMonitor.tsx`, etc. — generic UI components. Keep.

Routes that are DELETE (founder workforce tooling, harmful in product):
- `app/api/costs/route.ts` — reads `/home/focal55/.openclaw/agents/main/sessions` (Claude Code cost tracking). **DELETE.**
- `app/api/cron/route.ts` + `app/api/cron/run/route.ts` — `openclaw cron` invocations, `/home/focal55/.openclaw/cron/jobs.json`. **DELETE.**
- `app/api/sub-agents/*` (3 routes) — agentic-workforce sub-agent introspection. **DELETE.**
- `app/api/tasks/active/route.ts` — `~/.openclaw/agents/main/sessions/sessions.json`. **DELETE.**
- `app/api/usage/route.ts` — `/home/focal55/.openclaw/agents/main/sessions`. **DELETE.**
- `app/api/stats/route.ts` — `/home/focal55/.openclaw/workspace/usage-stats.json`. **DELETE.**
- `app/api/logs/route.ts` — references `/home/focal55/whisplay/logs`, `/home/focal55/.openclaw/logs`, `/home/focal55/.openclaw/cron/runs`, and a `journalctl` filter that includes `openclaw-gateway`. **REWRITE** (keep the journalctl path, drop the openclaw refs).
- `app/api/gateway/restart/route.ts` — restarts `openclaw-gateway`. **DELETE.**
- `app/api/iol/*` — IOL control plane integration. **DELETE.**
- `app/api/playwright-reports/*` — test infra. Maybe keep for dev, definitely don't ship.
- `app/api/middleware/*` — audit before keep/delete (founder API auth shape).

Pages that are DELETE (founder workforce UI):
- `app/iol/page.tsx` — IOL control plane UI, references `https://github.com/focal55/iol-monorepo/issues/...`. **DELETE.**
- `app/sub-agents/page.tsx` — sub-agent UI, same GitHub link. **DELETE.**
- `app/cron/page.tsx`, `app/costs/page.tsx`, `app/sub-agents/`, `app/subagent-types/`, `app/pathway/`, `app/testing/` — workforce/dev UI. **AUDIT EACH** but bias toward delete.

Pages that are KEEP (genuinely product-useful):
- `app/page.tsx` — homepage with system health + voice toggle. KEEP.
- `app/connectivity/page.tsx` — Wi-Fi management. KEEP.
- `app/config/page.tsx` — config UI. KEEP (rewrite backend).
- `app/npu/page.tsx` — NPU diagnostics. KEEP.
- `app/stats/page.tsx`, `app/logs/page.tsx` — KEEP after backend rewrite.

**Recommendation:** Plan two distinct dashboard tasks instead of one EXTRACT-06:
1. **EXTRACT-06a: Dashboard route audit + delete pass.** Categorize every route + page (keep/rewrite/delete) in a `dashboard-extraction-audit.md`. Delete the obvious-deletes. Net: removes ~40% of LOC.
2. **EXTRACT-06b: Dashboard rewrite pass.** Rewrite the keep-after-backend-rewrite routes to read from `/etc/arlowe/config.yml` and product paths instead of `~/.openclaw/`.

This is **the largest single piece of Phase 1 work** by LOC and uncertainty. Plan accordingly.

**Founder GitHub URLs in dashboard code:**
- `app/sub-agents/page.tsx:155` — `https://github.com/focal55/iol-monorepo/issues/${agent.parsed.taskId}`
- `app/iol/page.tsx:412` — `https://github.com/focal55/iol-monorepo/issues/${agent.issue}`

Both are in pages tagged for delete. Confirm no other GitHub-link leaks remain after the delete pass.

### EXTRACT-07: `runtime/wake-word/`

| Source | LOC | Confidence |
|---|---|---|
| `~/wake_word/auto_collect.py` | 91 | HIGH |
| `~/wake_word/collect_samples.py` | 186 | HIGH |
| `~/wake_word/quick_test.py` | 79 | HIGH |
| `~/wake_word/test_verifier.py` | 114 | HIGH |
| `~/wake_word/train_verifier.py` | 75 | HIGH |
| `~/wake_word/README.md` | — | HIGH |
| `~/wake_word/hey_arlowe_verifier.pkl` (founder voice — DO NOT SHIP) | 50 KB | HIGH |
| `~/wake_word/positive/*.wav` (50 founder samples — DO NOT SHIP) | — | HIGH |
| `~/wake_word/negative/*.wav` (30 noise samples — DO NOT SHIP) | — | HIGH |

The pipeline is well-encapsulated and independent. The training scripts use the `hey_jarvis` openWakeWord base model and train a **speaker-specific verifier** on top. Easy to extract.

**Critical sanitization:**
- The `.pkl` and `.wav` files are **founder's voice fingerprint**. They cannot ship. Phase 1 extraction copies the *scripts* but not the trained model or training data.
- Roadmap requirement EXTRACT-07 says "generic-model swap path documented." Concretely: Phase 1 task documents in `runtime/wake-word/README.md` (a) how to bypass the verifier (use bare `hey_jarvis` base model with a higher base threshold), and (b) how to train a generic verifier from a multi-speaker corpus when one is available.
- For the Phase 1 smoke test, the verifier `.pkl` stays on Arlowe-1 in its current location — the `runtime/voice/` config points at `/var/lib/arlowe/wake-word/verifier.pkl` (or wherever), and the smoke-test setup symlinks the founder's `.pkl` into place. **The repo never contains the founder voice file.**

**Hardcoded venv path in `train_verifier.py`:**
```python
sys.path.insert(0, '/home/focal55/venvs/voice/lib/python3.13/site-packages')
```
Same pattern as voice_client. Same fix.

### EXTRACT-08: `runtime/cli/`

| Source | LOC | Sanitization Required |
|---|---|---|
| `~/bin/face` | 27 | LOW — only literal is `localhost:8080` (keep). Clean. |
| `~/bin/speak` | 41 | MEDIUM — hardcoded `~/models/piper`, `plughw:2,0`, `localhost:8080`. |
| `~/bin/stt` | 14 | LOW — `plughw:2,0`, `localhost:8082`. Clean. |
| `~/bin/record` | 7 | LOW — `plughw:2,0`. Clean. |
| `~/bin/boot-check` | 60 | **HIGH** — references `openclaw-gateway` and port 18789. Strip both lines. Hardcoded `plughw:2,0`. |
| `~/bin/purge-logs` | 25 | MEDIUM — uses `$HOME/whisplay/logs`. Reroute to `/var/lib/arlowe/logs/`. |
| `~/bin/run-logrotate` | 3 | LOW — references `~/.config/logrotate/arlowe.conf` (need to extract that conf too). |
| `~/bin/wake-train` | 23 | LOW — `cd ~/wake_word`. Reroute. |
| `~/bin/wifi-watchdog` | 15 | **CRITICAL** — `HOME_SSID="casa_ybarra_chelsea"` (founder's home SSID). **DO NOT EXTRACT AS-IS.** Either delete entirely (the proposed `connectivity/` UI replaces it) or rewrite as a generic NetworkManager fallback that takes SSID from config. Recommend **delete**; the dashboard's connectivity routes cover this. |

The CLI tree is the easiest to sanitize after the `wifi-watchdog` decision. None depend on each other except `wake-train` → `~/wake_word/`.

Also worth noting: `~/bin/iol-sync`, `~/bin/usage-stats`, `~/bin/stats` are present in the bin dir and explicitly listed in `04-scope.md` as **personal/out-of-scope**. Phase 1 ignores them.

### EXTRACT-09: `third_party/ax-llm/`

**Verified state on Arlowe-1:**
- Local clone at `~/ax-llm/`.
- Origin: `https://github.com/AXERA-TECH/ax-llm.git`
- Branch: `axcl-context`
- HEAD: `df75c34ca2ed8fe55e7576204e4da9c5b5f88ad8` ("修复内存泄漏" — "fix memory leak", 2024)
- Working tree clean.
- License: BSD-3-Clause (verified via WebFetch of the GitHub repo).

**Branch consideration:** The upstream repo's primary branch has migrated to `axllm` (unified single-binary mode) according to current GitHub README. Arlowe-1 is on the older `axcl-context` (split build for AXCL PCIe specifically). The Pi runs the AX8850 over PCIe (M.2 form factor — that's the AXCL path), so `axcl-context` is correct for now. **Don't migrate to `axllm` in Phase 1** — that's a future capability decision and risks breaking the working build.

**Submodule strategy:**
```bash
git submodule add -b axcl-context https://github.com/AXERA-TECH/ax-llm.git third_party/ax-llm
cd third_party/ax-llm && git checkout df75c34c
cd ../.. && git add .gitmodules third_party/ax-llm && git commit
```

Pin policy: pin to commit hash, not branch tip. Document in `third_party/README.md` how to bump (test build_aarch64.sh on a Pi 5 dev unit before merging the bump).

**Build artifacts** that the firmware needs (from `~/ax-llm/build_aarch64.sh`):
- `main_api_axcl_aarch64` — the LLM HTTP server binary that `run_api.sh` invokes.

Phase 1 doesn't have to build it (the binary already exists on Arlowe-1). Phase 1 just vendors the source. Building it from source is Phase 11 (image build) scope.

### EXTRACT-10: `axcl_host_aarch64_V3.10.2.deb`

**Verified state:**
- File: `/home/focal55/axcl/axcl_host_aarch64_V3.10.2.deb`
- SHA-256: `1d6bd551644df30e39e3adbe3f32ab9b1d4cdc9c9d12752c27ebc99b35725b94`
- Size: needs `ls -la` measurement during extraction.

**Vendoring options:**
1. Commit the `.deb` directly under `third_party/axcl/` (uses Git LFS — file is binary, possibly tens of MB).
2. Don't commit — ship a `third_party/axcl/manifest.yml` with URL + SHA, fetch at image build time. Requires hosting the `.deb` somewhere (GitHub release asset, S3, etc.).
3. Hybrid: keep a `third_party/axcl/INSTALL.md` that says "place V3.10.2 here, sha256 must match" and fetch via the image-build script.

Recommend **option 2** with a private S3 or GitHub release. The `.deb` is from Axera (the chip vendor) — re-hosting may be allowed (BSD-licensed deps elsewhere) but **needs a Phase 1 task to confirm distribution rights**. If unclear, fall back to option 3 (no redistribution; user supplies file).

Either way, the Phase 1 success criterion is "hash verified at image build" — that's a `scripts/verify-axcl-deb.sh` task with a hash constant, runnable before image build proceeds.

### EXTRACT-11: `iol_router.py` ADR

**Recommendation: extract-clean (rename to `runtime/llm/router.py`).**

**Reasoning:** The "IOL" name is residue. The current code (verified by reading 452 lines) does **not** call any founder-only IOL infrastructure. The historical OpenClaw-gateway path on port 18789 was retired during the Claude Code migration (line 12-15 of the docstring confirms). Today's behavior:

- Local path: HTTP POST to `localhost:8001` (Qwen wrapper — currently broken).
- Cloud path: `subprocess.run(["/home/focal55/.local/bin/claude", "-p", ...])` — invokes Claude Code CLI with `--disallowed-tools` to neuter agentic behavior.

Concrete sanitization steps the planner needs to schedule:
1. Rename `iol_router.py` → `runtime/llm/router.py`. Update imports in `voice_client.py`.
2. L36-37: `USAGE_STATS_PATH = Path.home() / ".claude/workspace/usage-stats.json"` → `Path("/var/lib/arlowe/usage-stats.json")`.
3. L48: `CLAUDE_BIN = "/home/focal55/.local/bin/claude"` → read from config; default to `/usr/bin/claude` or fail-fast if missing.
4. L40-41: `QWEN_URL = "http://localhost:8001/..."` — depends on EXTRACT-05 ADR. If we eliminate the wrapper (recommended option 2 above), point at `localhost:8000` (ax-llm native).
5. L50: `VOICE_MODEL = os.environ.get("ARLOWE_VOICE_MODEL", "claude-haiku-4-5")` — env-var defaulting is fine; document in config schema.
6. L52-62: voice system prompt is generic enough to keep as-is.
7. L74-79: `DISALLOWED_TOOLS` list mentions `RemoteTrigger`, `CronCreate`, etc. — these are Claude Code workforce tool names. Keep the disallow list (better safe than sorry) but document in a comment that the list is a defense-in-depth measure, not load-bearing.

**ADR file:** `docs/architecture/0001-iol-router-extraction.md`. Records the extract-clean decision with a brief history note ("the IOL name is residue from a pre-Claude-Code architecture; the current router has no IOL infrastructure dependency").

**One subtle point:** The cloud path currently uses **Joe's Claude Code OAuth credentials** (`~/.claude/.credentials.json`) implicitly because that's how Claude Code CLI auths. Customer units cannot ship Joe's credentials. The cloud path requires a separate identity story (which is Phase 7 scope per the roadmap — first-boot pairing + customer-bound API key). For Phase 1, the cloud path **will not work on a sanitized customer-equivalent unit**, but it will work on Joe's Pi for the smoke test. Document this limitation explicitly in the ADR; it's a Phase 7 dependency, not a Phase 1 blocker.

### EXTRACT-12: `arlowe-scheduled-summary.service` ADR

**Recommendation: strip from the firmware.**

**Reasoning:** Read the actual files:

`~/.config/systemd/user/arlowe-scheduled-summary.service`:
> Description=Arlowe scheduled summary (Claude Code equivalent of the old openclaw hourly-progress cron)
> Documentation=https://github.com/focal55/iol-monorepo/blob/main/deploy/systemd/README.md

`~/iol-monorepo/deploy/scripts/arlowe-scheduled-summary.sh` (verified ~30 lines):
- Documentation header literally says: *"Currently does nothing meaningful because the Arlowe memory system is mid-rebuild."*
- The `claude -p` invocation prompt: *"This scheduled run is a placeholder — return a single short line acknowledging that scheduled work will resume once the memory layout is rewired."*
- Writes log files to `/home/focal55/.local/state/arlowe/summaries/`.

This is a placeholder that the founder set up to keep the scheduling infra warm; it produces no product value. Shipping it to customer units would result in customer Pis making `claude -p` calls every 4 hours producing throwaway log lines. That's bad on principle (cost), bad in practice (depends on Joe's credentials), and trivially fixable (delete it).

**ADR file:** `docs/architecture/0002-arlowe-scheduled-summary-stripped.md`. Records the decision and notes that if Joe ever wants a periodic on-device task (e.g., "summarize today's conversations and surface to dashboard"), it should be designed fresh in a future phase as part of the local memory work, not retrofitted onto this placeholder.

---

## Cross-Component Coupling Map

```
voice_client.py ──imports──> iol_router.py        (LLM routing)
                ──imports──> rules_engine.py      (stub, returns [])
                ──imports──> action_executor.py   (stub, no-op)
                ──imports──> voice_expression_controller.py
                ──imports──> tts_sync.py          (TTS + sync)
                ──imports──> sentiment_classifier.py
                ──imports──> openwakeword (PyPI)
                ──HTTP────> face_service.py at :8080
                ──HTTP────> stt_server.py at :8082
                ──HTTP────> dashboard at :3000 (rules engine fetches; stub doesn't actually use)
                ──HTTP────> qwen-openai at :8001 (BROKEN)

face_service.py ──imports──> face.py
                ──imports──> WhisPlayBoard (~/Library/Whisplay/Driver, vendor SDK)

face.py ────────imports──> WhisPlayBoard

sentiment_classifier.py ──HTTP──> qwen-openai at :8001 (BROKEN; falls back to heuristic)
                        ──reads──> ~/.claude/workspace/whisplay-config.json

tts_sync.py ────imports──> audio_sync.py
            ────reads───> ~/iol-monorepo/packages/arlowe-dashboard/.env.local (ElevenLabs key)
            ────HTTP────> face_service.py at :8080/mouth (lip-sync stream)
            ────exec────> piper binary
            ────exec────> sox + aplay

iol_router.py ──HTTP─────> qwen-openai at :8001 (BROKEN)
              ──HTTP─────> qwen-native at :8000 (works; reset endpoint)
              ──exec────> /home/focal55/.local/bin/claude
              ──reads──> ~/.claude/workspace/usage-stats.json (writes too)
              ──imports──> sentiment_classifier.py

stt_server.py ──standalone (only PyPI deps)

dashboard ──HTTP──> face_service.py at :8080 (set state on voice toggle)
          ──systemctl──> arlowe-voice (start/stop)
          ──reads──> ~/.openclaw/* (cost/usage routes — DELETE)
          ──reads──> ~/whisplay/logs (logs route)
          ──exec──> axcl-smi (npu status)
```

**Cycles:** None. The graph is a DAG. Voice depends on face/STT/LLM; LLM (router) depends on sentiment which depends on the local Qwen; face is a leaf except for the Whisplay vendor driver.

---

## Recommended Extraction Order

Four parallelizable streams. Single critical-path: smoke test at end depends on **all** streams.

### Stream A: Whisplay Python carve-out (sequential within stream)

1. **A1: Pull whisplay tree from Pi to local repo.** `scripts/dev-pull-from-pi.sh` rsyncs `~/iol-monorepo/packages/whisplay/` → workspace stash. Working copy lives outside `runtime/` until A2 fans it out.
2. **A2: Place files into `runtime/{voice,face,stt,tts,llm}/`** with the import-graph map above. Don't sanitize yet — keep the working tree booting on the Pi for diff/verification.
3. **A3: Sanitize hardcoded paths and personal literals** (use the per-file table above; one PR per subdirectory).
4. **A4: Author `requirements.txt` per directory** from `~/venvs/voice/` pip freeze.
5. **A5: Write `runtime/voice/README.md`** documenting the wake → STT → LLM → TTS → face contract and ports.

**Blocks:** Stream D smoke test.

### Stream B: Dashboard purge (sequential within stream)

1. **B1: Audit pass.** Author `docs/architecture/dashboard-extraction-audit.md` categorizing every route + page (keep / rewrite / delete). Reviewable artifact.
2. **B2: Copy + delete pass.** Pull the dashboard tree, run the deletes, commit.
3. **B3: Rewrite pass.** Replace `~/.openclaw/...` paths and `iol-monorepo/...` paths with `/etc/arlowe/config.yml` reads.
4. **B4: Smoke test the dashboard standalone** (`pnpm dev`, hit `/api/health` and `/api/voice`).

**Blocks:** Stream D smoke test (since smoke test is "voice toggle + face + e2e," and the dashboard is the toggle).

### Stream C: Third-party vendoring (parallel)

1. **C1: Add `third_party/ax-llm/` as submodule** pinned to `axcl-context` @ `df75c34c`.
2. **C2: Vendor `axcl_host_aarch64_V3.10.2.deb`** — decide between commit / fetch / hybrid (see EXTRACT-10). Author `third_party/axcl/manifest.yml` with sha256 and verification script.
3. **C3: Author `scripts/verify-third-party.sh`** that the future image build runs before proceeding. Exits 0 if all hashes match.

**Blocks:** Phase 11 (image build), not Phase 1 smoke test.

### Stream D: CLI helpers + wake-word + ADRs (parallel)

1. **D1: Copy CLI helpers** (`face`, `speak`, `stt`, `record`, `boot-check`, `purge-logs`, `run-logrotate`, `wake-train`) into `runtime/cli/` with sanitization per the per-file table.
2. **D2: Skip / delete `wifi-watchdog`** with rationale documented (replaced by dashboard connectivity).
3. **D3: Copy wake-word training pipeline** (scripts only, no `.pkl` or `.wav`) into `runtime/wake-word/` with generic-model swap doc.
4. **D4: Author ADR-0001** (`iol_router` extract-clean).
5. **D5: Author ADR-0002** (`arlowe-scheduled-summary` stripped).

**Blocks:** Stream D smoke test only weakly (the CLI helpers help operators verify, but aren't on the data path).

### Convergence: smoke test (last)

1. **E1: Symlink `runtime/` into Arlowe-1's filesystem** — `ln -s /home/focal55/projects/arlowe-firmware/runtime /tmp/arlowe-runtime-test` and a parallel set of systemd units pointing at the new tree.
2. **E2: Boot the new tree, run the wake → STT → LLM → TTS → face flow once manually.**
3. **E3: Capture the smoke test as `docs/operations/phase-1-smoke-test.md`** with exact `say "hey arlowe, what's your name?"` → expected face/audio observation.
4. **E4: Tear down symlinks; old units still work; dev unit returns to its prior state.**

The smoke test does not yet have CI gating (per the success criterion: "manual smoke test, not yet CI-gated"). Phase 2 adds the sanitization gate; later phases add e2e CI.

**Time-on-blocked-path estimate (gut feel, not load-bearing):** Stream B (dashboard) is 3-5x larger than any other stream. If Joe is single-threaded, Stream B is the gating concern. If multiple agents work in parallel via the workforce, B can run alongside A and the convergence point is straightforward.

---

## Pre-Conditions for "Sanitized Pi 5 Dev Unit Runs End-to-End"

What the Phase 1 smoke test concretely needs:

### Services that must be running

| Service | Port | Provides | Status today |
|---|---|---|---|
| `qwen-tokenizer` | 12345 | Tokenizer HTTP | active |
| `qwen-api` | 8000 | LLM native HTTP | active |
| `qwen-openai` | 8001 | OpenAI-compat shim | **BROKEN** (see EXTRACT-05) |
| `whisper-stt` | 8082 | STT HTTP | active |
| `arlowe-face` | 8080 | Face control + display | active |
| `arlowe-voice` | (no inbound) | Wake-word orchestrator | active |
| `arlowe-dashboard` | 3000 | Status UI | active |

For the smoke test to actually exercise the local-LLM path (not just cloud fallback), `qwen-openai` needs to be fixed first. See EXTRACT-05 recommendation.

### Environment / config

| Need | Today | After Phase 1 |
|---|---|---|
| Python venv | `~/venvs/voice/` | `/opt/arlowe/venv/` (built at image time) or per-service venvs in `runtime/*/` |
| Piper binary | `~/models/piper/piper` | `/opt/arlowe/runtime/tts/bin/piper` (image-time) |
| Piper voice | `~/models/piper-voices/en_US-lessac-medium.onnx` | `/opt/arlowe/models/piper-voices/...` |
| Wake verifier | `~/wake_word/hey_arlowe_verifier.pkl` | `/var/lib/arlowe/wake-word/verifier.pkl` (symlink to founder's `.pkl` for smoke test only) |
| Qwen 7B model | `~/models/Qwen2.5-7B-Instruct/` | `/opt/arlowe/models/qwen2.5-7b-int4-ax650/` |
| ax-llm binary | `~/ax-llm/build/main_api_axcl_aarch64` (also copied into `~/models/Qwen2.5-7B-Instruct/`) | Built into image |
| AXCL kernel module + userspace | installed system-wide via `axcl_host_aarch64_V3.10.2.deb` | same |

For Phase 1's manual smoke test, the planner does **not** need to relocate models or rebuild venvs. They can stay in `~/`. The Phase 1 test just needs the runtime code to live in the new tree and reach the existing models via configured paths.

### Audio devices

- USB combo card at ALSA `plughw:2,0` for both record and play. Verified by `arecord -D plughw:2,0 -d 1 /dev/null` succeeding in `boot-check`.
- 16 kHz S16_LE for input.
- Whisplay display reachable at the SPI/GPIO interface that `WhisPlayBoard` opens. (face.py imports the vendor driver; if the driver works, the display works.)

### Network

- Localhost loopback only for the smoke test. No internet round-trip required if the local LLM path is fixed (EXTRACT-05). With a broken local path, the cloud path (Claude CLI subprocess) needs internet + Joe's credentials.

### What "the smoke test passes" looks like operationally

1. `systemctl --user start arlowe-{face,voice,dashboard}` (and the qwen + whisper deps).
2. `boot-check` reports all green (modulo `openclaw-gateway` line which we strip).
3. Operator says "Hey Arlowe, what's two plus two?"
4. Pink wake background flashes, listening face appears, recording for 5s.
5. STT transcribes to text (visible in logs).
6. iol_router classifies as "local," queries local Qwen.
7. Response comes back, sentiment classifier picks an expression, face turns talking-blue, Piper TTS speaks the answer with lip-sync.
8. Face returns to idle.

Total round-trip should be under ~5 seconds on the working device today (most of that is the 5-second mic-record window, which is hardcoded — see EXTRACT-01 sanitization notes about parameterizing).

---

## Founder-Literal Inventory (for Phase 2's Sanitization Gate)

Phase 2's CI sanitization gate needs a banlist. These are every founder-specific literal observed in code that's earmarked for extraction. Some are already documented in `docs/04-scope.md`; this list is the deeper grep-pass version.

**Hard fail (must never appear in `runtime/`, `systemd/`, `config/`, or `third_party/{whisplay-driver,axcl}/`):**

| Literal | Where seen | Replacement |
|---|---|---|
| `focal55` | every systemd unit, every script `~/bin/*`, every venv path, dashboard `~/.openclaw/`, `iol_router.py:48`, `face.py:18`, `voice_client.py:18`, `train_verifier.py:14`, `purge-logs:5` | dedicated `arlowe` system user |
| `arlowe-1` | `boot-check` strings, voice_client banner ("ARLOWE-1 VOICE CLIENT"), face_service HTML title, archive directory name | `arlowe-${device_serial}` or just `arlowe` for cosmetic strings |
| `casa_ybarra_chelsea` | `~/bin/wifi-watchdog:5` (only) | delete wifi-watchdog; if kept, take SSID from config |
| `/home/focal55` | every systemd unit `WorkingDirectory`/`ExecStart`, dashboard 14+ files, scripts/venv paths | `/opt/arlowe/` or `/var/lib/arlowe/` |
| `iol-monorepo` | dashboard route comments, `tts_sync.py:74` (path traversal), service unit `Documentation=` | none — should not appear |
| `~/.openclaw` / `.openclaw` | dashboard `app/api/{config,costs,cron,sub-agents,tasks,usage,stats,logs}/route.ts` | delete or replace with `/etc/arlowe/config.yml` |
| `openclaw-gateway` | `boot-check:32`, dashboard logs route journalctl filter | delete |
| `openclaw` (case-insensitive) | dashboard `ProviderBadge.tsx:17`, voice-client comments | none |
| `Joe` (in system prompt) | `run_api.sh:13` ("Your human is Joe.") | "Your human is the device owner." or pull from owner config |
| `https://github.com/focal55/` | `app/sub-agents/page.tsx:155`, `app/iol/page.tsx:412` | both are in delete-pass pages, but add to banlist |
| `joe@focal55.com` (founder email) | not observed in the code I sampled, but list it for safety | none |
| `~/.claude/workspace` | `iol_router.py:36-37`, `sentiment_classifier.py:16` | `/var/lib/arlowe/state/` or similar |
| `iol-sync`, `usage-stats` (CLI helpers) | listed in scope as personal | not extracted |
| `OpenClaw`, `IOL` (in comments referring to founder infra) | `iol_router.py` history comment, dashboard | sanitize comments; rename `iol_router.py` |

**Soft warnings (might appear in docs, not in shipped code):**

| Literal | Where ok | Where banned |
|---|---|---|
| `arlowe-1.local` | `docs/operations/` (operational notes), `docs/architecture/` (history) | code, systemd, scripts |
| `Joe Ybarra`, `8bit Homies` | `LICENSE`, `README.md`, `CLAUDE.md`, ADRs | nowhere else |

The Phase 2 gate should grep all paths in `runtime/`, `systemd/`, `config/`, `scripts/`, `image/`, `third_party/{whisplay,axcl}/` (but skip the `ax-llm/` submodule — that's vendor code we don't own).

---

## Risks and Gotchas

### R1: `qwen-openai.service` is currently broken (HIGH)

The local LLM HTTP path is dead. `voice_client.py` falls through to cloud Claude on every query today. The "end-to-end smoke test" succeeds today only because the cloud fallback works. Phase 1 either fixes this (recommended option 2 in EXTRACT-05) or accepts that the smoke test is testing the cloud path. **Plan must explicitly call this out in a task** — don't let it be a "discovered during smoke test" surprise.

### R2: Dashboard is heavily contaminated and is not a copy job (HIGH)

EXTRACT-06 in the roadmap reads as "extract the dashboard." Reality: ~50% of routes need to be deleted, the rest need backend rewrites. Plan accordingly — split into audit + delete + rewrite tasks. Treating it as a single-PR copy will produce a contaminated firmware.

### R3: WhisPlay vendor driver is undocumented (MEDIUM)

`face.py` imports `WhisPlayBoard` from `~/Library/Whisplay/Driver/WhisPlay.py`. This is a vendor-shipped Python module from whoever sells the Whisplay hardware. License unknown. Can't ship without resolving:
- Where did this come from? GitHub? Vendor download? Email attachment?
- What's the license?
- Should it be vendored under `third_party/whisplay/` or left as an image-build dependency?

This blocks any Phase 1 task that wants the face service to actually render. The smoke test on Arlowe-1 itself works because the driver is already installed system-wide. A clean Pi (e.g., for image build verification) won't have it. **Schedule a task to resolve this in Phase 1**, even if just "document the source and license."

### R4: TTS reads dashboard's `.env.local` (MEDIUM)

`tts_sync.py:74` reaches into `~/iol-monorepo/packages/arlowe-dashboard/.env.local` for ElevenLabs API key. The moment the dashboard moves to `runtime/dashboard/`, this path breaks. Sanitization task must rewrite this read to come from config, not a sibling-package filesystem path.

### R5: Cloud LLM path requires Joe's Claude Code credentials (MEDIUM)

`iol_router.query_cloud()` runs `claude -p` which uses `~/.claude/.credentials.json`. Joe's credentials. **Cloud routing on a customer unit cannot work in Phase 1.** This is fine — the v1 success criterion explicitly says "no internet round-trip in the default path" — but it means the smoke test on a hypothetical sanitized customer unit (not Joe's Arlowe-1) only exercises the local path. Phase 1 plans must either (a) only smoke-test on Joe's unit (where his credentials are present) or (b) explicitly disable the cloud path during the smoke test. Document the choice.

### R6: Founder's `.pkl` voice fingerprint must not enter the repo (HIGH but easy to enforce)

`hey_arlowe_verifier.pkl` is 50 KB of biometric data. Phase 1 task that copies the wake-word tree must explicitly skip this file (and the `positive/`/`negative/` `.wav` corpus). Add to `.gitignore` immediately.

### R7: `--user` systemd units assume `focal55` HOME (MEDIUM)

Today's units are `~/.config/systemd/user/*.service`. They run under `focal55`. The roadmap target is system-level units under `/etc/systemd/system/` running as a dedicated `arlowe` user. **This affects every `ExecStart` path, every `WorkingDirectory`, and the `--user` flag in `systemctl` calls from the dashboard's `/api/voice` route.** Phase 1 doesn't have to convert all units to system level (that's image-build / Phase 4 scope), but the planner should decide: do Phase 1 units stay `--user` (easier for smoke test on Joe's unit) or move to system (harder, but sets up Phase 4)?

Recommend: keep `--user` for Phase 1 smoke test. Convert to system when image build lands (Phase 11). Document the tech debt.

### R8: hardcoded `localhost:` everywhere (LOW)

Every inter-service call uses `localhost:<port>`. This is fine on a single Pi. If the architecture ever splits services across processes/containers/networks, this fails. Out of scope for v1; flag as future tech debt.

### R9: `sudo` calls from voice service for fan PWM (LOW-MEDIUM)

`voice_client.py` shells out to `sudo tee /sys/class/hwmon/.../pwm1`. This works because `focal55` has `NOPASSWD` sudo (or because the `--user` unit somehow inherits a sudoers grant). Under a dedicated `arlowe` user without passwordless sudo, this breaks. Solution: `chgrp arlowe /sys/.../pwm1 && chmod g+w` at boot (udev rule or oneshot service). Phase 1 is not the moment to fix this; document it as a Phase 4 (config layer / dedicated user) follow-up.

### R10: `~/whisplay.archive-2026-04-05/` exists with older versions (LOW)

The archive contains older copies of `iol_router.py`, `rules_engine.py`, `sentiment_classifier.py`, plus design docs. Don't extract from the archive. The current code is in `~/iol-monorepo/packages/whisplay/`. The archive is useful as **read-only design context**; reference its READMEs (e.g., `IMPLEMENTATION_SUMMARY.md`, `SENTIMENT_CLASSIFICATION.md`) when planning sanitization, but don't pull code from there.

### R11: Two service paths reference paths that don't exist (HIGH for `qwen-openai`, LOW for the rest)

I verified `qwen-openai.service`'s `ExecStart` path doesn't exist. I did not exhaustively verify every other path. Recommend a Phase 1 task: `scripts/verify-source-paths.sh` that walks every `ExecStart=` and `WorkingDirectory=` in the systemd units and `stat`s them. Surfaces other broken units before extraction starts.

### R12: Smoke test on Joe's working dev unit risks contaminating it (MEDIUM)

The convergence step (E1-E4) adds parallel systemd units pointing at the new `runtime/` tree. If something goes wrong, the live unit is still working — but a sloppy task could conflict-on-port or stop a running service. Smoke-test task should explicitly: (a) start the new units on different unit names (e.g., `arlowe-voice-test.service`) to avoid clobber, (b) only stop the original units after the test passes, (c) tear down to original state regardless of test outcome.

---

## Open Questions

### Q1: Does an `openai_wrapper.py` exist somewhere?

Worth one git-archeology pass before declaring it gone:
```bash
ssh arlowe-1 'cd ~/iol-monorepo && git log --all --diff-filter=D --summary -- "**/openai_wrapper.py" 2>/dev/null'
ssh arlowe-1 'cd ~/whisplay.archive-2026-04-05 2>/dev/null && find . -name openai_wrapper.py'
```

If the file was deleted in iol-monorepo's history, recover it. If not, write a fresh ~50-line shim or take the eliminate-the-wrapper path. Either is feasible in a single task; the planner should pick **before** deciding the EXTRACT-05 task structure.

### Q2: WhisPlay driver provenance and license

Need to find out:
- Vendor name / company
- GitHub repo (if public) or download URL
- License terms

Until resolved, `face_service.py` extraction is half-blocked (the code copies but won't run on a clean Pi without the driver). Phase 1 task: spend 30 minutes searching the Pi for installer artifacts (`~/Library/Whisplay/Driver/install_wm8960_drive.sh` is a clue), document findings.

### Q3: Distribution rights for `axcl_host_aarch64_V3.10.2.deb`

Axera's `.deb` — can we redistribute? Public download URL would resolve this. If not, fall back to "user supplies file at image build" with sha256 verify.

### Q4: Should `runtime/` use a single repo-wide Python venv or per-service venvs?

- **Single venv**: simpler, smaller footprint, avoids dep-drift. Today's `~/venvs/voice/` is single-venv style.
- **Per-service venvs**: stronger isolation, easier per-service updates, larger footprint.

I'd lean single venv for v1 (matches current state, simpler image build). Plannable either way.

### Q5: `wake_word/` lives at the *whisplay* package level too

`~/iol-monorepo/packages/whisplay/wake_word/` exists as well as `~/wake_word/`. The whisplay-level version has its own `record_negative.py`/`record_positive.py`/`test_wake.py` — possibly an earlier split. Need to decide which is canonical (probably `~/wake_word/`, since that's where `voice_client.py` looks for the verifier). Likely a single Phase 1 task: pick one, delete the other.

---

## Sources

### Primary (HIGH confidence)

- Direct SSH read of `arlowe-1.local` source files (verified 2026-05-01):
  - `~/iol-monorepo/packages/whisplay/{voice_client.py, face_service.py, face.py, stt_server.py, iol_router.py, sentiment_classifier.py, audio_sync.py, tts_sync.py, voice_expression_controller.py, rules_engine.py, action_executor.py, voice_log.py}`
  - `~/iol-monorepo/packages/whisplay/systemd/{arlowe-face.service, arlowe-voice.service, whisper-stt.service}`
  - `~/.config/systemd/user/{arlowe-dashboard, arlowe-scheduled-summary, qwen-api, qwen-openai, qwen-tokenizer}.service` and the `.timer`
  - `~/iol-monorepo/deploy/scripts/arlowe-scheduled-summary.sh`
  - `~/bin/{face, speak, stt, record, boot-check, purge-logs, run-logrotate, wake-train, wifi-watchdog}`
  - `~/wake_word/{auto_collect, collect_samples, quick_test, test_verifier, train_verifier}.py`
  - `~/models/Qwen2.5-7B-Instruct/run_api.sh`, `qwen2.5_tokenizer_uid.py` (head)
  - `~/llm-models/Qwen2.5-1.5B-Instruct/` directory listing (confirms `openai_wrapper.py` absence)
  - `~/ax-llm/` git state (`origin`, branch, HEAD)
  - `~/Library/Whisplay/Driver/` directory listing
- Direct local read of `/Users/joeybarrajr/projects/iol-monorepo/packages/arlowe-dashboard/`:
  - All routes under `app/api/`
  - Page entry points
  - `package.json`, `.env.example`
- Direct local read of `/Users/joeybarrajr/projects/arlowe-firmware/docs/{01-context, 02-hardware, 03-current-state, 04-scope, 05-proposed-structure, 06-open-decisions}.md`
- Direct local read of `.planning/{ROADMAP, STATE, REQUIREMENTS, PROJECT}.md`
- Live `systemctl --user is-active` and `curl http://localhost:{8000,8001,8080,8082}/...` probes against Arlowe-1
- `sha256sum ~/axcl/axcl_host_aarch64_V3.10.2.deb` (= `1d6bd551644df30e39e3adbe3f32ab9b1d4cdc9c9d12752c27ebc99b35725b94`)

### Secondary (MEDIUM confidence)

- WebFetch `https://github.com/AXERA-TECH/ax-llm` — confirms BSD-3-Clause license, primary branch `axllm`, active development.

### Tertiary (LOW confidence)

- None used. All claims are grounded in either direct file read or live SSH probe.

---

## Metadata

**Confidence breakdown:**
- Source paths and file inventory: HIGH (direct SSH/local read)
- Cross-component imports: HIGH (read every relevant file's import block)
- Live service status: HIGH (verified 2026-05-01 12:30 ET)
- Sanitization scope (whisplay python): HIGH (grepped systematically)
- Sanitization scope (dashboard): MEDIUM (sampled with grep but did not read every file in `app/api/`)
- ax-llm vendoring strategy: HIGH (verified branch and commit)
- axcl deb vendoring strategy: MEDIUM (sha256 captured; distribution rights unresolved)
- WhisPlay driver: LOW (provenance and license unknown — flagged as Q2)
- `qwen-openai.service` brokenness: HIGH (verified by inspecting service status + `find` for the missing file)

**Research date:** 2026-05-01
**Valid until:** 2026-06-15 (the live state of Arlowe-1 may drift — re-verify if the planner picks this up after that date or if Joe makes structural changes to `~/iol-monorepo/packages/whisplay/`).
