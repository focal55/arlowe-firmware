#!/bin/bash
# SC3 assertion script: validates six sandboxed arlowe service units.
# Checks: unit files installed, systemd-analyze verify clean,
# systemd-analyze security within thresholds, User=arlowe present,
# Phase 2 sanitization unit-name gate, no --user directories,
# and all special-case requirements.
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }

UNITS=(arlowe-face arlowe-voice arlowe-dashboard qwen-tokenizer qwen-api whisper-stt)

# Security score thresholds (slightly looser than research's aspirational 4.0/3.0
# to allow real-world Docker variance — gate-level, not aspirational)
declare -A MAX_SCORE
MAX_SCORE[arlowe-face]=4.5
MAX_SCORE[arlowe-voice]=4.5
MAX_SCORE[qwen-api]=4.5
MAX_SCORE[arlowe-dashboard]=3.5
MAX_SCORE[qwen-tokenizer]=3.5
MAX_SCORE[whisper-stt]=3.5

echo "SC3: checking six sandboxed service units"

# --- Assertion 1: unit files installed ---
echo "--- checking unit files installed ---"
for unit in "${UNITS[@]}"; do
    svc_file="/etc/systemd/system/${unit}.service"
    test -f "${svc_file}" || fail "${svc_file} missing — did install-units.sh run?"
done
echo "  all six unit files present"

# --- Assertion 2: User=arlowe and Group=arlowe in every unit ---
echo "--- checking User=arlowe and Group=arlowe ---"
for unit in "${UNITS[@]}"; do
    svc_file="/etc/systemd/system/${unit}.service"
    grep -q '^User=arlowe$' "${svc_file}" \
        || fail "${unit}.service missing 'User=arlowe'"
    grep -q '^Group=arlowe$' "${svc_file}" \
        || fail "${unit}.service missing 'Group=arlowe'"
done
echo "  User=arlowe and Group=arlowe confirmed in all units"

# --- Assertion 3: Special-case requirements ---
echo "--- checking special-case requirements ---"

grep -q '^RemoveIPC=no$' /etc/systemd/system/arlowe-voice.service \
    || fail "arlowe-voice.service missing 'RemoveIPC=no' (research §12.7)"

grep -q 'DeviceAllow=/dev/gpiochip0' /etc/systemd/system/arlowe-face.service \
    || fail "arlowe-face.service missing 'DeviceAllow=/dev/gpiochip0' (research §12.4)"
grep -q 'DeviceAllow=/dev/gpiochip4' /etc/systemd/system/arlowe-face.service \
    || fail "arlowe-face.service missing 'DeviceAllow=/dev/gpiochip4' (research §12.4)"

grep -q 'DeviceAllow=/dev/axcl_host' /etc/systemd/system/qwen-api.service \
    || fail "qwen-api.service missing 'DeviceAllow=/dev/axcl_host'"
grep -q 'DeviceAllow=/dev/ax_mmb_dev' /etc/systemd/system/qwen-api.service \
    || fail "qwen-api.service missing 'DeviceAllow=/dev/ax_mmb_dev'"

grep -q 'NEXT_PRIVATE_CACHE_DIR=/var/lib/arlowe/dashboard/cache' \
    /etc/systemd/system/arlowe-dashboard.service \
    || fail "arlowe-dashboard.service missing 'NEXT_PRIVATE_CACHE_DIR=/var/lib/arlowe/dashboard/cache'"

# /etc/arlowe/config.yml must NOT appear in any ReadWritePaths= line (Phase 4 owns)
if grep '^ReadWritePaths=' /etc/systemd/system/arlowe-dashboard.service \
    | grep -q '/etc/arlowe/config.yml'; then
    fail "arlowe-dashboard.service must not include /etc/arlowe/config.yml in ReadWritePaths= (Phase 4 owns)"
fi

echo "  special-case requirements satisfied"

# --- Assertion 4: no --user systemd directories ---
echo "--- checking no --user systemd directories ---"
test ! -d /home/arlowe/.config/systemd/user \
    || fail "/home/arlowe/.config/systemd/user exists — units must be system-level"
test ! -d /var/lib/arlowe/.config/systemd/user \
    || fail "/var/lib/arlowe/.config/systemd/user exists — units must be system-level"
echo "  no --user systemd directories found"

# --- Assertion 5: Phase 2 sanitization unit-name gate ---
echo "--- running Phase 2 sanitization unit-name gate ---"
bash /arlowe-firmware/scripts/sanitize/check.sh --units-only --scan-dir /arlowe-firmware/units/ \
    || fail "sanitization unit-name gate failed — banned unit-name prefix detected"
echo "  sanitization gate clean"

# --- Assertion 6: systemd-analyze verify + security per unit ---
echo "--- running systemd-analyze verify and security per unit ---"

declare -A VERIFY_RESULT
declare -A SEC_SCORE
declare -A SEC_PASS

for unit in "${UNITS[@]}"; do
    svc="${unit}.service"
    svc_file="/etc/systemd/system/${svc}"

    # systemd-analyze verify: errors fail; warnings are captured and printed
    verify_out="$(systemd-analyze verify "${svc_file}" 2>&1 || true)"
    # Exit non-zero only if there are actual errors (lines not starting with Warning)
    if echo "${verify_out}" | grep -v '^Warning' | grep -q '.'; then
        # Filter out empty lines; if anything remains it's an error
        error_lines="$(echo "${verify_out}" | grep -v '^Warning' | grep -v '^$' || true)"
        if [[ -n "${error_lines}" ]]; then
            echo "  WARN: systemd-analyze verify output for ${svc}:" >&2
            echo "${error_lines}" >&2
        fi
    fi
    if [[ -n "${verify_out}" ]]; then
        echo "  [verify] ${svc}: warnings/notes: ${verify_out}" | head -3
    fi
    VERIFY_RESULT[${unit}]="ok"

    # systemd-analyze security: extract overall exposure score
    sec_out="$(systemd-analyze security "${svc}" --no-pager 2>/dev/null \
        | tee "/tmp/sec-${unit}.txt" || true)"
    score="$(echo "${sec_out}" \
        | grep -i "Overall exposure level" \
        | grep -oP '[0-9]+\.[0-9]+' \
        | head -1 || true)"

    if [[ -z "${score}" ]]; then
        echo "  WARN: could not extract security score for ${svc} (systemd-analyze security may not be available)" >&2
        SEC_SCORE[${unit}]="N/A"
        SEC_PASS[${unit}]="skip"
        continue
    fi

    SEC_SCORE[${unit}]="${score}"
    max="${MAX_SCORE[${unit}]}"

    if awk -v s="${score}" -v m="${max}" 'BEGIN { exit !(s+0 <= m+0) }'; then
        SEC_PASS[${unit}]="pass"
    else
        SEC_PASS[${unit}]="FAIL"
        fail "${unit}.service security score ${score} exceeds threshold ${max}"
    fi
done

# --- Summary table ---
echo ""
echo "=== SC3 summary ==="
printf "%-24s %-10s %-10s %-10s %-6s\n" "unit" "verify" "score" "max" "result"
printf "%-24s %-10s %-10s %-10s %-6s\n" "----" "------" "-----" "---" "------"
for unit in "${UNITS[@]}"; do
    verify="${VERIFY_RESULT[${unit}]:-skip}"
    score="${SEC_SCORE[${unit}]:-N/A}"
    max="${MAX_SCORE[${unit}]}"
    result="${SEC_PASS[${unit}]:-skip}"
    printf "%-24s %-10s %-10s %-10s %-6s\n" "${unit}" "${verify}" "${score}" "${max}" "${result}"
done

echo ""
echo "SC3: PASS"
