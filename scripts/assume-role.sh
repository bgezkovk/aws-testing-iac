#!/usr/bin/env bash
# Assume a devops role with MFA and print export lines for the shell.
#
# Usage:
#   eval "$(scripts/assume-role.sh admin|read_only <mfa-code> [profile])"
#
# Base profile: 3rd arg, else $AWS_PROFILE, else "devops" (the devops user's access keys).
# Requires: aws cli v2.
#
# Alternative (no script): let the AWS CLI handle MFA + caching via ~/.aws/config:
#
#   [profile devops]
#   region = eu-west-1
#   # credentials for the devops user live in ~/.aws/credentials under [devops]
#
#   [profile devops-admin]
#   region = eu-west-1
#   source_profile = devops
#   role_arn = arn:aws:iam::<ACCOUNT_ID>:role/devops-admin
#   mfa_serial = arn:aws:iam::<ACCOUNT_ID>:mfa/<device-name>
#   duration_seconds = 3600
#
#   [profile devops-read-only]
#   region = eu-west-1
#   source_profile = devops
#   role_arn = arn:aws:iam::<ACCOUNT_ID>:role/devops-read-only
#   mfa_serial = arn:aws:iam::<ACCOUNT_ID>:mfa/<device-name>
#   duration_seconds = 14400
#
#   then: AWS_PROFILE=devops-admin aws sts get-caller-identity
set -euo pipefail

REGION="eu-west-1"

usage() {
  echo "usage: $0 admin|read_only <mfa-code> [profile]" >&2
  exit 1
}

[[ $# -ge 2 && $# -le 3 ]] || usage

case "$1" in
  admin)     ROLE_NAME="devops-admin";     DURATION=3600 ;;
  read_only) ROLE_NAME="devops-read-only"; DURATION=14400 ;;
  *) usage ;;
esac

MFA_CODE="$2"
PROFILE="${3:-${AWS_PROFILE:-devops}}"

# Make sure we start from the base user's credentials, not stale session ones.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

aws_base() { aws --profile "$PROFILE" --region "$REGION" --output text "$@"; }

ACCOUNT_ID="$(aws_base sts get-caller-identity --query Account)"
MFA_SERIAL="$(aws_base iam list-mfa-devices --query 'MFADevices[0].SerialNumber')"

if [[ -z "$MFA_SERIAL" || "$MFA_SERIAL" == "None" ]]; then
  echo "error: no MFA device registered for profile '$PROFILE'" >&2
  exit 1
fi

read -r AKID SECRET TOKEN < <(
  aws_base sts assume-role \
    --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}" \
    --role-session-name "${ROLE_NAME}-$(date +%s)" \
    --serial-number "$MFA_SERIAL" \
    --token-code "$MFA_CODE" \
    --duration-seconds "$DURATION" \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]'
)

echo "unset AWS_PROFILE"
echo "export AWS_ACCESS_KEY_ID=${AKID}"
echo "export AWS_SECRET_ACCESS_KEY=${SECRET}"
echo "export AWS_SESSION_TOKEN=${TOKEN}"
echo "export AWS_REGION=${REGION}"
echo "assumed ${ROLE_NAME} in ${ACCOUNT_ID} for ${DURATION}s" >&2
