#!/usr/bin/env bash
# Deploy a patched network-policy-agent (aws-eks-nodeagent container in the aws-node DaemonSet).
#
# Usage:
#   scripts/set-npa-image.sh <image-ref>
#   scripts/set-npa-image.sh --build <path-to-aws-network-policy-agent-checkout> [tag]
#   scripts/set-npa-image.sh --reset
#
# --build  builds linux/amd64 from the checkout, pushes to the ECR repo created by the
#          cluster stack (tag defaults to the checkout's git short sha), then deploys it.
# --reset  back to the chart's default agent image.
#
# Deploys via scripts/install-cni.sh (helm upgrade with nodeAgent.image.override), so the
# change is declarative and nothing on the EKS side reverts it.
#
# Env overrides: AWS_REGION, ECR_REPO_NAME
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGION="${AWS_REGION:-eu-west-1}"
ECR_REPO_NAME="${ECR_REPO_NAME:-network-policy-agent}" # ECR_REPO_NAME in lib/config.ts

usage() { sed -n '2,15p' "$0"; exit "${1:-2}"; }

[[ $# -ge 1 ]] || usage

case "$1" in
  -h|--help) usage 0 ;;
  --reset) exec "$REPO_ROOT/scripts/install-cni.sh" ;;
  --build)
    SRC="${2:-}"
    [[ -n "$SRC" && -d "$SRC" ]] || { echo "--build needs a path to the agent checkout" >&2; usage; }
    TAG="${3:-$(git -C "$SRC" rev-parse --short HEAD)}"
    ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
    REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
    IMAGE="${REGISTRY}/${ECR_REPO_NAME}:${TAG}"
    echo "Logging in to $REGISTRY ..."
    aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"
    echo "Building and pushing $IMAGE ..."
    docker buildx build --platform linux/amd64 -t "$IMAGE" --push "$SRC"
    ;;
  -*) echo "Unknown flag: $1" >&2; usage ;;
  *) IMAGE="$1" ;;
esac

exec "$REPO_ROOT/scripts/install-cni.sh" --npa-image "$IMAGE"
