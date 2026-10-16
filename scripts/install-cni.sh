#!/usr/bin/env bash
# Install / upgrade the self-managed VPC CNI (aws-node) with network policy enabled.
#
# Usage:
#   scripts/install-cni.sh                     # default node agent image from the chart
#   scripts/install-cni.sh --npa-image <ref>   # patched network-policy-agent image
#
# EKS bootstraps a self-managed aws-node DaemonSet when the cluster is created (no vpc-cni
# managed addon in lib/cluster-stack.ts). The first run adopts those resources into a Helm
# release (chart README "Adopting the existing aws-node resources"); after that it is a
# plain `helm upgrade`. Every run without --npa-image puts the chart's default agent back.
#
# Needs: kubectl (context pointing at the cluster, see scripts/kubeconfig.sh), helm.
# Env overrides: CHART_VERSION
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART_VERSION="${CHART_VERSION:-1.23.2}"
RELEASE=aws-vpc-cni
NS=kube-system
NPA_IMAGE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --npa-image) NPA_IMAGE="${2:?--npa-image needs an image ref}"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

helm repo add eks https://aws.github.io/eks-charts --force-update >/dev/null
helm repo update eks >/dev/null

if ! helm status "$RELEASE" -n "$NS" >/dev/null 2>&1; then
  echo "Adopting EKS-bootstrapped aws-node resources into Helm release $RELEASE ..."
  for kind in daemonSet clusterRole clusterRoleBinding serviceAccount; do
    kubectl -n "$NS" annotate --overwrite "$kind" aws-node \
      meta.helm.sh/release-name="$RELEASE" meta.helm.sh/release-namespace="$NS"
    kubectl -n "$NS" label --overwrite "$kind" aws-node app.kubernetes.io/managed-by=Helm
  done
  if kubectl -n "$NS" get configmap amazon-vpc-cni >/dev/null 2>&1; then
    kubectl -n "$NS" annotate --overwrite configmap amazon-vpc-cni \
      meta.helm.sh/release-name="$RELEASE" meta.helm.sh/release-namespace="$NS"
    kubectl -n "$NS" label --overwrite configmap amazon-vpc-cni app.kubernetes.io/managed-by=Helm
  fi
fi

args=(upgrade --install "$RELEASE" eks/aws-vpc-cni --version "$CHART_VERSION" -n "$NS"
  -f "$REPO_ROOT/k8s/aws-vpc-cni-values.yaml" --wait --timeout 5m)
[[ -n "$NPA_IMAGE" ]] && args+=(--set "nodeAgent.image.override=$NPA_IMAGE")

echo "helm ${args[*]}"
helm "${args[@]}"
kubectl -n "$NS" rollout status daemonset/aws-node --timeout=180s

echo "aws-eks-nodeagent image:"
kubectl -n "$NS" get daemonset aws-node \
  -o jsonpath="{.spec.template.spec.containers[?(@.name=='aws-eks-nodeagent')].image}{'\n'}"
