---
phase: 02-sanitization-gate
plan: 02
type: summary
completed: 2026-05-26
pr: pending
---

# Plan 02-02 Summary: systemd unit-name block + --scan-dir reuse hook

## What was shipped

Two tasks, both complete:

1. `scripts/sanitize/unit-prefixes.txt` — 3 banned unit-name patterns (one per line, no comments inside data):
   - `openclaw-*`
   - `trace-*`
   - `workforce-metrics-snapshot.*`

2. `scripts/sanitize/check.sh` — full implementation replacing Plan 01 stubs:
   - `--units-only` is real (basename glob-match against all tracked `*.service|timer|socket|target|mount|path` files)
   - `--scan-dir DIR` supported for both grep and units gates; switches enumeration from `git ls-files` to `find DIR -type f`
   - `--grep-only --units-only` combination exits 2 (invalid); unknown flags exit 2
   - No-flag invocation runs both gates back-to-back, OR'ing exit codes
   - Header comment documents all four invocation modes including the Phase 6 reuse contract

3. `scripts/sanitize/test-check.sh` — extended with two new scenarios:
   - Planted `openclaw-test.service` + `safe-unit.service`; assert units gate catches banned prefix, passes clean unit
   - Planted `focal55` literal in scan dir; assert `--grep-only --scan-dir` is non-zero (grep gate reuse contract)

4. `.github/workflows/sanitize.yml` — `banlist-and-units` job now invokes `check.sh` with no flag (both gates); top comment updated to reflect Phase 2 / Plan 02 state.

## Four invocation modes

| Mode | Use case |
|------|----------|
| `check.sh` | Default CI: both grep + units gates against tracked files |
| `check.sh --grep-only` | Banned identity literals only (faster, used in pre-02-02 CI) |
| `check.sh --units-only` | Banned systemd unit basenames only |
| `check.sh --scan-dir DIR` | Scan DIR via `find` instead of `git ls-files`; allow-list ignored |

Flags `--grep-only` and `--units-only` may also be combined with `--scan-dir`.

## Phase 6 reuse contract

```bash
bash scripts/sanitize/check.sh --scan-dir /mnt/img/etc/systemd/system
```

Runs both grep and units gates against the assembled rootfs before pi-gen finalizes the `.img`. The `.sanitize-allowlist` is intentionally ignored in `--scan-dir` mode — the allow-list is a tracked-files concept, not an image-content concept.

## Current main: zero unit-name-block hits

`bash scripts/sanitize/check.sh --units-only` exits 0. The three tracked unit files are:

- `.planning/phases/01-runtime-extraction/test-units/arlowe-dashboard-test.service`
- `.planning/phases/01-runtime-extraction/test-units/arlowe-face-test.service`
- `.planning/phases/01-runtime-extraction/test-units/arlowe-voice-test.service`

All use the `arlowe-*` prefix — none match any banned pattern. Founder-only units (`openclaw-*`, `trace-*`, `workforce-metrics-snapshot.*`) live in gitignored `.dev-stash/` and do not appear in `git ls-files`.

## What's next

- **Plan 03** (issue #56): dashboard rendered-text gate — Playwright spec at `runtime/dashboard/tests/sanitize.spec.ts`
- **Plan 04** (issue #57): SC4 runtime/ cleanup — make `bash scripts/sanitize/check.sh` exit 0 end-to-end (grep gate currently exits 1 on `runtime/` literals; Plan 04 owns fixing that)
