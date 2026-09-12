#!/usr/bin/env bash
set -euo pipefail

# Destroy everything setup-staging.sh created, plus every certificate and thing the
# CSR broker minted under the same prefix. Anything left behind bills indefinitely.
#
# Usage: AWS_PROFILE=... AWS_REGION=... scripts/pki/teardown-staging.sh [--prefix NAME]
#
# Re-running is safe: every step checks for existence first.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.staging-env"

PREFIX="arlowe-staging"

usage() {
  echo "Usage: AWS_PROFILE=... AWS_REGION=... scripts/pki/teardown-staging.sh [--prefix NAME]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      [[ $# -ge 2 ]] || { echo "teardown-staging.sh: --prefix requires a value" >&2; exit 2; }
      PREFIX="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "teardown-staging.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

: "${AWS_PROFILE:?teardown-staging.sh: AWS_PROFILE is not set.}"
: "${AWS_REGION:?teardown-staging.sh: AWS_REGION is not set.}"
command -v aws >/dev/null 2>&1 || { echo "teardown-staging.sh: aws CLI v2 not found on PATH" >&2; exit 2; }

ROLE_NAME="${PREFIX}-device-role"
ROLE_ALIAS="${PREFIX}-role-alias"
POLICY_NAME="${PREFIX}-device-policy"
INLINE_POLICY_NAME="${PREFIX}-ota-read"

echo "==> tearing down staging PKI prefix=${PREFIX} region=${AWS_REGION}"

# AWS enforces a strict order here: a certificate cannot be deleted while it is ACTIVE
# or while any policy or thing is still attached to it. Doing this explicitly rather
# than letting delete-certificate fail is the difference between a clean teardown and
# a silent recurring bill.
delete_certificate() {
  local cert_arn="$1"
  local cert_id="${cert_arn##*/}"
  echo "    certificate ${cert_id}: detaching, deactivating, deleting"

  while IFS= read -r attached_policy; do
    [[ -n "$attached_policy" ]] || continue
    aws iot detach-policy --policy-name "$attached_policy" --target "$cert_arn"
  done < <(aws iot list-attached-policies --target "$cert_arn" \
             --query 'policies[].policyName' --output text | tr '\t' '\n')

  while IFS= read -r thing_name; do
    [[ -n "$thing_name" ]] || continue
    aws iot detach-thing-principal --thing-name "$thing_name" --principal "$cert_arn"
    aws iot delete-thing --thing-name "$thing_name"
    echo "    thing ${thing_name}: deleted"
  done < <(aws iot list-principal-things --principal "$cert_arn" \
             --query 'things[]' --output text | tr '\t' '\n')

  aws iot update-certificate --certificate-id "$cert_id" --new-status INACTIVE
  aws iot delete-certificate --certificate-id "$cert_id" --force-delete
}

# --- broker-minted certificates + the IoT policy ----------------------------
if aws iot get-policy --policy-name "$POLICY_NAME" >/dev/null 2>&1; then
  while IFS= read -r target_arn; do
    [[ -n "$target_arn" ]] || continue
    delete_certificate "$target_arn"
  done < <(aws iot list-targets-for-policy --policy-name "$POLICY_NAME" \
             --query 'targets[]' --output text | tr '\t' '\n')

  while IFS= read -r version_id; do
    [[ -n "$version_id" ]] || continue
    aws iot delete-policy-version --policy-name "$POLICY_NAME" --policy-version-id "$version_id"
  done < <(aws iot list-policy-versions --policy-name "$POLICY_NAME" \
             --query 'policyVersions[?!isDefaultVersion].versionId' --output text | tr '\t' '\n')

  aws iot delete-policy --policy-name "$POLICY_NAME"
  echo "    iot policy ${POLICY_NAME}: deleted"
else
  echo "    iot policy ${POLICY_NAME}: absent"
fi

# Things the broker registered but never attached a policy-bearing cert to would
# otherwise survive the sweep above.
while IFS= read -r thing_name; do
  [[ -n "$thing_name" ]] || continue
  [[ "$thing_name" == "$PREFIX"* ]] || continue
  while IFS= read -r principal_arn; do
    [[ -n "$principal_arn" ]] || continue
    delete_certificate "$principal_arn"
  done < <(aws iot list-thing-principals --thing-name "$thing_name" \
             --query 'principals[]' --output text | tr '\t' '\n')
  if aws iot describe-thing --thing-name "$thing_name" >/dev/null 2>&1; then
    aws iot delete-thing --thing-name "$thing_name"
    echo "    thing ${thing_name}: deleted"
  fi
done < <(aws iot list-things --query 'things[].thingName' --output text | tr '\t' '\n')

# --- role alias -------------------------------------------------------------
if aws iot describe-role-alias --role-alias "$ROLE_ALIAS" >/dev/null 2>&1; then
  aws iot delete-role-alias --role-alias "$ROLE_ALIAS"
  echo "    role alias ${ROLE_ALIAS}: deleted"
else
  echo "    role alias ${ROLE_ALIAS}: absent"
fi

# --- IAM role ---------------------------------------------------------------
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  # An IAM role cannot be deleted while it still carries inline or attached policies.
  if aws iam get-role-policy --role-name "$ROLE_NAME" --policy-name "$INLINE_POLICY_NAME" >/dev/null 2>&1; then
    aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$INLINE_POLICY_NAME"
  fi
  while IFS= read -r managed_arn; do
    [[ -n "$managed_arn" ]] || continue
    aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$managed_arn"
  done < <(aws iam list-attached-role-policies --role-name "$ROLE_NAME" \
             --query 'AttachedPolicies[].PolicyArn' --output text | tr '\t' '\n')
  aws iam delete-role --role-name "$ROLE_NAME"
  echo "    iam role ${ROLE_NAME}: deleted"
else
  echo "    iam role ${ROLE_NAME}: absent"
fi

rm -f "$ENV_FILE"
echo "==> teardown complete; ${ENV_FILE} removed"
