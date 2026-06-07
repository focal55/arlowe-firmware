#!/bin/bash
# Phase 4 assertion: validates the config install shape (stat-only checks).
#
# Asserts:
#   - /etc/arlowe is mode 0770 owner root group arlowe (ADR-0003)
#   - /opt/arlowe/config/schema.yml exists and is owned root:arlowe
#   - /opt/arlowe/config/defaults.yml exists and is owned root:arlowe
#   - /opt/arlowe/runtime/lib/arlowe_config.py exists and is owned root:arlowe
#   - /opt/arlowe/runtime/lib/arlowe_config_validate.py exists and is owned root:arlowe
#   - /etc/arlowe/config.yml does NOT exist (CONFIG-03 factory absence contract)
#
# These are STAT-ONLY shape checks (file existence + mode + owner). The Python
# loader is NOT executed here; validator execution is verified on the provisioned
# Pi/staging unit and in 04-01's repo-root pytest run (runtime/lib/tests/).
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }

check_stat() {
    local path="$1" expected="$2"
    local actual
    actual="$(stat -c '%U:%G %a' "${path}" 2>/dev/null)" \
        || fail "path does not exist: ${path}"
    echo "${actual}" | grep -q "^${expected}$" \
        || fail "${path}: expected '${expected}', got '${actual}'"
}

echo "Phase 4 config install shape assertion"

# /etc/arlowe: root:arlowe 0770 (ADR-0003 loosen-perms decision)
check_stat /etc/arlowe "root:arlowe 770"

# /opt/arlowe/config content files: present and owned root:arlowe
check_stat /opt/arlowe/config/schema.yml   "root:arlowe 640"
check_stat /opt/arlowe/config/defaults.yml "root:arlowe 640"

# Shared loader library: present and owned root:arlowe
check_stat /opt/arlowe/runtime/lib/arlowe_config.py          "root:arlowe 644"
check_stat /opt/arlowe/runtime/lib/arlowe_config_validate.py "root:arlowe 644"

# CONFIG-03 absence contract: config.yml must NOT exist on a factory image
test ! -f /etc/arlowe/config.yml \
    || fail "/etc/arlowe/config.yml must not exist on factory image (CONFIG-03 pairing trigger)"

echo "Phase 4 config install shape: PASS"
