#!/bin/bash
# SC4 (real-hardware): under the production sandbox directives, arlowe-staging
# cannot write outside its own /var/lib/arlowe-staging/ tree. Verified against the
# actual systemd on the dev Pi via systemd-run (the Docker testbed could only
# validate this synthetically).
#
# Run on the dev Pi as root, after the staging install has run.
set -uo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }

SVC_USER=arlowe-staging
RWPATH=/var/lib/arlowe-staging/logs/face

id "$SVC_USER" >/dev/null 2>&1 || fail "$SVC_USER not present — run the staging install first"
[[ -d "$RWPATH" ]] || fail "$RWPATH missing — staging fs layout not provisioned"

# Production sandbox directives mirrored from the shipping units.
SANDBOX=(-p ProtectSystem=strict -p ProtectHome=yes -p NoNewPrivileges=yes
         -p PrivateTmp=yes -p "ReadWritePaths=$RWPATH")

attempt() { # attempt <path> -> prints command output, exits with touch's status
    systemd-run --uid="$SVC_USER" --gid="$SVC_USER" --pipe --wait -q \
        "${SANDBOX[@]}" /bin/sh -c "touch '$1'" 2>&1
}

# Positive: the declared ReadWritePaths target must be writable.
if out=$(attempt "$RWPATH/positive-test"); then
    rm -f "$RWPATH/positive-test"
    echo "  positive: write to $RWPATH OK"
else
    fail "positive write to declared RW path denied: ${out:-<no output>}"
fi

# Negative: every path outside the sandbox must be denied. A successful write here
# is a catastrophic sandbox failure; /home/focal55 is the founder home and must
# NEVER be reachable from a service account.
for target in /opt/arlowe-staging/runtime/voice/neg /etc/neg /root/neg /home/focal55/neg; do
    if out=$(attempt "$target"); then
        fail "sandbox ALLOWED write to $target — SC4 enforcement broken"
    fi
    echo "  negative: $target denied (${out##*: })"
done

echo "[06-sandbox-write-deny] PASS (1 positive + 4 negative against real systemd)"
