# Phase 4: Config overlay - Research

**Researched:** 2026-06-07
**Domain:** Schema-validated config for a mixed Python + Next.js runtime under systemd
**Confidence:** HIGH (repo facts), MEDIUM (library choice — verified against repo deps + ecosystem)

## Summary

Phase 4 replaces hardcoded runtime literals with a two-file overlay: `/opt/arlowe/config/defaults.yml` (shipped, root-owned, read-only) merged with optional `/etc/arlowe/config.yml` (owner-mutable overlay), both validated against `config/schema.yml`. The runtime is **already wired for this pattern**: every Python service reads `ARLOWE_*` environment variables with sensible defaults (set by the systemd units), and `sentiment_classifier.py` already loads `ARLOWE_CONFIG_PATH=/etc/arlowe/config.yml` with a graceful "fall back to default mapping" path. The dashboard already has a `POST /api/config` route that does temp+rename writes (with a `TODO(phase-4): validate against schema` marker) and a `GET` route that returns `{paired:false}` when the overlay is absent.

The cleanest, lowest-friction architecture given this repo: keep **systemd env vars as the injection layer** and introduce a thin config-resolution step that loads defaults+overlay, validates against the schema, and either (a) is sourced into the unit's environment via `ExecStartPre`/`EnvironmentFile`, or (b) is imported by a shared Python module that services already import. Validation lives in **Python (jsonschema, draft 2020-12)** as the single source of truth; the Next.js dashboard reuses the **same `schema.yml` via a small JSON-Schema validation in JS** (ajv) so both sides validate against one file. PyYAML is already a dependency (tts) and `js-yaml` is already a dashboard dependency — no new YAML libs needed.

**The single biggest blocker to surface:** `/etc/arlowe/` is provisioned `root:arlowe 0755` (Phase 3 `install-arlowe-fs.sh`). The dashboard runs as user `arlowe` under `ProtectSystem=strict`, and the unit's `ReadWritePaths` does **not** include `/etc/arlowe`. With dir mode 0755 the `arlowe` user cannot create `config.yml` even if the path were writable. The unit file already carries a `FIXME(Phase 4)` saying the write must go through "a privileged helper (polkit or setuid helper)." **Phase 4 must resolve how the dashboard persists the overlay** — this is not a detail, it's a design fork.

**Primary recommendation:** Schema authored once as JSON Schema embedded in `config/schema.yml`; validated in Python with `jsonschema`, in the dashboard with `ajv`. Config resolution lives in a shared Python module (`runtime/lib/arlowe_config.py`) imported by services; validation runs at service entry (clean journal error + `sys.exit(1)`) AND a standalone `arlowe-config-validate` invoked by `ExecStartPre=` so a bad overlay fails fast before the interpreter loads heavy ML deps. Dashboard writes via a small root helper invoked through the existing polkit/systemctl seam (see Pitfall 1).

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| PyYAML | 6.0.3 (already pinned in `runtime/tts/requirements.txt`) | Parse `defaults.yml` + overlay in Python | Already in tree; `yaml.safe_load` is the canonical safe parse |
| jsonschema | latest 4.x (draft 2020-12 support) | Validate merged config against schema in Python | De-facto standard; language-agnostic schema reusable by JS; no model boilerplate |
| js-yaml | ^4.1.1 (already a dashboard dep) | Parse YAML in the Next.js route | Already imported in `app/api/config/route.ts` |
| ajv | ^8.x (new dashboard dep) | Validate config against the same JSON Schema in the dashboard | Standard Node JSON-Schema validator; lets the dashboard pre-validate before write |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| (none — stdlib `os`, `pathlib`) | - | Env injection, path merge | Config resolution is small enough to avoid a config framework |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| jsonschema (Python) | Pydantic v2 | Pydantic is faster and ergonomic BUT its schema lives in Python classes, not a shareable file — the dashboard could only consume it via a *generated* JSON Schema (extra build step). The success criterion is `config/schema.yml` as the artifact; jsonschema consumes that file directly on both sides. Pick jsonschema for single-source-of-truth. |
| jsonschema | Cerberus / Voluptuous | Pythonic but not consumable by the Node dashboard; would force a second schema definition. Rejected. |
| Validate in both Python+JS | Validate only in Python; dashboard POSTs raw, Python rejects | Simpler (one validator) but the dashboard couldn't give the user inline errors before write, and an invalid overlay could land on disk and brick a restart. Recommend validate-before-write in the dashboard too. |

**Installation:**
```bash
# Python (add to a shared runtime/lib/requirements.txt or each service that loads config)
# jsonschema; PyYAML already present
# Dashboard
pnpm add ajv          # js-yaml already present
```

## Architecture Patterns

### Existing injection convention (DO NOT fight this)
Every Python service already resolves config from `ARLOWE_*` env vars with literal defaults, set by the systemd units. Examples verified in-repo:

- `runtime/voice/voice_client.py`: `ARLOWE_FACE_URL`, `ARLOWE_STT_URL`, `ARLOWE_DASHBOARD_URL`, `ARLOWE_PIPER_MODEL`, `ARLOWE_ALSA_DEVICE` (Phase 5), `ARLOWE_VERIFIER_MODEL`
- `runtime/llm/router.py`: `ARLOWE_VOICE_MODEL`, `ARLOWE_VOICE_TIMEOUT`, `ARLOWE_STATE_DIR`
- `runtime/face/sentiment_classifier.py`: **already reads `ARLOWE_CONFIG_PATH=/etc/arlowe/config.yml`** and falls back to a default mapping — this is the reference implementation for "absent overlay = not-yet-paired, no crash."
- Units inject the env (`arlowe-voice.service`, `arlowe-face.service`, `arlowe-dashboard.service` already set `ARLOWE_CONFIG_PATH`, `ARLOWE_LOGS_DIR`, etc.)

**Implication for the plan:** the config knobs map to env vars the services already consume. The loader's job is to translate `defaults.yml` + overlay → the `ARLOWE_*` values, OR services import a shared resolver that returns a validated dict. Two viable shapes below.

### Recommended Project Structure
```
config/
├── schema.yml          # JSON Schema (CONFIG-01) — type, default, enum, description per knob
└── defaults.yml        # shipped defaults (CONFIG-02); installed to /opt/arlowe/config/defaults.yml
runtime/lib/            # NEW shared lib dir (mirror of /opt/arlowe/runtime/lib at runtime)
├── arlowe_config.py    # load(defaults, overlay) -> validate -> merged dict; raises on violation
└── requirements.txt    # jsonschema, PyYAML
scripts/provision/
└── install-arlowe-config.sh   # NEW: installs defaults.yml + schema.yml into /opt/arlowe/config
```
Note: `install-arlowe-fs.sh` already creates `/opt/arlowe/config` and intentionally does NOT create `defaults.yml` (its comments mark that as the Phase-4 contract). Add a content installer; do not modify the fs installer's directory creation.

### Pattern 1: Config resolution + validation in a shared module
**What:** One module both services and a CLI validator import.
**When to use:** Always; keeps merge/validate logic in one place.
```python
# runtime/lib/arlowe_config.py  (installed to /opt/arlowe/runtime/lib/)
import os, sys, yaml, json
from pathlib import Path
from jsonschema import Draft202012Validator

DEFAULTS = Path(os.environ.get("ARLOWE_DEFAULTS_PATH", "/opt/arlowe/config/defaults.yml"))
OVERLAY  = Path(os.environ.get("ARLOWE_CONFIG_PATH",   "/etc/arlowe/config.yml"))
SCHEMA   = Path(os.environ.get("ARLOWE_SCHEMA_PATH",   "/opt/arlowe/config/schema.yml"))

def load() -> dict:
    defaults = yaml.safe_load(DEFAULTS.read_text())
    overlay  = yaml.safe_load(OVERLAY.read_text()) if OVERLAY.exists() else {}  # absent overlay == not paired
    merged   = {**defaults, **(overlay or {})}      # shallow; deep-merge per-knob if nested
    schema   = yaml.safe_load(SCHEMA.read_text())
    errors   = sorted(Draft202012Validator(schema).iter_errors(merged), key=lambda e: e.path)
    if errors:
        for e in errors:
            print(f"[arlowe-config] schema violation at {'/'.join(map(str,e.path)) or '<root>'}: {e.message}", file=sys.stderr)
        raise SystemExit(78)   # EX_CONFIG (sysexits.h) — clean, greppable in journal
    return merged
```
`SystemExit(78)` = `EX_CONFIG`; systemd records it and the journal shows the stderr lines. Distinct from generic crash exit codes.

### Pattern 2: Fail-fast at ExecStartPre (before heavy imports)
**What:** A standalone validator the unit runs before the real ExecStart.
**When to use:** For services with slow imports (voice loads openwakeword/onnx; llm loads transformers) — you want the config rejected in milliseconds, not after a 10s model load.
```ini
# in each *.service [Service] block
ExecStartPre=/opt/arlowe/venvs/<svc>/bin/python -m arlowe_config_validate
ExecStart=...
```
A bare `ExecStartPre` that exits non-zero **prevents the main process from starting** (verified: systemd treats a non-`-`-prefixed ExecStartPre failure as a unit start failure; the journal shows the pre-start exit). This directly satisfies SC2 "refuse to start on schema violation with a clear journal error."

### Pattern 3: Env injection vs. in-process load — pick in planning
- **Option A (in-process):** services `from arlowe_config import load; cfg = load()` and read knobs from the dict. Cleanest single source of truth. Requires `runtime/lib` on `PYTHONPATH` (units already set `PYTHONPATH=/opt/arlowe/runtime`; put the lib under `runtime/lib` and adjust, or under an existing importable package).
- **Option B (env bridge):** an `ExecStartPre` writes resolved values to an `EnvironmentFile` that the unit reads, preserving the existing `ARLOWE_*` env convention with zero Python-code change in services. Lower blast radius for Phase 4 (services keep reading env), but adds a generated file in `/run`.
  - Recommend **A for services that already need structured config** (face sentiment mapping, persona), **B as the migration shim** for the pure-env knobs (ports, URLs) so Phase 4 doesn't rewrite every service. Planner should decide per knob.

### Anti-Patterns to Avoid
- **Re-deriving the schema in two languages.** One `schema.yml`; both validators read it.
- **Validating only in the dashboard.** The image must boot and validate without the dashboard running (first-boot, pre-pairing). Python validation at service start is the authoritative gate; dashboard validation is UX.
- **Deep-merging silently.** Decide shallow vs deep merge explicitly and document it in schema comments; mismatched nesting between defaults and overlay is a classic config bug.
- **Treating absent overlay as an error.** `sentiment_classifier.load_config()` already models the correct behavior: absent overlay → use defaults, no crash (SC3).

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Config validation | Hand-written type/enum checks | `jsonschema` (Py) + `ajv` (JS) against `schema.yml` | Enums, defaults, type coercion, nested errors, path reporting are all solved; hand-rolled checks drift from the schema |
| Atomic overlay write | Plain `writeFile` | temp-file + `rename()` (already done in `route.ts`) | Already correct in repo — keep it, just add validation before write |
| YAML parse | regex / manual | `yaml.safe_load` / `js-yaml` (both present) | Never `yaml.load` (unsafe); never hand-parse |
| Privileged write to /etc | setuid wrapper from scratch | systemd-run/polkit seam OR a tiny audited helper | See Pitfall 1 — getting privilege boundaries right is security-critical (this is package:security territory) |

## Common Pitfalls

### Pitfall 1: The dashboard cannot write /etc/arlowe/config.yml as-is (BLOCKER)
**What goes wrong:** `route.ts` does `writeFile('/etc/arlowe/.config.yml.tmp')` then `rename()` to `/etc/arlowe/config.yml`. But:
- The dir is provisioned `root:arlowe 0755` (`install-arlowe-fs.sh`) — group `arlowe` has `r-x`, **not** write. The `arlowe` user cannot create files there.
- The `arlowe-dashboard.service` unit runs `ProtectSystem=strict` and lists `ReadWritePaths=/var/lib/arlowe/dashboard /var/lib/arlowe/logs/dashboard` — `/etc/arlowe` is **not** writable even if perms allowed it. The unit's own comment: *"`/etc/arlowe/config.yml` is intentionally NOT in ReadWritePaths — the dashboard POST /api/config route goes through a privileged helper. FIXME(Phase 4): wire the privileged-helper write path."*

**Why it happens:** Phase 3 deliberately deferred the write path to Phase 4.
**How to avoid / options for the planner:**
1. **Privileged helper via the existing systemctl/polkit seam.** The dashboard already shells out (`child_process.exec`) for nmcli. A small root-owned helper (`/usr/local/sbin/arlowe-write-config`) invoked through a polkit-authorized path can validate-then-write. The polkit rule today only covers `org.freedesktop.systemd1.manage-units` — writing config is a *different* action, so this needs a new authorized mechanism (a dedicated polkit action, a `systemd-run` transient unit, or a setuid helper).
2. **Loosen perms:** make `/etc/arlowe` `root:arlowe 0775` (group-writable) AND add `ReadWritePaths=/etc/arlowe` to the dashboard unit. Simplest, but widens the dashboard's write surface into `/etc` — weigh against the sandbox hardening Phase 3 invested in.
3. **State dir instead of /etc:** write the overlay to an `arlowe`-writable path and symlink/bind — rejected, breaks the CONFIG-03 `/etc/arlowe/config.yml` contract that other services and the GET route already hardcode.
**Recommendation:** Option 1 (helper) is the security-correct answer and matches the unit's own FIXME, but it is the heaviest. Option 2 is defensible if the dashboard is already trusted (it can restart services via polkit anyway). **This is a real design decision — flag for the planner to resolve before writing tasks, likely as an ADR.** Treat any task touching this as `package:security`.

### Pitfall 2: Validation after heavy imports = slow failure
**What goes wrong:** Validating inside `voice_client.py` after `import openwakeword, onnxruntime` means a bad overlay takes ~10s to reject.
**How to avoid:** `ExecStartPre` standalone validator (Pattern 2) rejects in <1s before the real process loads.

### Pitfall 3: defaults.yml must contain ZERO founder literals
**What goes wrong:** CI sanitize gate (Phase 2) fails any tracked file (not in `.sanitize-allowlist`) containing `focal55`, `arlowe-1`, etc. `config/defaults.yml` and `config/schema.yml` will be **scanned** (they ship in the image — they must NOT be allow-listed).
**How to avoid:** hostname default must be a template like `arlowe-${device_serial}` (resolved Phase 7/8), never `arlowe-1`. Audio device default `plughw:2,0` is Phase 5's concern, not a founder literal. Run `scripts/sanitize` locally before commit.
**Warning signs:** any concrete personal name, the dev Pi hostname, ElevenLabs keys (`tts_sync.py` reads `ELEVENLABS_API_KEY` from env — keep that out of defaults.yml).

### Pitfall 4: Restart trigger must use the units' real names
**What goes wrong:** A persona change should restart only the affected unit. The polkit rule authorizes `arlowe` to manage units matching `arlowe-*`, `qwen-*`, or exactly `whisper-stt.service` — nothing else, and NOT `daemon-reload`.
**How to avoid:** map each knob → affected unit(s). Persona/face → `arlowe-face.service` (+ maybe `arlowe-voice`); model choice → `qwen-api`/`qwen-tokenizer`; audio (Phase 5) → `arlowe-voice`. The dashboard restart goes `systemctl restart <unit>` and succeeds without sudo via the Phase 3 polkit rule (its comment explicitly lists "dashboard POST /api/config (Phase 4 will use)").
**Warning signs:** attempting `daemon-reload` (denied) or restarting a non-prefixed unit (denied).

### Pitfall 5: Shallow vs deep merge of defaults+overlay
**What goes wrong:** `{**defaults, **overlay}` replaces whole top-level keys. If `persona` is a nested object and the overlay sets only one sub-field, the rest is lost.
**How to avoid:** decide per-knob; document; deep-merge nested objects if any knob is structured (persona/face assets likely are).

## CONFIG-06 Knob Inventory (real, against the repo)

Knobs required by CONFIG-06, mapped to where the literal currently lives:

| Knob | Current literal / env | File(s) | Affected unit |
|------|----------------------|---------|---------------|
| hostname | (none yet; Phase 7/8 device identity) | — | system; not a service env |
| audio devices | `ARLOWE_ALSA_DEVICE="plughw:2,0"` (Phase 5 owns the *detection*, Phase 4 owns the *knob*) | `voice_client.py:49-50`, `wake-word/auto_collect.py:21` | arlowe-voice |
| model choice (7B vs 1.5B) | `QWEN_MODEL_DIR=/opt/arlowe/models/qwen2.5-7b-int4-ax650` | `qwen-api.service` (Environment), implicitly `router.py`/`sentiment_classifier.py` QWEN_URL | qwen-api, qwen-tokenizer |
| persona / face assets | sentiment→expression mapping; `DEFAULT_MAPPING`, `EXPRESSION_TO_STATE` | `face/sentiment_classifier.py:38-58` (already reads `ARLOWE_CONFIG_PATH`) | arlowe-face (+ arlowe-voice) |
| log retention | `ARLOWE_LOGS_DIR` exists; **no retention policy literal yet** | `voice_log.py:11`, units | journald/logrotate (Phase 11 consumes) |
| support-mode policy | (none yet; Phase 10) | — | (Phase 10) |
| OTA channel URL | (none yet; Phase 9) | — | (Phase 9) |
| **bonus literals found** | face port `8080` (F1 todo), STT port `8082`, dashboard `3000`, qwen `8000`, `ARLOWE_VOICE_MODEL`, `ARLOWE_VOICE_TIMEOUT`, piper model path | `face_service.py:179`, `stt_server.py:17-18`, multiple | respective units |

**Key insight for the planner:** several CONFIG-06 knobs (hostname, support-mode, OTA URL) have **no consumer yet** — they're defined in `schema.yml` + `defaults.yml` in Phase 4 but actually *used* in Phases 7/8, 9, 10. Phase 4's job is to *define and validate* them, not necessarily wire a live consumer for every one. SC1 says "schema defines every knob"; SC4 only requires *one* knob (persona) to take effect end-to-end. Persona is the right end-to-end demo because `sentiment_classifier.py` already has the overlay-read scaffolding — pick it for the SC4 vertical slice.

The `F1` (face port 8080) and `F4` (voice_client `sudo tee` fan control) todos are tagged Phase 4 in the unit FIXMEs — confirm whether they're in-scope or punt F4 (fan control is unrelated to config; it's a sandbox issue).

## Code Examples

### Dashboard: validate before atomic write (extends existing route.ts)
```typescript
// runtime/dashboard/app/api/config/route.ts (add validation; keep temp+rename)
import Ajv from 'ajv';
import yaml from 'js-yaml';
import { readFile } from 'fs/promises';

const SCHEMA_PATH = process.env.ARLOWE_SCHEMA_PATH ?? '/opt/arlowe/config/schema.yml';

export async function POST(request: NextRequest) {
  const body = await request.json();
  const schema = yaml.load(await readFile(SCHEMA_PATH, 'utf-8'));
  const validate = new Ajv({ allErrors: true }).compile(schema as object);
  if (!validate(body)) {
    return NextResponse.json({ error: 'schema violation', details: validate.errors }, { status: 422 });
  }
  // existing temp+rename write, then restart affected unit via the existing systemctl seam
}
```
Source: existing `runtime/dashboard/app/api/config/route.ts` (verified in repo) + ajv standard usage.

### Reference for graceful absent-overlay handling (already in repo)
```python
# runtime/face/sentiment_classifier.py (verified) — the SC3 pattern to copy
def load_config() -> dict:
    for path in (CONFIG_OVERLAY, CONFIG_PATH):
        if path.exists():
            try: ...  # parse
    return DEFAULT_MAPPING   # absent overlay -> defaults, no crash
```

## State of the Art

| Old Approach | Current Approach | Impact |
|--------------|------------------|--------|
| Hardcoded literals in source | env-var injection via systemd units (already in place) | Phase 4 layers schema+overlay on top of an existing env convention — low blast radius |
| One validator per language | shared JSON Schema file, jsonschema + ajv read it | Single source of truth satisfies CONFIG-01's `schema.yml` artifact requirement |

**Deprecated/outdated:** `qwen-openai.service` (ADR-0001); router uses ax-llm native `/api/chat` — relevant only if a knob touches the LLM endpoint.

## Open Questions

1. **How does the dashboard write `/etc/arlowe/config.yml`?** (Pitfall 1) — privileged helper vs. loosening dir perms + ReadWritePaths. **Needs an ADR / planning decision before tasks are written.** Security-sensitive.
   - What we know: current perms (`root:arlowe 0755`) + sandbox (`ProtectSystem=strict`, no `/etc/arlowe` in ReadWritePaths) block the write; the unit FIXME expects a privileged helper.
   - Recommendation: decide in planning; default to a small audited root helper if security posture matters, else 0775 + ReadWritePaths.

2. **Env-bridge vs in-process load** (Pattern 3) — per-knob decision. Recommend in-process for structured knobs (persona), env-bridge shim for simple scalars to avoid rewriting every service.

3. **Is `config/schema.yml` literally YAML-encoded JSON Schema, or a custom DSL?** SC1 requires type/default/allowed-values/docstring per knob — JSON Schema (`type`, `default`, `enum`, `description`) covers all four natively. Recommend JSON Schema authored in YAML for readability. Confirm no custom format is expected.

4. **`docs/04-scope.md` referenced by CONFIG-02 does not exist** — CONFIG-02 says defaults.yml "covers every literal flagged in `docs/04-scope.md`." That doc is absent. The knob inventory above substitutes; planner may need to author `docs/04-scope.md` as a Phase-4 deliverable or treat this RESEARCH's inventory as the canonical list.

5. **Scope of F1/F4 todos** — F1 (face port→config) fits Phase 4 cleanly; F4 (voice_client `sudo tee` fan control under NoNewPrivileges) is a sandbox bug, not config. Recommend punt F4 or split it out.

## Sources

### Primary (HIGH confidence)
- Repo files (verified directly): `scripts/provision/install-arlowe-fs.sh`, `units/*.service`, `units/install-units.sh`, `provision/polkit/50-arlowe-systemctl.rules`, `runtime/dashboard/app/api/config/route.ts`, `runtime/dashboard/package.json`, `runtime/voice/voice_client.py`, `runtime/llm/router.py`, `runtime/face/sentiment_classifier.py`, `runtime/*/requirements.txt`, `.sanitize-allowlist`, `.planning/REQUIREMENTS.md`, `.planning/ROADMAP.md`, `.planning/STATE.md`
- systemd ExecStartPre fail-fast behavior (non-`-` prefixed failure prevents start): systemd issue #11868, RedHat bz#651797

### Secondary (MEDIUM confidence)
- Python validation library comparison (jsonschema/pydantic/cerberus/voluptuous), 2026: dev.to, dasroot.net, pydantic docs
- systemd troubleshooting / exit codes: oneuptime.com

## Metadata

**Confidence breakdown:**
- Repo facts / knob inventory: HIGH — read directly from source
- Standard stack (jsonschema + ajv, single schema): MEDIUM — verified against existing deps + ecosystem; final lib choice is the planner's call but justified
- Pitfall 1 (write-path blocker): HIGH — perms + unit ReadWritePaths + unit FIXME all confirm it
- Validation/fail-fast pattern: HIGH — systemd behavior verified; matches existing `sentiment_classifier` graceful-fallback

**Research date:** 2026-06-07
**Valid until:** 2026-07-07 (stable; repo-derived facts don't expire, library minor versions may bump)
