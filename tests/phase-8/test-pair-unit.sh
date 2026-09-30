#!/usr/bin/env bash
# Static gate for arlowe-pair.service: runs only when unpaired, least privilege,
# no Conflicts= with the face, and the reset triggers can reach systemd.
# The helpers below are invoked through check "$@", which shellcheck cannot see.
# shellcheck disable=SC2317,SC2329
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PAIR="${REPO_ROOT}/units/arlowe-pair.service"
FACE="${REPO_ROOT}/units/arlowe-face.service"
DASH="${REPO_ROOT}/units/arlowe-dashboard.service"
fails=0
check() { local name=$1; shift; if "$@"; then echo "PASS $name"; else echo "FAIL $name"; fails=1; fi; }
has() { [[ -f "$1" ]] && grep -qxF -- "$2" "$1"; }
lacks() { [[ -f "$1" ]] && ! grep -Eq -- "$2" "$1"; }
# values <file> <key>: every value of a (possibly repeated, space-separated) key, one per line, sorted
values() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tr ' ' '\n' | sed '/^$/d' | sort; }
lines() { grep "^$2=" "$1" 2>/dev/null; }
in_values() { values "$1" "$2" | grep -qxF -- "$3"; }
same_lines() { [[ -f "$1" && -f "$2" ]] && [[ "$(lines "$1" "$3")" == "$(lines "$2" "$3")" ]]; }
exact_values() { local f=$1 k=$2; shift 2; [[ "$(values "$f" "$k")" == "$(printf '%s\n' "$@" | sort)" ]]; }

check "gated on an absent config.yml" has "$PAIR" "ConditionPathExists=!/etc/arlowe/config.yml"
for dep in arlowe-identity-init arlowe-firstboot NetworkManager arlowe-radio-init arlowe-factory-reset-resume; do
    check "ordered after $dep" in_values "$PAIR" After "$dep.service"
done
check "requires radio-init" in_values "$PAIR" Requires arlowe-radio-init.service
check "does not require identity-init" lacks "$PAIR" "^Requires=.*arlowe-identity-init"
check "no Conflicts= line" lacks "$PAIR" "^Conflicts="
check "runs as arlowe" has "$PAIR" "User=arlowe"
check "ambient CAP_NET_BIND_SERVICE" has "$PAIR" "AmbientCapabilities=CAP_NET_BIND_SERVICE"
check "bounding set is CAP_NET_BIND_SERVICE only" has "$PAIR" "CapabilityBoundingSet=CAP_NET_BIND_SERVICE"
check "no new privileges" has "$PAIR" "NoNewPrivileges=yes"
check "runs python3 -m pair" has "$PAIR" "ExecStart=/usr/bin/python3 -m pair"
check "PYTHONPATH covers runtime and runtime/lib" \
    has "$PAIR" "Environment=PYTHONPATH=/opt/arlowe/runtime:/opt/arlowe/runtime/lib"
check "sets no global CA override" lacks "$PAIR" "^[^#]*(REQUESTS_CA_BUNDLE|CURL_CA_BUNDLE|SSL_CERT_FILE)"
check "DeviceAllow= identical to the face" same_lines "$PAIR" "$FACE" DeviceAllow
check "Whisplay groups" has "$PAIR" "SupplementaryGroups=gpio spi video"
check "SystemCallFilter= identical to the face" same_lines "$PAIR" "$FACE" SystemCallFilter
check "re-admits mbind" has "$PAIR" "SystemCallFilter=mbind"
check "writes only the paths pairing writes" exact_values "$PAIR" ReadWritePaths \
    /etc/arlowe /var/lib/arlowe/identity /var/lib/arlowe/dashboard
check "runtime directory is arlowe-pair" has "$PAIR" "RuntimeDirectory=arlowe-pair"
check "CWD is the runtime directory" has "$PAIR" "WorkingDirectory=/run/arlowe-pair"
check "restarts only on failure (exit 0 is the paired handoff)" has "$PAIR" "Restart=on-failure"
check "enabled at build" has "$PAIR" "WantedBy=multi-user.target"

# The reset triggers run `systemctl start` over D-Bus from inside their sandboxes.
for u in "$PAIR" "$FACE" "$DASH"; do
    check "$(basename "$u") can reach D-Bus (AF_UNIX)" in_values "$u" RestrictAddressFamilies AF_UNIX
done

if command -v systemd-analyze >/dev/null 2>&1; then
    # Missing ExecStart targets and users are expected off-device.
    out=$(systemd-analyze verify "$PAIR" 2>&1 | grep -viE 'not executable|no such file|user|group|arlowe-(identity-init|firstboot|radio-init|factory-reset-resume)')
    check "systemd-analyze verify is clean" test -z "$out"
    [[ -n "$out" ]] && printf '     %s\n' "$out"
else
    echo "SKIP systemd-analyze not installed"
fi
exit "$fails"
