---
phase: 01-runtime-extraction
plan: 10
type: execute
wave: 2
depends_on: ["01"]
files_modified:
  - runtime/cli/face
  - runtime/cli/speak
  - runtime/cli/stt
  - runtime/cli/record
  - runtime/cli/boot-check
  - runtime/cli/purge-logs
  - runtime/cli/run-logrotate
  - runtime/cli/wake-train
  - runtime/cli/logrotate.conf
  - runtime/cli/README.md
  - .planning/phases/01-runtime-extraction/01-10-SUMMARY.md
autonomous: true

requirements:
  - "EXTRACT-08: CLI helpers (face, speak, stt, record, boot-check, purge-logs, run-logrotate, wake-train, wifi-watchdog) extract to runtime/cli/, sanitized"

must_haves:
  truths:
    - "runtime/cli/ contains face, speak, stt, record, boot-check, purge-logs, run-logrotate, wake-train"
    - "wifi-watchdog is NOT present in runtime/cli/ (deleted; rationale documented in README)"
    - "boot-check has openclaw-gateway and port-18789 references stripped"
    - "purge-logs uses /var/lib/arlowe/logs/ instead of $HOME/whisplay/logs"
    - "wake-train cd's into /opt/arlowe/runtime/wake-word (or env-overridable)"
    - "speak uses /opt/arlowe paths or env vars, not ~/models/piper"
    - "All scripts are executable (chmod +x)"
  artifacts:
    - path: "runtime/cli/boot-check"
      provides: "Post-boot validation (seed for Phase 11 BOOT-01)"
      min_lines: 40
    - path: "runtime/cli/speak"
      provides: "TTS CLI wrapper"
      min_lines: 20
    - path: "runtime/cli/purge-logs"
      provides: "Log retention/truncate (seed for Phase 11 LOG-02)"
      min_lines: 15
    - path: "runtime/cli/wake-train"
      provides: "Wake-word retraining wrapper"
      min_lines: 10
    - path: "runtime/cli/logrotate.conf"
      provides: "Logrotate config (referenced by run-logrotate)"
    - path: "runtime/cli/README.md"
      provides: "CLI helpers index + sanitization decisions"
      min_lines: 30
  key_links:
    - from: "runtime/cli/wake-train"
      to: "/opt/arlowe/runtime/wake-word/"
      via: "cd or env override"
      pattern: "/opt/arlowe/runtime/wake-word|ARLOWE_WAKE_WORD"
---

<objective>
Extract the founder's `~/bin/` CLI helpers into `runtime/cli/`, sanitized per research §EXTRACT-08. Critically: **delete `wifi-watchdog`** (research flagged the literal `casa_ybarra_chelsea` in it; the dashboard's connectivity routes replace this functionality), and **strip openclaw-gateway / port 18789 references from `boot-check`**.

Also out of scope (research): `iol-sync`, `usage-stats`, `stats` — these are personal/founder tools, not extracted.

Purpose: Land EXTRACT-08. CLI helpers are the operator's verification path — `boot-check` in particular is the seed for Phase 11's BOOT-01 post-boot validation.

Output: `runtime/cli/` populated with sanitized scripts; wifi-watchdog excluded with documented rationale.
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
  <name>Task 1: Copy CLI helpers from ~/bin/ to runtime/cli/, skip wifi-watchdog</name>
  <files>
    runtime/cli/face
    runtime/cli/speak
    runtime/cli/stt
    runtime/cli/record
    runtime/cli/boot-check
    runtime/cli/purge-logs
    runtime/cli/run-logrotate
    runtime/cli/wake-train
  </files>
  <action>
Assumes `dev-pull-from-pi.sh --apply` mirrored `~/bin/` to `.dev-stash/arlowe-1/bin/`.

Copy each script (verbatim, no sanitization yet):
```bash
for s in face speak stt record boot-check purge-logs run-logrotate wake-train; do
  cp .dev-stash/arlowe-1/bin/$s runtime/cli/$s
done
chmod +x runtime/cli/*
```

**Explicitly do NOT copy**:
- `wifi-watchdog` (deleted per research §EXTRACT-08; rationale: hardcoded `casa_ybarra_chelsea`; dashboard connectivity routes replace it)
- `iol-sync`, `usage-stats`, `stats` (personal/out-of-scope per research and `docs/04-scope.md`)

Also extract logrotate config if it exists at `~/.config/logrotate/arlowe.conf` (referenced by `run-logrotate`):
```bash
ssh arlowe-1 'cat ~/.config/logrotate/arlowe.conf 2>/dev/null' > runtime/cli/logrotate.conf
```
If absent on the Pi, write a minimal one:
```
/var/lib/arlowe/logs/*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
```
  </action>
  <verify>
```bash
for s in face speak stt record boot-check purge-logs run-logrotate wake-train; do
  test -x runtime/cli/$s || { echo "missing $s"; exit 1; }
  bash -n runtime/cli/$s || { echo "syntax error in $s"; exit 1; }
done
test -f runtime/cli/logrotate.conf && \
  ! test -f runtime/cli/wifi-watchdog && \
  ! test -f runtime/cli/iol-sync && \
  ! test -f runtime/cli/usage-stats && \
  echo OK
```
  </verify>
  <done>All 8 expected scripts exist, executable, syntactically valid bash. wifi-watchdog and the personal helpers explicitly absent.</done>
</task>

<task type="auto">
  <name>Task 2: Sanitize boot-check (high-priority — has openclaw-gateway literal)</name>
  <files>runtime/cli/boot-check</files>
  <action>
Per research §EXTRACT-08, `boot-check` references `openclaw-gateway` and port `18789`. **Both must die.**

Read the file. Find:
1. Lines that test/curl `openclaw-gateway` or port `18789` — DELETE those lines entirely. Also delete any output/echo line that prints the gateway status.
2. `plughw:2,0` references — leave (Phase 5 fix), but add a comment:
   ```bash
   # TODO(phase-5): plughw:2,0 hardcoded; replace with auto-detected device.
   ```
3. Any `/home/focal55/...` paths — replace with `/opt/arlowe/...` or `/var/lib/arlowe/...` as appropriate to the path's purpose.
4. Any `--user` systemctl invocations — for Phase 1 keep as `--user` but parameterize via env:
   ```bash
   SYSTEMCTL_FLAGS="${ARLOWE_SYSTEMCTL_FLAGS:---user}"
   systemctl $SYSTEMCTL_FLAGS is-active arlowe-voice
   ```
5. Service list to check: should be the product service set (matching plan 08's logs route):
   - `arlowe-voice`, `arlowe-face`, `arlowe-dashboard`
   - `qwen-tokenizer`, `qwen-api`, `qwen-openai`
   - `whisper-stt`
   Drop any check for `openclaw-*`, `trace-*`, `workforce-*`. Keep checks for product services.

After edits, re-run `bash -n` to confirm valid syntax.
  </action>
  <verify>
```bash
! grep -n 'openclaw\|18789\|focal55' runtime/cli/boot-check && \
  bash -n runtime/cli/boot-check && \
  echo OK
```
  </verify>
  <done>boot-check has zero openclaw-gateway, zero port 18789, zero focal55 references. Still valid bash.</done>
</task>

<task type="auto">
  <name>Task 3: Sanitize remaining CLI scripts</name>
  <files>
    runtime/cli/speak
    runtime/cli/stt
    runtime/cli/record
    runtime/cli/face
    runtime/cli/purge-logs
    runtime/cli/run-logrotate
    runtime/cli/wake-train
  </files>
  <action>
Per the per-file table in research §EXTRACT-08:

**`speak`** (~41 LOC):
- `~/models/piper/piper` → `${PIPER_BIN:-/opt/arlowe/runtime/tts/bin/piper}`
- `~/models/piper-voices/...` → `${PIPER_VOICE:-/opt/arlowe/models/piper-voices/en_US-lessac-medium.onnx}`
- `plughw:2,0` → leave with `# TODO(phase-5)` comment
- `localhost:8080` → leave (single-host)

**`stt`** (~14 LOC):
- `plughw:2,0` → leave with TODO
- `localhost:8082` → leave

**`record`** (~7 LOC):
- `plughw:2,0` → leave with TODO

**`face`** (~27 LOC):
- `localhost:8080` → leave

**`purge-logs`** (~25 LOC):
- `$HOME/whisplay/logs` → `${ARLOWE_LOGS_DIR:-/var/lib/arlowe/logs}`
- Default retention: 7 days (already today's behaviour per research § Project context)

**`run-logrotate`** (~3 LOC):
- `~/.config/logrotate/arlowe.conf` → `${ARLOWE_LOGROTATE_CONF:-/opt/arlowe/runtime/cli/logrotate.conf}` (matches the file we placed in Task 1)

**`wake-train`** (~23 LOC):
- `cd ~/wake_word` → `cd ${ARLOWE_WAKE_WORD_DIR:-/opt/arlowe/runtime/wake-word}`
- Any `~/venvs/voice/...` references → `${ARLOWE_VENV:-/opt/arlowe/venv}/...` or remove if not needed

For every script: search for `focal55`, `iol-monorepo`, `casa_ybarra`, `joe@focal55`. Strip anything found.

Use surgical edits (find/replace), not rewrites. After edits, `bash -n` each script.
  </action>
  <verify>
```bash
! grep -rn 'focal55\|iol-monorepo\|casa_ybarra\|joe@focal55' runtime/cli/ && \
  for s in face speak stt record purge-logs run-logrotate wake-train; do
    bash -n runtime/cli/$s || exit 1
  done && \
  grep -q 'PIPER_BIN\|/opt/arlowe' runtime/cli/speak && \
  grep -q '/var/lib/arlowe' runtime/cli/purge-logs && \
  echo OK
```
  </verify>
  <done>All scripts sanitized; TODO(phase-5) comments mark plughw:2,0 sites for later; paths are env-overridable with /opt/arlowe defaults.</done>
</task>

<task type="auto">
  <name>Task 4: Author runtime/cli/README.md</name>
  <files>runtime/cli/README.md</files>
  <action>
Author `runtime/cli/README.md`:

- Module purpose: Operator CLI helpers for the on-device runtime
- Helpers index (table):
  | Helper | Purpose | Used by |
  |---|---|---|
  | `face` | Set face state via tcp/8080 | Manual ops + smoke test |
  | `speak` | Run TTS once via Piper | Manual ops + smoke test |
  | `stt` | Run STT once via tcp/8082 | Manual ops + smoke test |
  | `record` | Capture mic to file (debug) | Debug |
  | `boot-check` | Post-boot validation (seed for Phase 11 BOOT-01) | systemd or manual |
  | `purge-logs` | Truncate/rotate logs by age + size (seed for Phase 11 LOG-02) | logrotate timer |
  | `run-logrotate` | Wraps logrotate with Arlowe config | systemd timer |
  | `wake-train` | Re-train wake-word verifier from samples | Manual (Phase 8 personalization eventually) |
- Env knobs (the things sanitization parameterized):
  - `ARLOWE_LOGS_DIR` (default `/var/lib/arlowe/logs`)
  - `ARLOWE_LOGROTATE_CONF` (default `/opt/arlowe/runtime/cli/logrotate.conf`)
  - `ARLOWE_WAKE_WORD_DIR` (default `/opt/arlowe/runtime/wake-word`)
  - `ARLOWE_VENV` (default `/opt/arlowe/venv`)
  - `PIPER_BIN`, `PIPER_VOICE`
  - `ARLOWE_SYSTEMCTL_FLAGS` (default `--user` Phase 1; flip to empty for system in Phase 11)
- **wifi-watchdog excluded**: Research §EXTRACT-08 noted the live script hardcodes `casa_ybarra_chelsea` (founder Wi-Fi SSID). The dashboard's `/api/connectivity/*` routes (KEEP per plan 06 audit) replace its functionality, owner-provisioned via pairing (Phase 8). If a Wi-Fi-failure-recovery helper is needed in v1, design fresh.
- **`iol-sync`, `usage-stats`, `stats` excluded**: Personal founder tools per `docs/04-scope.md`.
- TODO(phase-5): every `plughw:2,0` site is marked; replaces with audio auto-detection.
- TODO(phase-11): `--user` systemctl mode flips to system when image build lands.

30-80 lines.
  </action>
  <verify>
```bash
test -f runtime/cli/README.md && \
  test "$(wc -l < runtime/cli/README.md)" -ge 30 && \
  grep -qi 'wifi-watchdog' runtime/cli/README.md && \
  grep -qi 'casa_ybarra\|founder Wi-Fi\|deleted' runtime/cli/README.md && \
  grep -q 'ARLOWE_LOGS_DIR\|ARLOWE_VENV' runtime/cli/README.md && \
  echo OK
```
  </verify>
  <done>README documents the helpers index, env knobs, and the rationale for excluded scripts.</done>
</task>

</tasks>

<verification>
Phase-level checks for this plan:

```bash
# All 8 scripts present, executable, syntactically valid
for s in face speak stt record boot-check purge-logs run-logrotate wake-train; do
  test -x runtime/cli/$s && bash -n runtime/cli/$s
done

# wifi-watchdog and personal helpers absent
! test -f runtime/cli/wifi-watchdog
! test -f runtime/cli/iol-sync
! test -f runtime/cli/usage-stats
! test -f runtime/cli/stats

# Founder literals scrubbed
! grep -rn 'focal55\|iol-monorepo\|casa_ybarra\|joe@focal55\|openclaw\|18789' runtime/cli/

# Specific sanitizations landed
grep -q '/var/lib/arlowe' runtime/cli/purge-logs
grep -q '/opt/arlowe' runtime/cli/speak
```

PR-size: 8 small scripts (~200 LOC total) + logrotate.conf + 50-line README + ~50 LOC of edits ≈ 350 lines. Comfortable under 400 net.
</verification>

<success_criteria>
- All 8 product CLI helpers exist in runtime/cli/, sanitized, executable, valid bash
- wifi-watchdog NOT present (deleted with documented rationale)
- iol-sync/usage-stats/stats NOT present (personal scope)
- Zero founder literals (`focal55`, `iol-monorepo`, `casa_ybarra`, `openclaw`, `18789`) anywhere in runtime/cli/
- README documents helpers, env knobs, exclusion rationale
- EXTRACT-08 complete
</success_criteria>

<output>
After completion, create `.planning/phases/01-runtime-extraction/01-10-SUMMARY.md` documenting:
- Helpers extracted and their LOC
- Sanitization edits per script
- Excluded helpers + rationale
- Open TODOs for Phase 5 (audio) and Phase 11 (system units)
</output>
