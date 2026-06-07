#!/bin/bash
# Image-only sanitization assertion: the founder identity must NOT be present on a
# shipped image. Split out of 01-user-shape.sh (plan 03-05) because that check is
# inherently false on the founder's own dev Pi, which broke 01's reuse by the
# staging harness. This assertion runs in the Docker testbed and the Phase 6 image
# build — NOT against a dev Pi (where focal55 legitimately exists).
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "SC-image: checking founder identity is absent"

getent passwd focal55 >/dev/null 2>&1 \
    && fail "founder user 'focal55' present in passwd — image not sanitized"
[ ! -d /home/focal55 ] \
    || fail "founder home /home/focal55 present — image not sanitized"

echo "SC-image: PASS"
