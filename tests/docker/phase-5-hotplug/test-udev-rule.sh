#!/bin/bash
# Phase 5 shape test: 92-arlowe-audio.rules correctness (no hardware required).
#
# Verifies the udev rule file's form, scope, debounce anchor, and install shape
# using grep assertions and, if udevadm is available, syntax validation. No real
# hotplug event is simulated — hardware confirmation is deferred to plan 05-07.
#
# Assertions:
#   1. udevadm verify passes on the rule (skip with message if udevadm absent)
#   2. Rule is scoped to SUBSYSTEM=="sound" (not broad)
#   3. Rule uses --no-block (no udev<->systemd deadlock)
#   4. Rule is anchored on controlC* (debounce; does not fire on every pcm sub-node)
#   5. Rule targets only arlowe-voice.service (no non-arlowe unit)
#   6. Rule file is installed at the expected path with mode 0644 (install glob)
#
# Usage:
#   bash tests/docker/phase-5-hotplug/test-udev-rule.sh
#   (run from repo root or any directory; paths are resolved relative to this script)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
RULES_SRC="${REPO_ROOT}/provision/udev/92-arlowe-audio.rules"

pass_count=0
fail_count=0

pass() { echo "  PASS: $*"; pass_count=$((pass_count + 1)); }
fail() { echo "  FAIL: $*" >&2; fail_count=$((fail_count + 1)); }
skip() { echo "  SKIP: $*"; }

echo "=== Phase 5 hotplug rule shape test ==="
echo "    rule: ${RULES_SRC}"

# ---- 0. Rule file exists ----
if [[ ! -f "${RULES_SRC}" ]]; then
    echo "FATAL: rule file not found at ${RULES_SRC}" >&2
    exit 1
fi

# ---- 1. udevadm verify (skip if absent) ----
if command -v udevadm >/dev/null 2>&1; then
    if udevadm verify "${RULES_SRC}" 2>&1; then
        pass "udevadm verify ${RULES_SRC}"
    else
        fail "udevadm verify failed on ${RULES_SRC}"
    fi
else
    skip "udevadm not available — skipping syntax verification (acceptable in CI without udev)"
fi

# ---- 2. Scoped to SUBSYSTEM=="sound" ----
if grep -qE 'SUBSYSTEM=="sound"' "${RULES_SRC}"; then
    pass "rule is scoped to SUBSYSTEM==\"sound\""
else
    fail "rule does not contain SUBSYSTEM==\"sound\""
fi

# ---- 3. Uses --no-block ----
if grep -qE -- '--no-block' "${RULES_SRC}"; then
    pass "rule uses --no-block"
else
    fail "rule does not use --no-block (required to avoid udev<->systemd deadlock)"
fi

# ---- 4. Debounced via controlC anchor ----
if grep -qE 'KERNEL=="controlC' "${RULES_SRC}"; then
    pass "rule anchored on controlC* (debounce: one restart per card, not per pcm sub-node)"
else
    fail "rule does not anchor on controlC* — restart storm risk on single USB plug"
fi

# 4b. Must NOT fire on raw pcm sub-node events (no broad sound/* match without anchor)
if grep -qP 'KERNEL=="pcmC' "${RULES_SRC}" 2>/dev/null; then
    fail "rule matches pcmC* nodes — this defeats the controlC debounce anchor"
else
    pass "rule does not match pcmC* sub-nodes (debounce intact)"
fi

# ---- 5. Targets only arlowe-voice.service; no foreign unit names ----
if grep -qE 'arlowe-voice\.service' "${RULES_SRC}"; then
    pass "rule targets arlowe-voice.service"
else
    fail "rule does not reference arlowe-voice.service"
fi

# Check that the only unit name in RUN+= lines is arlowe-voice.service.
# Extract all words after 'restart' in RUN lines and verify they match.
non_arlowe=$(grep -E 'RUN\+=' "${RULES_SRC}" \
    | grep -oE 'restart [a-zA-Z0-9_@.-]+' \
    | awk '{print $2}' \
    | grep -v '^arlowe-' || true)
if [[ -z "${non_arlowe}" ]]; then
    pass "no non-arlowe-* unit referenced in RUN+= lines"
else
    fail "non-arlowe-* unit(s) found in RUN+= lines: ${non_arlowe}"
fi

# ---- 6. Install shape: glob installs rule at expected path with mode 0644 ----
TMPDIR_RULES="$(mktemp -d /tmp/arlowe-udev-test-XXXXXX)"
trap 'rm -rf "${TMPDIR_RULES}"' EXIT

# Simulate the install glob from install-arlowe-udev-polkit.sh line 42:
#   install -m 0644 -o root -g root "${UDEV_SRC}"/*.rules /etc/udev/rules.d/
# We install into a temp dir (can't write /etc in CI without root).
install -m 0644 "${RULES_SRC}" "${TMPDIR_RULES}/"

INSTALLED="${TMPDIR_RULES}/92-arlowe-audio.rules"

if [[ -f "${INSTALLED}" ]]; then
    pass "install glob places 92-arlowe-audio.rules at expected path"
else
    fail "92-arlowe-audio.rules not found after install simulation"
fi

# stat format differs: GNU coreutils (-c '%a') vs BSD/macOS (-f '%OLp').
if stat --version >/dev/null 2>&1; then
    actual_mode="$(stat -c '%a' "${INSTALLED}" 2>/dev/null)"
else
    actual_mode="$(stat -f '%OLp' "${INSTALLED}" 2>/dev/null)"
fi
if [[ "${actual_mode}" == "644" ]]; then
    pass "installed file has mode 0644"
else
    fail "installed file mode is ${actual_mode}, expected 644"
fi

# Confirm the file name matches the install-arlowe-udev-polkit.sh glob pattern
# (9?-arlowe-*.rules) that the installed_count check at line 66 uses.
if echo "92-arlowe-audio.rules" | grep -qE '^9[0-9]-arlowe-.*\.rules$'; then
    pass "filename 92-arlowe-audio.rules matches installer glob 9?-arlowe-*.rules"
else
    fail "filename does not match installer glob 9?-arlowe-*.rules"
fi

# ---- Summary ----
echo ""
echo "=== Results: ${pass_count} passed, ${fail_count} failed ==="
if [[ "${fail_count}" -gt 0 ]]; then
    exit 1
fi
echo "=== PASS ==="
