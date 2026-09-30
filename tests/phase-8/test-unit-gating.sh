#!/usr/bin/env bash
# tests/phase-8/test-unit-gating.sh
#
# Static gate: the six runtime units stay down until pairing writes
# /etc/arlowe/config.yml, and nothing shipped still says they ship disabled.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SIX=(arlowe-dashboard arlowe-face arlowe-voice qwen-api qwen-tokenizer whisper-stt)
COND='ConditionPathExists=/etc/arlowe/config.yml'

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$(( FAILURES + 1 )); }

unit_section() {  # unit_section <file>  -> the [Unit] section only
    awk '/^\[/{s=($0=="[Unit]")} s' "$1"
}

for u in "${SIX[@]}"; do
    f="${REPO_ROOT}/units/${u}.service"
    n=$(unit_section "$f" | grep -cxF "$COND")
    if [[ "$n" == 1 ]]; then pass "[gate-six] $u gated on config.yml in [Unit]"
    else bad "[gate-six] $u has $n '$COND' lines in [Unit], expected 1"; fi
    if grep -qxF 'WantedBy=multi-user.target' "$f"; then pass "[gate-six] $u still enabled at build"
    else bad "[gate-six] $u lost WantedBy=multi-user.target"; fi
done

RESET_GUARD='ConditionPathExists=!/var/lib/arlowe/reset-ledger/in-progress'
for u in "${SIX[@]}" arlowe-pair; do
    n=$(unit_section "${REPO_ROOT}/units/${u}.service" | grep -cxF "$RESET_GUARD")
    if [[ "$n" == 1 ]]; then pass "[gate-reset] $u stays down while a reset is in progress"
    else bad "[gate-reset] $u has $n '$RESET_GUARD' lines in [Unit], expected 1"; fi
done

FIRSTBOOT="${REPO_ROOT}/pi-gen/stage-arlowe/03-firstboot/files/arlowe-firstboot.service"
if grep -qE '^TimeoutStartSec=[1-9][0-9]*min$' "$FIRSTBOOT"; then
    pass "[gate-firstboot-timeout] arlowe-firstboot has a finite start timeout"
else
    bad "[gate-firstboot-timeout] arlowe-firstboot needs TimeoutStartSec=<N>min so a hung step cannot hold pairing forever"
fi

if grep -q '^ConditionPathExists' "${REPO_ROOT}/units/arlowe-identity-init.service"; then
    bad "[gate-identity-untouched] arlowe-identity-init.service must never be Condition-gated"
else
    pass "[gate-identity-untouched] arlowe-identity-init.service has no ConditionPathExists"
fi

stale=$(cd "$REPO_ROOT" && grep -rniE \
    'installed[-* ]+but[-* ]+disabled|ship(s)? disabled|disabled by design' \
    units pi-gen/stage-arlowe provision docs/operations/phase-7.1-substrate.md)
if [[ -n "$stale" ]]; then
    bad "[gate-no-stale-comment] still claims the units ship disabled:"
    printf '     %s\n' "$stale" >&2
else
    pass "[gate-no-stale-comment] no comment claims the six ship disabled"
fi

if command -v systemd-analyze >/dev/null 2>&1; then
    for u in "${SIX[@]}"; do
        # Missing ExecStart binaries are expected off-device; only a complaint
        # about the condition itself is in scope here.
        out=$(systemd-analyze verify "${REPO_ROOT}/units/${u}.service" 2>&1 | grep -i 'condition')
        if [[ -z "$out" ]]; then pass "[gate-verify] $u condition parses"
        else bad "[gate-verify] $u: $out"; fi
    done
else
    echo "SKIP: [gate-verify] systemd-analyze not installed"
fi

echo "------------------------------------------------------------"
if (( FAILURES != 0 )); then
    echo "${FAILURES} case(s) failed" >&2
    exit 1
fi
echo "unit-gating: all cases passed"
