#!/usr/bin/env bash
# Factory-reset units: one template instance per trigger, plus the boot-time resume.
# The helpers below are invoked through check "$@", which shellcheck cannot see.
# shellcheck disable=SC2329
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TPL="${REPO_ROOT}/units/arlowe-factory-reset@.service"
RES="${REPO_ROOT}/units/arlowe-factory-reset-resume.service"
POLKIT="${REPO_ROOT}/provision/polkit/50-arlowe-systemctl.rules"
EXEC="ExecStart=/usr/bin/python3 /opt/arlowe/runtime/cli/factory-reset"
fails=0
check() { local name=$1; shift; if "$@"; then echo "PASS $name"; else echo "FAIL $name"; fails=1; fi; }
has() { [[ -f "$1" ]] && grep -qxF -- "$2" "$1"; }
lacks() { [[ -f "$1" ]] && ! grep -Eq -- "$2" "$1"; }
before() { sed -n 's/^Before=//p' "$RES" 2>/dev/null | tr ' ' '\n' | grep -qxF "$1"; }
# The rule grants any unit whose name starts with one of its indexOf(...) === 0 prefixes.
polkit_allows() {
    local p
    while read -r p; do
        [[ -n "$p" && "$1" == "$p"* ]] && return 0
    done < <(grep -o 'indexOf("[^"]*") === 0' "$POLKIT" | cut -d'"' -f2)
    return 1
}

check "template passes its instance as the trigger" has "$TPL" "$EXEC --trigger %i"
check "resume unit runs --resume" has "$RES" "$EXEC --resume"
for u in "$TPL" "$RES"; do
    n=$(basename "$u")
    check "$n sets the broker file" has "$u" "Environment=ARLOWE_BROKER_FILE=/boot/firmware/arlowe-broker.json"
    check "$n runs as root" lacks "$u" "^User="
    check "$n sets no global CA override" lacks "$u" "REQUESTS_CA_BUNDLE|CURL_CA_BUNDLE|SSL_CERT_FILE"
    check "$n keeps /etc writable" has "$u" "ProtectSystem=yes"
done
check "template is not enabled at boot" lacks "$TPL" '^\[Install\]'
check "resume is conditional on the marker" \
    has "$RES" "ConditionPathExists=/var/lib/arlowe/reset-ledger/in-progress"
check "resume is enabled at boot" has "$RES" "WantedBy=multi-user.target"
for s in arlowe-pair arlowe-dashboard arlowe-face arlowe-voice qwen-api qwen-tokenizer whisper-stt; do
    check "resume runs before $s" before "$s.service"
done
for inst in dashboard button; do
    check "polkit lets arlowe start arlowe-factory-reset@$inst.service" \
        polkit_allows "arlowe-factory-reset@$inst.service"
done
exit "$fails"
