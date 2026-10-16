#!/usr/bin/env bash
# Delete the cluster stack (same effect as `cdk destroy Cluster`, without needing node/cdk).
#
# Usage:
#   scripts/cluster-down.sh                    # delete if it exists
#   scripts/cluster-down.sh --max-age-hours 8  # delete only if last created/updated > 8h ago
#
# No-op if the stack does not exist. The ECR repo is emptied by CloudFormation (EmptyOnDelete).
# Env overrides: AWS_REGION, STACK_NAME
set -euo pipefail

REGION="${AWS_REGION:-eu-west-1}"
STACK_NAME="${STACK_NAME:-aws-testing-cluster}" # STACK_NAMES.cluster in lib/config.ts
MAX_AGE_HOURS=""

case "${1:-}" in
  "") ;;
  --max-age-hours) MAX_AGE_HOURS="${2:?--max-age-hours needs a number}" ;;
  -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
  *) echo "Unknown argument: $1" >&2; exit 2 ;;
esac

if ! out="$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK_NAME" \
  --query 'Stacks[0].[StackStatus,CreationTime,LastUpdatedTime]' --output text 2>&1)"; then
  if grep -q 'does not exist' <<<"$out"; then
    echo "Stack $STACK_NAME does not exist - nothing to do."
    exit 0
  fi
  echo "describe-stacks failed: $out" >&2
  exit 1
fi
read -r status created updated <<<"$out"
echo "Stack $STACK_NAME: $status (created $created, updated $updated)"

if [[ "$status" == DELETE_IN_PROGRESS ]]; then
  echo "Already deleting - waiting."
elif [[ -n "$MAX_AGE_HOURS" ]]; then
  age_h="$(python3 -I -c '
import sys, datetime as d
ts = [t for t in sys.argv[1:] if t and t != "None"]
last = max(d.datetime.fromisoformat(t.replace("Z", "+00:00")) for t in ts)
print(int((d.datetime.now(d.timezone.utc) - last).total_seconds() // 3600))' "$created" "$updated")"
  echo "Age since last create/update: ${age_h}h (limit ${MAX_AGE_HOURS}h)"
  if (( age_h < MAX_AGE_HOURS )); then
    echo "Keeping the cluster."
    exit 0
  fi
fi

if [[ "$status" != DELETE_IN_PROGRESS ]]; then
  echo "Deleting $STACK_NAME ..."
  aws cloudformation delete-stack --region "$REGION" --stack-name "$STACK_NAME"
fi
aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$STACK_NAME"
echo "Deleted."
