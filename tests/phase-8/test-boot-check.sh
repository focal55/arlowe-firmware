#!/usr/bin/env bash
# tests/phase-8/test-boot-check.sh
#
# Drives runtime/cli/boot-check through both pairing states with PATH shims for
# systemctl, lsof and python3, and ARLOWE_AXCL_SMI for the NPU probe.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOOT_CHECK="${REPO_ROOT}/runtime/cli/boot-check"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$(( FAILURES + 1 )); }
assert_rc()     { if [[ "$2" == "$1" ]]; then pass "$3 (exit $2)"; else bad "$3 (expected exit $1, got $2)"; fi; }
assert_out()    { if grep -qF -- "$1" "$OUT"; then pass "$2"; else bad "$2 — output lacks: $1"; fi; }
assert_no_out() { if grep -qF -- "$1" "$OUT"; then bad "$2 — output contains: $1"; else pass "$2"; fi; }

SERVICES=(qwen-tokenizer qwen-api whisper-stt arlowe-face arlowe-voice arlowe-dashboard)
PORTS=(12345 8000 8082 8080 3000)

SHIMS="${WORK}/bin"
mkdir -p "$SHIMS"
# Shims read their state from files, so each case only rewrites those files.
cat > "${SHIMS}/systemctl" <<SH
#!/bin/sh
for a; do svc=\$a; done
grep -qx "\$svc" "${WORK}/active"
SH
cat > "${SHIMS}/lsof" <<SH
#!/bin/sh
for a; do p=\${a#:}; done
grep -qx "\$p" "${WORK}/listening"
SH
printf '#!/bin/sh\nexit 0\n' > "${SHIMS}/python3"
cat > "${WORK}/axcl-smi" <<SH
#!/bin/sh
test ! -e "${WORK}/npu-down"
SH
chmod 0755 "${SHIMS}"/* "${WORK}/axcl-smi"

ROOT="${WORK}/root"
mkdir -p "${ROOT}/var/lib/arlowe/identity" "${ROOT}/var/lib/arlowe/state" \
    "${ROOT}/opt/arlowe" "${ROOT}/etc/arlowe"
chmod 0700 "${ROOT}/var/lib/arlowe/identity"
OWNER=$(stat -c '%U:%G' "${ROOT}/var/lib/arlowe/identity" 2>/dev/null \
    || stat -f '%Su:%Sg' "${ROOT}/var/lib/arlowe/identity")

set_state() {  # set_state paired|unpaired all|none|<svc-to-drop> npu-up|npu-down
    rm -f "${ROOT}/etc/arlowe/config.yml" "${WORK}/npu-down"
    [[ "$1" == paired ]] && : > "${ROOT}/etc/arlowe/config.yml"
    : > "${WORK}/active"; : > "${WORK}/listening"
    if [[ "$2" != none ]]; then
        printf '%s\n' "${SERVICES[@]}" | grep -vx "$2" > "${WORK}/active"
        printf '%s\n' "${PORTS[@]}" > "${WORK}/listening"
    fi
    [[ "$3" == npu-down ]] && : > "${WORK}/npu-down"
    return 0
}

run() {  # run <label> [args...]
    OUT="${WORK}/out-$1.log"; shift
    PATH="${SHIMS}:${PATH}" ARLOWE_ROOT="$ROOT" ARLOWE_IDENTITY_OWNER="$OWNER" \
        ARLOWE_AXCL_SMI="${WORK}/axcl-smi" bash "$BOOT_CHECK" "$@" >"$OUT" 2>&1
    RC=$?
}

set_state unpaired none npu-up
run unpaired --first-boot
assert_rc 0 "$RC" "[bc-unpaired] unpaired with healthy hardware"
for d in "Qwen Tokenizer" "Qwen LLM API" "Whisper STT Server" "Face Display Service" \
         "Voice Assistant" "Arlowe Dashboard"; do
    assert_out "SKIP $d (not paired" "[bc-unpaired] service '$d' is SKIP"
done
for p in "${PORTS[@]}"; do
    assert_out "port $p) (not paired" "[bc-unpaired] port $p is SKIP"
done
assert_no_out "FAIL" "[bc-unpaired] no FAIL lines"
assert_out "READY TO PAIR" "[bc-unpaired] reports READY TO PAIR"
assert_no_out "OpenAI" "[bc-no-openai] no qwen-openai check"
assert_no_out "8001" "[bc-no-openai] no port 8001 check"

set_state unpaired none npu-down
run unpaired-hw-fail
assert_rc 1 "$RC" "[bc-unpaired-hw-fail] NPU failure on an unpaired unit"
assert_no_out "READY TO PAIR" "[bc-unpaired-hw-fail] not ready to pair"

set_state paired all npu-up
run paired-ok
assert_rc 0 "$RC" "[bc-paired-ok] paired, all active and listening"
assert_out "ALL SYSTEMS OPERATIONAL" "[bc-paired-ok] reports operational"
assert_no_out "SKIP" "[bc-paired-ok] nothing skipped"
assert_no_out "READY TO PAIR" "[bc-paired-ok] not READY TO PAIR once paired"
assert_no_out "OpenAI" "[bc-no-openai] paired run has no qwen-openai check"
assert_no_out "8001" "[bc-no-openai] paired run has no port 8001 check"

set_state paired arlowe-face npu-up
run paired-fail
assert_rc 1 "$RC" "[bc-paired-fail] arlowe-face inactive"
assert_out "FAIL Face Display Service" "[bc-paired-fail] names the failed unit"

set_state paired all npu-up
run first-boot --first-boot
assert_rc 0 "$RC" "[bc-first-boot-flag] --first-boot accepted"
run bad-flag --bogus
assert_rc 2 "$RC" "[bc-first-boot-flag] unknown flag"

echo "------------------------------------------------------------"
if (( FAILURES != 0 )); then
    echo "${FAILURES} case(s) failed" >&2
    exit 1
fi
echo "boot-check: all cases passed"
