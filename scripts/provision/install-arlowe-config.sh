#!/bin/bash
# Installs schema.yml, defaults.yml, and the shared config loader library into
# the image. Does NOT create /etc/arlowe/config.yml — its absence is the
# CONFIG-03 pairing trigger (Phase 8 creates it on first pairing).
#
# Destination layout (mirrors what units expect at runtime):
#   /opt/arlowe/config/schema.yml         root:arlowe 0640  (read-only at runtime)
#   /opt/arlowe/config/defaults.yml       root:arlowe 0640  (read-only at runtime)
#   /opt/arlowe/runtime/lib/              root:arlowe 0755  (directory; created here)
#   /opt/arlowe/runtime/lib/*.py          root:arlowe 0644  (every module in runtime/lib)
#
# Units import the loader with PYTHONPATH=/opt/arlowe/runtime/lib as flat modules:
#   from arlowe_config import load
#   python -m arlowe_config_validate   (ExecStartPre validator)
#
# Idempotency: install(1) sets owner and mode on each invocation — safe to re-run.
# Must be run as root. Requires install-arlowe-user.sh and install-arlowe-fs.sh
# to have run first (arlowe user and /opt/arlowe/config directory must exist).
set -euo pipefail

# Resolve repo root relative to this script so it works both on the Pi (cloned
# checkout) and inside the Docker testbed (bind-mounted at /arlowe-firmware).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Verify prerequisite: arlowe user must exist.
getent passwd arlowe >/dev/null 2>&1 \
    || { echo "[install-arlowe-config] ERROR: arlowe user not found; run install-arlowe-user.sh first" >&2; exit 1; }

# Verify prerequisite: /opt/arlowe/config directory must exist (install-arlowe-fs.sh owns it).
[[ -d /opt/arlowe/config ]] \
    || { echo "[install-arlowe-config] ERROR: /opt/arlowe/config not found; run install-arlowe-fs.sh first" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Config content: schema.yml + defaults.yml → /opt/arlowe/config/
# ---------------------------------------------------------------------------

install -o root -g arlowe -m 0640 \
    "${REPO_ROOT}/config/schema.yml" /opt/arlowe/config/schema.yml

install -o root -g arlowe -m 0640 \
    "${REPO_ROOT}/config/defaults.yml" /opt/arlowe/config/defaults.yml

# ---------------------------------------------------------------------------
# Shared loader library → /opt/arlowe/runtime/lib/
# ---------------------------------------------------------------------------

install -d -o root -g arlowe -m 0755 /opt/arlowe/runtime/lib

# Glob rather than an explicit list: adding a module must not require editing the
# installer. An install list that drifted from reality has already bitten this
# repo once (F7 #21, install-arlowe-cli.sh). runtime/lib/tests/ is a directory, so
# *.py does not pick up test files. The guard below fails loudly if the glob
# matches nothing, which would otherwise ship a lib directory with no modules.
shopt -s nullglob
LIB_MODULES=("${REPO_ROOT}"/runtime/lib/*.py)
shopt -u nullglob

[[ ${#LIB_MODULES[@]} -gt 0 ]] \
    || { echo "[install-arlowe-config] ERROR: no modules matched ${REPO_ROOT}/runtime/lib/*.py" >&2; exit 1; }

for module in "${LIB_MODULES[@]}"; do
    install -o root -g arlowe -m 0644 "$module" "/opt/arlowe/runtime/lib/$(basename "$module")"
done

# ---------------------------------------------------------------------------
# Absence contract: /etc/arlowe/config.yml must NOT be created here.
# Its absence is the CONFIG-03 factory-image pairing trigger.
# Phase 8 creates it on first pairing.
# ---------------------------------------------------------------------------

echo "[install-arlowe-config] config content installed"
