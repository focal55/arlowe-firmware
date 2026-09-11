#!/usr/bin/env bash
set -euo pipefail

# Stand up the Phase 7 staging PKI in AWS IoT Core.
#
# Creates: an IAM role the IoT credentials provider can assume, an IoT role alias
# pointing at it, and an IoT policy granting device certificates exactly one action.
# Certificates themselves are minted by the CSR broker, not here.
#
# This is an OPS-HOST script. Nothing under scripts/pki/ ships in the firmware image.
# It creates real, billable AWS resources - run it against a STAGING account, and run
# teardown-staging.sh when you are done.
#
# Usage: AWS_PROFILE=... AWS_REGION=... scripts/pki/setup-staging.sh [--prefix NAME]
#
# Re-running is safe: every step is create-or-update.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.staging-env"

PREFIX="arlowe-staging"

# Passed to the role alias below as --credential-duration-seconds 900.
# That is the AWS minimum, and it is deliberately at the bottom of the 900-43200s range.
#
# Revoking a certificate stops NEW credential exchanges; it does not retroactively
# invalidate an STS token the device already holds. The honest revocation bound is
# therefore max(poll_interval, remaining_credential_lifetime). Pinning this to 900
# puts it at or below identity.poll_interval_seconds (min 900, default 3600), which
# collapses the bound to a single polling interval - the number SC4 asserts against.
# See ADR-0007. Do not raise this without re-deriving SC4's bound.
CREDENTIAL_DURATION_SECONDS=900

usage() {
  echo "Usage: AWS_PROFILE=... AWS_REGION=... scripts/pki/setup-staging.sh [--prefix NAME]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      [[ $# -ge 2 ]] || { echo "setup-staging.sh: --prefix requires a value" >&2; exit 2; }
      PREFIX="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "setup-staging.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

: "${AWS_PROFILE:?setup-staging.sh: AWS_PROFILE is not set. Export the profile for your STAGING account.}"
: "${AWS_REGION:?setup-staging.sh: AWS_REGION is not set. Export the region for your STAGING account.}"
command -v aws >/dev/null 2>&1 || { echo "setup-staging.sh: aws CLI v2 not found on PATH" >&2; exit 2; }

ROLE_NAME="${PREFIX}-device-role"
ROLE_ALIAS="${PREFIX}-role-alias"
POLICY_NAME="${PREFIX}-device-policy"
INLINE_POLICY_NAME="${PREFIX}-ota-read"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
ROLE_ALIAS_ARN="arn:aws:iot:${AWS_REGION}:${ACCOUNT_ID}:rolealias/${ROLE_ALIAS}"

echo "==> staging PKI prefix=${PREFIX} region=${AWS_REGION}"

TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"credentials.iot.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

# Placeholder permission only. Its job is to prove the exchanged credentials are real
# AWS credentials; the actual OTA grants are Phase 9's to define.
INLINE_POLICY="$(printf '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::%s-ota-placeholder/*"}]}' "$PREFIX")"

DEVICE_POLICY="$(printf '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"iot:AssumeRoleWithCertificate","Resource":"%s"}]}' "$ROLE_ALIAS_ARN")"

# --- IAM role ---------------------------------------------------------------
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "    iam role ${ROLE_NAME}: exists, updating trust policy"
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "$TRUST_POLICY"
else
  echo "    iam role ${ROLE_NAME}: creating"
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --description "Arlowe staging PKI: assumed by the AWS IoT credentials provider" >/dev/null
fi
# put-role-policy overwrites, so this needs no existence check.
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$INLINE_POLICY_NAME" \
  --policy-document "$INLINE_POLICY"

# --- IoT role alias ---------------------------------------------------------
if aws iot describe-role-alias --role-alias "$ROLE_ALIAS" >/dev/null 2>&1; then
  echo "    role alias ${ROLE_ALIAS}: exists, updating"
  aws iot update-role-alias \
    --role-alias "$ROLE_ALIAS" \
    --role-arn "$ROLE_ARN" \
    --credential-duration-seconds "$CREDENTIAL_DURATION_SECONDS" >/dev/null
else
  echo "    role alias ${ROLE_ALIAS}: creating"
  aws iot create-role-alias \
    --role-alias "$ROLE_ALIAS" \
    --role-arn "$ROLE_ARN" \
    --credential-duration-seconds "$CREDENTIAL_DURATION_SECONDS" >/dev/null
fi

# --- IoT policy -------------------------------------------------------------
if aws iot get-policy --policy-name "$POLICY_NAME" >/dev/null 2>&1; then
  echo "    iot policy ${POLICY_NAME}: exists, setting a fresh default version"
  # IoT caps a policy at 5 versions; prune the non-default ones first so repeated
  # runs cannot wedge on VersionsLimitExceeded.
  while IFS= read -r version_id; do
    [[ -n "$version_id" ]] || continue
    aws iot delete-policy-version --policy-name "$POLICY_NAME" --policy-version-id "$version_id"
  done < <(aws iot list-policy-versions --policy-name "$POLICY_NAME" \
             --query 'policyVersions[?!isDefaultVersion].versionId' \
             --output text | tr '\t' '\n')
  aws iot create-policy-version \
    --policy-name "$POLICY_NAME" \
    --policy-document "$DEVICE_POLICY" \
    --set-as-default >/dev/null
else
  echo "    iot policy ${POLICY_NAME}: creating"
  aws iot create-policy --policy-name "$POLICY_NAME" --policy-document "$DEVICE_POLICY" >/dev/null
fi

CREDENTIALS_ENDPOINT="$(aws iot describe-endpoint \
  --endpoint-type iot:CredentialProvider --query endpointAddress --output text)"

# The endpoint prefix and the role ARN are account-identifying, and the sanitize
# banlist does not know about them, so they only ever land in this gitignored file.
umask 077
cat > "$ENV_FILE" <<ENVEOF
# Generated by scripts/pki/setup-staging.sh - gitignored, never commit.
# These six names are a frozen contract read by the CSR broker and the SC4 harness.
ARLOWE_PKI_PREFIX=${PREFIX}
ARLOWE_PKI_REGION=${AWS_REGION}
ARLOWE_PKI_ROLE_ALIAS=${ROLE_ALIAS}
ARLOWE_PKI_POLICY=${POLICY_NAME}
ARLOWE_PKI_CREDENTIALS_ENDPOINT=${CREDENTIALS_ENDPOINT}
ARLOWE_PKI_ROLE_ARN=${ROLE_ARN}
ENVEOF

echo "==> wrote ${ENV_FILE} (gitignored)"
echo "    credential duration: ${CREDENTIAL_DURATION_SECONDS}s"
echo "    tear down with: scripts/pki/teardown-staging.sh --prefix ${PREFIX}"
