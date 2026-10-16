#!/usr/bin/env bash
# Write/refresh the kubeconfig entry for the test cluster.
#
# Usage:
#   scripts/kubeconfig.sh            # use current AWS credentials
#   scripts/kubeconfig.sh --admin    # authenticate as role devops-admin (adds --role-arn)
#   scripts/kubeconfig.sh --role-arn arn:aws:iam::123456789012:role/some-role
#
# Env overrides: CLUSTER_NAME, AWS_REGION, KUBE_ALIAS
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGION="${AWS_REGION:-eu-west-1}"
CLUSTER_NAME="${CLUSTER_NAME:-$(cd "$REPO_ROOT" && node -p "require('./cdk.json').context.clusterName")}"
KUBE_ALIAS="${KUBE_ALIAS:-$CLUSTER_NAME}"
ADMIN_ROLE_NAME="devops-admin" # IAM_NAMES.adminRole in lib/config.ts

ROLE_ARGS=()
case "${1:-}" in
  "") ;;
  --admin)
    ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
    ROLE_ARGS=(--role-arn "arn:aws:iam::${ACCOUNT}:role/${ADMIN_ROLE_NAME}")
    ;;
  --role-arn)
    [[ -n "${2:-}" ]] || { echo "--role-arn needs an ARN" >&2; exit 2; }
    ROLE_ARGS=(--role-arn "$2")
    ;;
  -h|--help)
    sed -n '2,10p' "$0"; exit 0 ;;
  *)
    echo "Unknown argument: $1 (see --help)" >&2; exit 2 ;;
esac

aws eks update-kubeconfig \
  --region "$REGION" \
  --name "$CLUSTER_NAME" \
  --alias "$KUBE_ALIAS" \
  ${ROLE_ARGS[@]+"${ROLE_ARGS[@]}"}

kubectl --context "$KUBE_ALIAS" get nodes -o wide || true
