---
phase: 02-sanitization-gate
plan: 04
type: summary
status: complete
---

# Plan 02-04 Summary — runtime/ SC4 cleanup + F5 ADR-0001 fix

## Disposition matrix applied

| File | Decision | Notes |
|------|----------|-------|
| `runtime/llm/router.py:35` | Sanitized | `/home/focal55/ax-llm/docs/http_api.md` → `ax-llm's docs/http_api.md (vendored at third_party/ax-llm/)` |
| `runtime/llm/run_api.sh:6` | Sanitized | `smoke test on arlowe-1` → `smoke-testing on a Pi 5 dev unit with the AX accelerator` |
| `runtime/dashboard/app/layout.tsx:11` | Sanitized | `"Control panel for Arlowe-1"` → `"Control panel for your Arlowe device"` |
| `runtime/dashboard/app/components/RetroActivityMonitor.tsx:140` | Sanitized | `ARLOWE-1 SYSTEM MONITOR` → `ARLOWE SYSTEM MONITOR` |
| `runtime/dashboard/README.md:61` | Sanitized | Section header `Running locally on arlowe-1` → `Running locally on a Pi 5 dev unit` |
| `runtime/face/README.md:37,43,59` | Sanitized | 3 occurrences: driver path prose, broken-endpoint note, section header |
| `runtime/llm/README.md:52` | Sanitized | Smoke-test env-override note |
| `runtime/stt/README.md:39` | Sanitized | Section header |
| `runtime/tts/README.md:64,68,76,79,99` | Sanitized | 5 occurrences: PyYAML venv note, ssh command, smoke-test note, section header, PLAY_DEVICE known limitation |
| `runtime/voice/README.md:23` | Sanitized | Section header |
| `runtime/wake-word/README.md:91-97` | Sanitized | Both `iol-monorepo` and `arlowe-1` in one paragraph; rewritten to generic post-extraction architectural note |
| `runtime/*/requirements.txt` (6 files) | Allow-listed | Dev-pinning provenance comments; audit-trail metadata, never renders or ships as a service |
| `runtime/tts/manifest.yml` | Allow-listed | Same reasoning — SHA-256 verification provenance |
| `runtime/dashboard/tests/sanitize.spec.ts` | Allow-listed | Gate test file; contains banned literals as test data by design |
| `docs/architecture/0001-iol-router-extraction.md` | Sanitized (F5 fix) | "Why option-2" bullet rewritten to match resolved decision |

No deviations from the plan's disposition matrix.

## F5 fix landed

- `docs/architecture/0001-iol-router-extraction.md` "Verified working live" bullet rewritten: removed false assertion that ax-llm speaks OpenAI `/v1/chat/completions`; replaced with accurate curl against `/api/chat` returning `{done, message}` and explanation of the PR #52 drift.
- F5 todo moved from `.planning/todos/pending/` to `.planning/todos/done/` with closure note appended.
- `STATE.md` did not list F5 (it was captured as an untracked file, never committed to STATE); no STATE.md edit needed.

## Phase-exit criteria verification

All four ROADMAP SC criteria met:

**SC1 — Grep gate wired and exercised:**
```
bash scripts/sanitize/check.sh --grep-only
# sanitize grep: clean (119 files scanned) — exit 0
```

**SC2 — Unit-name block wired and exercised:**
```
bash scripts/sanitize/check.sh --units-only
# sanitize units: clean (3 unit files checked) — exit 0
```

**SC3 — Dashboard rendered-text gate wired and exercised:**
```
cd runtime/dashboard && pnpm exec playwright test sanitize.spec.ts --project=chromium
# 4 passed (25.3s) — exit 0
```
All four routes pass: `/`, `/connectivity`, `/logs`, `/npu`.

**SC4 — runtime/ tree zero banned literals outside allow-list:**
```
bash scripts/sanitize/check.sh
# --- grep gate ---
# sanitize grep: clean (119 files scanned)
# --- units gate ---
# sanitize units: clean (3 unit files checked)
```

Self-test still passes all 3 PASS lines:
```
bash scripts/sanitize/test-check.sh
# PASS: grep gate correctly blocked planted focal55
# PASS: gate correctly blocked planted openclaw-test.service while allowing safe-unit.service
# PASS: grep gate with --scan-dir correctly blocked planted focal55 literal
```

## Final .sanitize-allowlist contents

```
# .sanitize-allowlist
# Path globs (gitignore-style) of tracked files allowed to contain banned identity literals.
# Single `*` does NOT cross `/`; use `**` for recursive matching.
# If you're tempted to add a new entry, ask: does this file ship in the firmware image?
# If yes, fix the literal instead of allow-listing.

# Planning artifacts that document banned literals as part of their purpose.
.planning/**

# Architecture decision records and operational docs that capture historical state.
docs/architecture/**
docs/architecture-overview.md
docs/operations/phase-1-smoke-test.md

# Journey entries (workforce diary; never ships in firmware).
docs/journey/**

# Workforce / template plumbing — references @focal55 the GitHub username, not founder
# identity in the firmware sense. None of these files ship in the image.
.github/CODEOWNERS
.github/ISSUE_TEMPLATE/config.yml
AGENTS.md.template
README.md

# Dev pull script: references arlowe-1 because that's the dev unit it pulls from.
scripts/dev-pull-from-pi.sh

# Third-party distribution paperwork.
third_party/axcl/DISTRIBUTION-RIGHTS.md
third_party/axcl/INSTALL.md
third_party/whisplay-driver/PROVENANCE.md

# Sanitize gate self-references (the data files contain the literals by design).
.sanitize-allowlist
scripts/sanitize/banlist.txt
scripts/sanitize/unit-prefixes.txt
scripts/sanitize/test-check.sh
runtime/dashboard/tests/sanitize.spec.ts

# --- Dev-pinning provenance allow-list (Plan 04 SC4 cleanup) ---
# The runtime/*/requirements.txt comments record which dev unit the pins were
# captured from and when. These are audit-trail metadata that never render as
# user-facing strings and never ship as a service. Rewriting them loses real
# provenance value (we'd no longer know which Pi the pins are calibrated against).
# Decision rationale: 02-04-PLAN.md disposition matrix.
runtime/voice/requirements.txt
runtime/face/requirements.txt
runtime/stt/requirements.txt
runtime/tts/requirements.txt
runtime/llm/requirements.txt
runtime/wake-word/requirements.txt

# Same reasoning: tts/manifest.yml's SHA-256-verified-on comments are provenance.
runtime/tts/manifest.yml
```

## Provenance phrasing notes for future authors

- `runtime/tts/README.md:68` — the `ssh <your-dev-pi>` angle-bracket placeholder is intentional; it matches the convention used for operator docs where the command is device-specific.
- `runtime/wake-word/README.md:91-97` — the original paragraph named both the source monorepo and the dev hostname in a single sentence. The replacement drops both proper nouns and preserves only the architectural point (pre-extraction copy vs. canonical post-extraction tree). No cross-links existed to the old section header.
- `runtime/dashboard/tests/sanitize.spec.ts` — the test file contains banned literals as its test-data array. Allow-listing it is the correct call; the gate script validates rendered output, not the test file itself.

## Phase 2 closure note

This is the last plan in Phase 2 (sanitization gate). Plans 01-04 are complete. The next step is `/gsd:verify-work` against Phase 2's SC1-SC4 success criteria. All three sanitize CI jobs (banlist-and-units, self-test, dashboard-rendered-text) are expected to go GREEN on this PR, completing Phase 2.
