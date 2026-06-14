#!/usr/bin/env bash
# scripts/dev-deploy.sh
#
# Rsync runtime/ to a target Pi and restart affected arlowe-* units over SSH.
# Mirrors the SSH/host conventions of scripts/dev-pull-from-pi.sh.
#
# This script does NOT reflash. It is the fast dev-iteration path — push a
# changed runtime file and bounce the affected unit in seconds.
#
# Usage:
#   scripts/dev-deploy.sh [--target <host>] [--units <unit,...>] [--dry-run]
#
# Examples:
#   scripts/dev-deploy.sh
#   scripts/dev-deploy.sh --target pi-dev
#   scripts/dev-deploy.sh --units arlowe-voice,arlowe-face
#   scripts/dev-deploy.sh --dry-run
#
# The default target host is configurable via the DEV_TARGET env var or the
# --target flag. The host must be reachable via SSH key auth (same user that
# runs this script, or set REMOTE_USER).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Default target — can be overridden with --target or the DEV_TARGET env var.
# Uses a generic default so the banlist does not trip on a literal hostname.
REMOTE="${DEV_TARGET:-arlowe-dev}"
REMOTE_USER="${REMOTE_USER:-}"
DRY_RUN=false
UNITS_OVERRIDE=""

# All arlowe-* units that may be affected by a runtime/ change.
# Order matters: restart voice last (it depends on stt/llm).
DEFAULT_UNITS=(
    whisper-stt
    qwen-api
    qwen-tokenizer
    arlowe-face
    arlowe-dashboard
    arlowe-voice
)

usage() {
    cat <<EOF
Usage: $(basename "$0") [--target <host>] [--units <unit,...>] [--dry-run] [-h|--help]

Rsync runtime/ to the target Pi and restart affected arlowe-* units.

Options:
  --target <host>    SSH host alias or IP (default: \$DEV_TARGET or arlowe-dev)
  --units <unit,...> Comma-separated list of units to restart (default: all arlowe-*)
  --dry-run          Print what would happen without running rsync or systemctl
  -h, --help         Show this message and exit

Environment:
  DEV_TARGET    Default SSH target host (overridden by --target)
  REMOTE_USER   SSH user (default: same as local user)
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            [[ $# -ge 2 ]] || { echo "dev-deploy: --target requires a value" >&2; exit 1; }
            REMOTE="$2"; shift 2 ;;
        --units)
            [[ $# -ge 2 ]] || { echo "dev-deploy: --units requires a value" >&2; exit 1; }
            UNITS_OVERRIDE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "dev-deploy: unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

# Build the SSH target string.
if [[ -n "${REMOTE_USER}" ]]; then
    SSH_TARGET="${REMOTE_USER}@${REMOTE}"
else
    SSH_TARGET="${REMOTE}"
fi

# Build the units list.
if [[ -n "${UNITS_OVERRIDE}" ]]; then
    IFS=',' read -ra UNITS <<< "${UNITS_OVERRIDE}"
else
    UNITS=("${DEFAULT_UNITS[@]}")
fi

# ---------------------------------------------------------------------------
# Dry-run prefix
# ---------------------------------------------------------------------------
DRY=""
if "${DRY_RUN}"; then
    DRY="--dry-run"
    echo "[dry-run] No files will be written and no units will be restarted."
fi

# ---------------------------------------------------------------------------
# Step 1: rsync runtime/ to the target
# ---------------------------------------------------------------------------
RUNTIME_SRC="${REPO_ROOT}/runtime/"
# shellcheck disable=SC2088
# Tilde must be expanded by the remote shell, not locally.
RUNTIME_DST='~/runtime/'

echo ""
echo "--- Syncing runtime/ to ${SSH_TARGET}:${RUNTIME_DST}"

# shellcheck disable=SC2086
rsync -avz --delete ${DRY} \
    -e "ssh -o StrictHostKeyChecking=accept-new" \
    "${RUNTIME_SRC}" \
    "${SSH_TARGET}:${RUNTIME_DST}"

# ---------------------------------------------------------------------------
# Step 2: restart affected arlowe-* units on the target
# ---------------------------------------------------------------------------
echo ""
echo "--- Restarting units on ${SSH_TARGET}"

if "${DRY_RUN}"; then
    for unit in "${UNITS[@]}"; do
        printf '[dry-run] would run: ssh %s sudo systemctl restart %s\n' "${SSH_TARGET}" "${unit}"
    done
else
    for unit in "${UNITS[@]}"; do
        printf 'Restarting %s...\n' "${unit}"
        # Treat a missing unit as a warning, not a fatal error — not all units
        # may be active on a partial dev image.
        if ! ssh -o StrictHostKeyChecking=accept-new "${SSH_TARGET}" \
                "sudo systemctl restart ${unit}" 2>/dev/null; then
            printf '[WARN] %s: restart failed or unit not found — skipping\n' "${unit}" >&2
        else
            printf 'OK    %s\n' "${unit}"
        fi
    done
fi

echo ""
if "${DRY_RUN}"; then
    echo "[dry-run] Done. Re-run without --dry-run to apply."
else
    echo "Deploy complete to ${SSH_TARGET}."
fi
