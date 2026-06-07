#!/bin/bash
# SC2 assertion script: validates the arlowe filesystem layout ownership and modes.
# Env-var-driven so plan 03-05's staging harness can re-target without edits:
#   ARLOWE_USER=arlowe-staging bash tests/phase-3/assertions/02-fs-layout.sh
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }

ARLOWE_USER="${ARLOWE_USER:-arlowe}"
ARLOWE_GROUP="${ARLOWE_GROUP:-${ARLOWE_USER}}"
ARLOWE_HOME="${ARLOWE_HOME:-/var/lib/${ARLOWE_USER}}"
ARLOWE_OPT="${ARLOWE_OPT:-/opt/${ARLOWE_USER}}"
ARLOWE_ETC="${ARLOWE_ETC:-/etc/${ARLOWE_USER}}"

echo "SC2: checking filesystem layout (OPT=${ARLOWE_OPT}, HOME=${ARLOWE_HOME}, ETC=${ARLOWE_ETC})"

check_path() {
  local path="$1" expected_stat="$2"
  local actual
  actual="$(stat -c '%U:%G %a' "${path}" 2>/dev/null)" || fail "path does not exist: ${path}"
  echo "${actual}" | grep -q "^${expected_stat}$" || fail "${path}: expected '${expected_stat}', got '${actual}'"
}

# /opt/arlowe tree — root:arlowe owned, read-only at runtime
check_path "${ARLOWE_OPT}"                "root:${ARLOWE_GROUP} 750"
check_path "${ARLOWE_OPT}/runtime"        "root:${ARLOWE_GROUP} 755"
check_path "${ARLOWE_OPT}/runtime/voice"  "root:${ARLOWE_GROUP} 755"
check_path "${ARLOWE_OPT}/runtime/face"   "root:${ARLOWE_GROUP} 755"
check_path "${ARLOWE_OPT}/runtime/stt"    "root:${ARLOWE_GROUP} 755"
check_path "${ARLOWE_OPT}/runtime/tts"    "root:${ARLOWE_GROUP} 755"
check_path "${ARLOWE_OPT}/runtime/llm"    "root:${ARLOWE_GROUP} 755"
check_path "${ARLOWE_OPT}/runtime/dashboard" "root:${ARLOWE_GROUP} 755"
check_path "${ARLOWE_OPT}/runtime/wake-word" "root:${ARLOWE_GROUP} 755"
check_path "${ARLOWE_OPT}/runtime/cli"    "root:${ARLOWE_GROUP} 755"
check_path "${ARLOWE_OPT}/third_party"    "root:${ARLOWE_GROUP} 755"
check_path "${ARLOWE_OPT}/models"         "root:${ARLOWE_GROUP} 755"
check_path "${ARLOWE_OPT}/venvs"          "root:${ARLOWE_GROUP} 755"

# /opt/arlowe/config: parent dir exists (root:arlowe 0755); defaults.yml is ABSENT
# Phase 4 owns the file content — plan 03-01 only reserves the parent directory.
check_path "${ARLOWE_OPT}/config" "root:${ARLOWE_GROUP} 755"
test ! -f "${ARLOWE_OPT}/config/defaults.yml" \
  || fail "${ARLOWE_OPT}/config/defaults.yml must not exist in Phase 3 (Phase 4 owns content)"

# /var/lib/arlowe tree — arlowe:arlowe owned, writable state
check_path "${ARLOWE_HOME}"                   "${ARLOWE_USER}:${ARLOWE_GROUP} 750"
check_path "${ARLOWE_HOME}/logs"              "${ARLOWE_USER}:${ARLOWE_GROUP} 750"
check_path "${ARLOWE_HOME}/logs/voice"        "${ARLOWE_USER}:${ARLOWE_GROUP} 750"
check_path "${ARLOWE_HOME}/logs/face"         "${ARLOWE_USER}:${ARLOWE_GROUP} 750"
check_path "${ARLOWE_HOME}/logs/stt"          "${ARLOWE_USER}:${ARLOWE_GROUP} 750"
check_path "${ARLOWE_HOME}/logs/tts"          "${ARLOWE_USER}:${ARLOWE_GROUP} 750"
check_path "${ARLOWE_HOME}/logs/llm"          "${ARLOWE_USER}:${ARLOWE_GROUP} 750"
check_path "${ARLOWE_HOME}/logs/dashboard"    "${ARLOWE_USER}:${ARLOWE_GROUP} 750"
check_path "${ARLOWE_HOME}/conversations"     "${ARLOWE_USER}:${ARLOWE_GROUP} 700"
check_path "${ARLOWE_HOME}/identity"          "${ARLOWE_USER}:${ARLOWE_GROUP} 700"
check_path "${ARLOWE_HOME}/state"             "${ARLOWE_USER}:${ARLOWE_GROUP} 750"
check_path "${ARLOWE_HOME}/wake-word"         "${ARLOWE_USER}:${ARLOWE_GROUP} 750"
check_path "${ARLOWE_HOME}/dashboard/cache"   "${ARLOWE_USER}:${ARLOWE_GROUP} 750"

# /etc/arlowe: directory exists but config.yml is ABSENT
# Mode is 0770 (root:arlowe group-writable) per ADR-0003 (plan 04-02).
# Absence of config.yml is the CONFIG-03 pairing trigger (Phase 8 creates it).
check_path "${ARLOWE_ETC}" "root:${ARLOWE_GROUP} 770"
test ! -f "${ARLOWE_ETC}/config.yml" \
  || fail "${ARLOWE_ETC}/config.yml must not exist in Phase 3 (its absence triggers pairing)"

# /var/lib/arlowe/.ssh must NOT exist — Phase 10 owns this path.
test ! -d "${ARLOWE_HOME}/.ssh" \
  || fail "${ARLOWE_HOME}/.ssh must not exist in Phase 3 (Phase 10 creates at support-mode activation)"

# identity mode must be exactly 0700 (sensitive PKI store, Phase 7)
identity_mode="$(stat -c '%a' "${ARLOWE_HOME}/identity")"
test "${identity_mode}" = "700" \
  || fail "${ARLOWE_HOME}/identity mode is ${identity_mode}, expected 700"

echo "SC2: PASS"
