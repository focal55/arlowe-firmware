#!/usr/bin/env bash
set -euo pipefail

# The SC4 lever: change a device certificate's status and report the status AWS
# actually reports back afterwards, not the one that was requested.
#
# Usage: AWS_PROFILE=... AWS_REGION=... scripts/pki/revoke.sh <certificate-id> \
#          [--status ACTIVE|INACTIVE|REVOKED]
#
# Defaults to REVOKED. ACTIVE exists so a staging run can be reset without minting a
# new certificate. Exits non-zero if the observed status is not the requested one.
#
# Revoking blocks further credential exchanges; it does not invalidate an STS token the
# device already holds. Residual exposure is bounded by the role alias's 900s credential
# duration (see setup-staging.sh).

CERT_ID=""
STATUS="REVOKED"

usage() {
  echo "Usage: scripts/pki/revoke.sh <certificate-id> [--status ACTIVE|INACTIVE|REVOKED]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)
      [[ $# -ge 2 ]] || { echo "revoke.sh: --status requires a value" >&2; exit 2; }
      STATUS="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    -*)
      echo "revoke.sh: unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)
      [[ -z "$CERT_ID" ]] || { echo "revoke.sh: unexpected extra argument: $1" >&2; exit 2; }
      CERT_ID="$1"; shift ;;
  esac
done

if [[ -z "$CERT_ID" ]]; then
  echo "revoke.sh: a certificate id is required" >&2
  usage >&2
  exit 2
fi

case "$STATUS" in
  ACTIVE|INACTIVE|REVOKED) ;;
  *) echo "revoke.sh: --status must be ACTIVE, INACTIVE or REVOKED (got: ${STATUS})" >&2; exit 2 ;;
esac

: "${AWS_PROFILE:?revoke.sh: AWS_PROFILE is not set.}"
: "${AWS_REGION:?revoke.sh: AWS_REGION is not set.}"
command -v aws >/dev/null 2>&1 || { echo "revoke.sh: aws CLI v2 not found on PATH" >&2; exit 2; }

aws iot update-certificate --certificate-id "$CERT_ID" --new-status "$STATUS"

OBSERVED="$(aws iot describe-certificate --certificate-id "$CERT_ID" \
  --query certificateDescription.status --output text)"

echo "certificate ${CERT_ID} status: ${OBSERVED}"

if [[ "$OBSERVED" != "$STATUS" ]]; then
  echo "revoke.sh: requested ${STATUS} but AWS reports ${OBSERVED}" >&2
  exit 1
fi
