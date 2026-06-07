#!/bin/bash
# Phase 3 plan 05 staging harness. Runs on the Mac; drives the dev Pi over SSH.
# Installs the arlowe-staging environment, re-runs the SC1/SC2 assertions against
# it (via env override — no edits to those scripts), runs SC4 + the speculative
# hardware probe, and captures the observed run. Tear-down is a separate explicit
# step (printed at the end) so you can inspect the live system first.
#
# Each phase's exit code is captured and reported but does NOT abort the run: this
# is a human-verified harness, so it surfaces every result rather than stopping at
# the first expected divergence (e.g. SC1's founder-absence check, which is image-
# only and cannot pass on the founder's own dev Pi — see docs/operations).
#
# Prereq: SSH alias 'arlowe-1' with key auth.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SSH_HOST="${ARLOWE_STAGING_HOST:-arlowe-1}"
REMOTE=/tmp/arlowe-firmware
OBSERVED="$REPO_ROOT/.planning/phases/03-service-user-and-filesystem-layout/staging-observed-run.txt"

echo "=== Phase 3 plan 05 staging harness -> $SSH_HOST ==="
ssh -o ConnectTimeout=5 -o BatchMode=yes "$SSH_HOST" 'hostname && uname -m && systemctl --version | head -1' \
    || { echo "Cannot reach $SSH_HOST over SSH. Check your SSH config." >&2; exit 1; }

echo "=== syncing repo to $SSH_HOST:$REMOTE ==="
rsync -az --delete \
    --exclude '.git' --exclude 'node_modules' --exclude '__pycache__' \
    --exclude 'runtime/dashboard/.next' \
    "$REPO_ROOT/" "$SSH_HOST:$REMOTE/" \
    || { echo "rsync to $SSH_HOST failed." >&2; exit 1; }

phase() { echo ""; echo "=== $1 ==="; }

{
    echo "### staging observed run ###"
    echo "host: $SSH_HOST"

    phase "install"
    ssh "$SSH_HOST" "sudo bash $REMOTE/scripts/provision/install-arlowe-on-arlowe1-staging.sh"
    echo "[install exit=$?]"

    phase "SC1 + SC2 assertions (env-overridden to the staging tree)"
    ssh "$SSH_HOST" "
        export ARLOWE_USER=arlowe-staging ARLOWE_GROUP=arlowe-staging
        export ARLOWE_HOME=/var/lib/arlowe-staging ARLOWE_OPT=/opt/arlowe-staging ARLOWE_ETC=/etc/arlowe-staging
        for a in $REMOTE/tests/phase-3/assertions/01-user-shape.sh $REMOTE/tests/phase-3/assertions/02-fs-layout.sh; do
            echo \"--- \$a ---\"; sudo -E bash \"\$a\"; echo \"[exit=\$?]\"
        done
    "

    phase "SC4 sandbox write-deny"
    ssh "$SSH_HOST" "sudo bash $REMOTE/tests/phase-3/staging/06-sandbox-write-deny.sh"
    echo "[06 exit=$?]"

    phase "speculative hardware probe"
    ssh "$SSH_HOST" "sudo bash $REMOTE/tests/phase-3/staging/07-hardware-speculative.sh"
    echo "[07 exit=$?]"
} 2>&1 | tee "$OBSERVED"

cat <<EOF

=== staging run complete ===
Observed run captured at: $OBSERVED

Review it, then TEAR DOWN:
  ssh $SSH_HOST 'sudo bash $REMOTE/scripts/provision/uninstall-arlowe-on-arlowe1-staging.sh'

Verify clean:
  ssh $SSH_HOST 'id arlowe-staging 2>&1; ls /etc/systemd/system/*-staging.service 2>&1 | head'

Then fold findings into docs/operations/phase-3-staging.md + 03-05-SUMMARY.md.
EOF
