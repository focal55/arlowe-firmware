#!/bin/bash
# SC1 assertion script: validates the arlowe system user shape.
# Env-var-driven so plan 03-05's staging harness can re-target without edits:
#   ARLOWE_USER=arlowe-staging bash tests/phase-3/assertions/01-user-shape.sh
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }

ARLOWE_USER="${ARLOWE_USER:-arlowe}"
ARLOWE_GROUP="${ARLOWE_GROUP:-${ARLOWE_USER}}"
ARLOWE_HOME="${ARLOWE_HOME:-/var/lib/${ARLOWE_USER}}"

echo "SC1: checking user shape for ${ARLOWE_USER} (HOME=${ARLOWE_HOME})"

# uid must be < 1000 (system user range on Debian: SYS_UID_MIN..SYS_UID_MAX = 100..999)
uid="$(id -u "${ARLOWE_USER}" 2>/dev/null)" || fail "${ARLOWE_USER} user does not exist"
test "${uid}" -lt 1000 || fail "${ARLOWE_USER} is not a system user (uid=${uid} >= 1000)"

# HOME must match expected path
actual_home="$(getent passwd "${ARLOWE_USER}" | cut -d: -f6)"
test "${actual_home}" = "${ARLOWE_HOME}" || fail "HOME wrong: expected ${ARLOWE_HOME}, got ${actual_home}"

# shell must be nologin
actual_shell="$(getent passwd "${ARLOWE_USER}" | cut -d: -f7)"
test "${actual_shell}" = "/usr/sbin/nologin" || fail "shell wrong: expected /usr/sbin/nologin, got ${actual_shell}"

# required supplementary groups (dialout + video dropped per plan 03-05 — confirmed
# unused on hardware; founder-absence moved to 06-image-sanitization.sh so this
# script is reusable against a dev Pi via ARLOWE_USER override)
id -nG "${ARLOWE_USER}" | grep -qw audio || fail "${ARLOWE_USER} missing audio group"
id -nG "${ARLOWE_USER}" | grep -qw gpio  || fail "${ARLOWE_USER} missing gpio group"
id -nG "${ARLOWE_USER}" | grep -qw spi   || fail "${ARLOWE_USER} missing spi group"

echo "SC1: PASS"
