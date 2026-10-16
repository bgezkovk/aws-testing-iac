#!/usr/bin/env bash
# Return the aws-testing account to ~$0/month.
#
#   cleanup.sh [plan]   destroy nothing; aws-nuke dry run (default)
#   cleanup.sh run      destroy the cluster stack, nuke everything not protected
#                       by cleanup/aws-nuke.yaml, then check for billable leftovers
#   cleanup.sh report   only the leftover billable resources check
#
# Required env (safety interlocks):
#   EXPECTED_ACCOUNT_ID   must equal the account of the current AWS credentials
#   CONFIRM_NUKE=yes      required for "run"
# Optional env:
#   AWS_NUKE_VERSION      aws-nuke release to use (default: pinned below)
#   AWS_NUKE_INSTALL_DIR  where to install aws-nuke if it is not on PATH
#
# Works with bash 3.2 (macOS) and in GitHub Actions (ubuntu runner with awscli).
set -euo pipefail

AWS_NUKE_VERSION="${AWS_NUKE_VERSION:-v3.68.3}"
HOME_REGION="eu-west-1"                 # lib/config.ts REGION
CLUSTER_STACK="aws-testing-cluster"      # lib/config.ts STACK_NAMES.cluster
CLUSTER_CONSTRUCT_ID="Cluster"           # bin/app.ts construct id of the cluster stack

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_TEMPLATE="${SCRIPT_DIR}/aws-nuke.yaml"

MODE="${1:-plan}"

log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; }

case "${MODE}" in
  plan|run|report) ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage >&2; die "unknown mode: ${MODE}" ;;
esac

command -v aws >/dev/null 2>&1 || die "aws CLI not found"

# ---------------------------------------------------------------------------
# 1. Safety interlock: right account, explicit confirmation for destructive runs
# ---------------------------------------------------------------------------
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" \
  || die "cannot resolve the AWS account (no credentials?)"
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"
log "Account ${ACCOUNT_ID} as ${CALLER_ARN}"

[ -n "${EXPECTED_ACCOUNT_ID:-}" ] || die "set EXPECTED_ACCOUNT_ID to the aws-testing account id"
[ "${EXPECTED_ACCOUNT_ID}" = "${ACCOUNT_ID}" ] \
  || die "credentials are for account ${ACCOUNT_ID}, but EXPECTED_ACCOUNT_ID=${EXPECTED_ACCOUNT_ID}. Refusing to continue."
if [ "${MODE}" = "run" ] && [ "${CONFIRM_NUKE:-}" != "yes" ]; then
  die "real run requires CONFIRM_NUKE=yes"
fi

# ---------------------------------------------------------------------------
# Leftover billable resources report
# ---------------------------------------------------------------------------
LEFTOVERS=0
QUERY_ERRORS=0

# check <region> <label> <aws args...>: the command must print whitespace-separated ids
check() {
  local region="$1" label="$2" out
  shift 2
  if ! out="$(aws --region "${region}" --output text "$@" 2>&1)"; then
    warn "${region}: ${label}: query failed: $(printf '%s' "${out}" | head -n 1)"
    QUERY_ERRORS=$((QUERY_ERRORS + 1))
    return 0
  fi
  out="$(printf '%s' "${out}" | tr '\t' '\n' | grep -v -e '^None$' -e '^[[:space:]]*$' || true)"
  if [ -n "${out}" ]; then
    printf '  %-14s %-28s %s\n' "${region}" "${label}" "$(printf '%s' "${out}" | tr '\n' ' ')"
    LEFTOVERS=$((LEFTOVERS + $(printf '%s\n' "${out}" | wc -l)))
  fi
}

leftover_report() {
  local regions region
  log "Checking for leftover billable resources in all enabled regions"
  regions="$(aws ec2 describe-regions --region "${HOME_REGION}" \
    --filters Name=opt-in-status,Values=opt-in-not-required,opted-in \
    --query 'Regions[].RegionName' --output text)" || die "cannot list regions"

  for region in ${regions}; do
    check "${region}" "Elastic IPs"        ec2 describe-addresses --query 'Addresses[].PublicIp'
    check "${region}" "EBS volumes"        ec2 describe-volumes --query 'Volumes[].VolumeId'
    check "${region}" "EBS snapshots"      ec2 describe-snapshots --owner-ids self --query 'Snapshots[].SnapshotId'
    check "${region}" "NAT gateways"       ec2 describe-nat-gateways \
      --filter Name=state,Values=pending,available --query 'NatGateways[].NatGatewayId'
    check "${region}" "EC2 instances"      ec2 describe-instances \
      --filters Name=instance-state-name,Values=pending,running,stopping \
      --query 'Reservations[].Instances[].InstanceId'
    check "${region}" "Load balancers v2"  elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
    check "${region}" "Classic ELBs"       elb describe-load-balancers --query 'LoadBalancerDescriptions[].LoadBalancerName'
    check "${region}" "EKS clusters"       eks list-clusters --query 'clusters[]'
    check "${region}" "RDS instances"      rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'
    # shellcheck disable=SC2016 # backticks are a JMESPath literal, not shell
    check "${region}" "Log groups (>0 B)"  logs describe-log-groups --query 'logGroups[?storedBytes > `0`].logGroupName'
  done

  if [ "${LEFTOVERS}" -gt 0 ]; then
    warn "${LEFTOVERS} billable resource(s) remain (listed above)"
    return 1
  fi
  if [ "${QUERY_ERRORS}" -gt 0 ]; then
    warn "no leftovers found, but ${QUERY_ERRORS} queries failed: result is incomplete"
    return 1
  fi
  log "No billable leftovers found"
}

if [ "${MODE}" = "report" ]; then
  if leftover_report; then exit 0; else exit 1; fi
fi

# ---------------------------------------------------------------------------
# 7. aws-nuke binary (pinned, checksum-verified)
# ---------------------------------------------------------------------------
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

fetch() { # fetch <url> <dest>
  if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 3 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then wget -q -O "$2" "$1"
  else die "need curl or wget to download aws-nuke"; fi
}

ensure_aws_nuke() {
  local os arch asset base dir tmp expected actual
  if command -v aws-nuke >/dev/null 2>&1 \
     && aws-nuke version 2>/dev/null | grep -q "${AWS_NUKE_VERSION}"; then
    AWS_NUKE="$(command -v aws-nuke)"
    return 0
  fi

  case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux)  os=linux ;;
    *) die "unsupported OS: $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  arch=amd64 ;;
    arm64|aarch64) arch=arm64 ;;
    *) die "unsupported CPU: $(uname -m)" ;;
  esac

  dir="${AWS_NUKE_INSTALL_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/aws-nuke/${AWS_NUKE_VERSION}}"
  AWS_NUKE="${dir}/aws-nuke"
  if [ -x "${AWS_NUKE}" ]; then
    return 0
  fi

  command -v tar >/dev/null 2>&1 || die "need tar to install aws-nuke"
  asset="aws-nuke-${AWS_NUKE_VERSION}-${os}-${arch}.tar.gz"
  base="https://github.com/ekristen/aws-nuke/releases/download/${AWS_NUKE_VERSION}"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/aws-nuke-dl.XXXXXX")"
  log "Installing aws-nuke ${AWS_NUKE_VERSION} (${os}/${arch}) into ${dir}"
  fetch "${base}/${asset}" "${tmp}/${asset}"
  fetch "${base}/checksums.txt" "${tmp}/checksums.txt"

  expected="$(awk -v f="${asset}" '$2 == f {print $1}' "${tmp}/checksums.txt")"
  [ -n "${expected}" ] || die "${asset} not listed in checksums.txt"
  actual="$(sha256_of "${tmp}/${asset}")"
  [ "${expected}" = "${actual}" ] || die "checksum mismatch for ${asset}: expected ${expected}, got ${actual}"

  mkdir -p "${tmp}/x" "${dir}"
  tar -xzf "${tmp}/${asset}" -C "${tmp}/x" aws-nuke
  mv "${tmp}/x/aws-nuke" "${AWS_NUKE}"
  chmod +x "${AWS_NUKE}"
  rm -rf "${tmp}"
}

ensure_aws_nuke
log "Using $("${AWS_NUKE}" version) at ${AWS_NUKE}"

# ---------------------------------------------------------------------------
# Protected GitHub Actions OIDC provider (Foundation stack)
# ---------------------------------------------------------------------------
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${OIDC_ARN}" >/dev/null 2>&1; then
  log "Protected GitHub OIDC provider: ${OIDC_ARN}"
elif [ "${MODE}" = "run" ]; then
  die "GitHub OIDC provider ${OIDC_ARN} not found. Deploy the Foundation stack first, or CI access could not be restored after the nuke."
else
  warn "GitHub OIDC provider ${OIDC_ARN} not found"
fi

# ---------------------------------------------------------------------------
# 2. Account alias (aws-nuke refuses accounts without one, unless the alias check
#    is bypassed; we keep the check as an extra safety net)
# ---------------------------------------------------------------------------
ALIAS="$(aws iam list-account-aliases --query 'AccountAliases[0]' --output text)"
if [ -z "${ALIAS}" ] || [ "${ALIAS}" = "None" ]; then
  ALIAS="aws-testing-${ACCOUNT_ID}"
  log "Account has no alias; creating '${ALIAS}' (required by aws-nuke)"
  aws iam create-account-alias --account-alias "${ALIAS}"
fi
log "Account alias: ${ALIAS}"

# ---------------------------------------------------------------------------
# 3. Destroy the cluster stack the normal way first (clean, ordered teardown)
# ---------------------------------------------------------------------------
stack_exists() {
  aws cloudformation describe-stacks --region "${HOME_REGION}" --stack-name "$1" >/dev/null 2>&1
}

destroy_cluster_stack() {
  if ! stack_exists "${CLUSTER_STACK}"; then
    log "Stack ${CLUSTER_STACK} not present"
    return 0
  fi
  if [ "${MODE}" != "run" ]; then
    log "Stack ${CLUSTER_STACK} exists; 'run' destroys it with cdk before nuking (plan: skipped)"
    return 0
  fi

  if [ -x "${REPO_ROOT}/node_modules/.bin/cdk" ]; then
    log "cdk destroy ${CLUSTER_CONSTRUCT_ID} (${CLUSTER_STACK})"
    if (cd "${REPO_ROOT}" && npx --no-install cdk destroy "${CLUSTER_CONSTRUCT_ID}" --force); then
      stack_exists "${CLUSTER_STACK}" || return 0
    fi
    warn "cdk destroy did not remove ${CLUSTER_STACK}; falling back to CloudFormation"
  else
    log "CDK not installed (no node_modules); deleting ${CLUSTER_STACK} via CloudFormation"
  fi

  aws cloudformation delete-stack --region "${HOME_REGION}" --stack-name "${CLUSTER_STACK}"
  log "Waiting for ${CLUSTER_STACK} deletion (EKS takes ~10-15 min)"
  if ! aws cloudformation wait stack-delete-complete --region "${HOME_REGION}" --stack-name "${CLUSTER_STACK}"; then
    warn "${CLUSTER_STACK} deletion did not complete; aws-nuke will remove the remaining resources"
  fi
}

destroy_cluster_stack

# ---------------------------------------------------------------------------
# 4. Render the config
# ---------------------------------------------------------------------------
RENDERED="$(mktemp "${TMPDIR:-/tmp}/aws-nuke-config.XXXXXX")"
trap 'rm -f "${RENDERED}"' EXIT
sed -e "s|__ACCOUNT_ID__|${ACCOUNT_ID}|g" \
  "${CONFIG_TEMPLATE}" > "${RENDERED}"
if grep -q '__[A-Z_]*__' "${RENDERED}"; then
  die "unrendered placeholders left in config"
fi

# ---------------------------------------------------------------------------
# 5. aws-nuke
# ---------------------------------------------------------------------------
# --force         = --no-prompt: skip the interactive "enter account alias" prompts (CI)
# --force-sleep 3 = --prompt-delay: the minimum delay aws-nuke allows
NUKE_ARGS=(run --config "${RENDERED}" --force --force-sleep 3 --default-region "${HOME_REGION}")
if [ -n "${CI:-}" ]; then
  NUKE_ARGS+=(--log-disable-colors)
fi

if [ "${MODE}" = "plan" ]; then
  log "aws-nuke dry run (nothing is deleted)"
  "${AWS_NUKE}" "${NUKE_ARGS[@]}"
  exit 0
fi

log "aws-nuke REAL RUN on ${ACCOUNT_ID} (${ALIAS})"
NUKE_RC=0
"${AWS_NUKE}" "${NUKE_ARGS[@]}" --no-dry-run || NUKE_RC=$?
[ "${NUKE_RC}" -eq 0 ] || warn "aws-nuke exited with ${NUKE_RC}"

# ---------------------------------------------------------------------------
# 6. Verify nothing billable is left
# ---------------------------------------------------------------------------
REPORT_RC=0
leftover_report || REPORT_RC=$?

if [ "${NUKE_RC}" -ne 0 ] || [ "${REPORT_RC}" -ne 0 ]; then
  exit 1
fi
log "Done: account ${ACCOUNT_ID} is clean"
