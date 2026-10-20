#!/usr/bin/env bash
# Turn an empty account into a configured checkout: assert the invariants, create
# the Terraform state bucket, write the four generated files. Idempotent.
#
# Does NOT probe capacity or open a reservation: one command that silently
# starts a $60/hr meter is the wrong shape. Absorbs the old bootstrap.sh, minus
# its AWSServiceRoleForEC2Spot step -- nothing in this configuration launches
# Spot. Switching
# the demo to Spot means adding it back; docs/DEMO.md carries the change set.
#
# Usage:
#   scripts/configure.sh --region <r> --expected-account <12-digit-id>
#     [--gpu-instance-type <t>] [--state-region <r>] [--dry-run]
#
# Env overrides: CLUSTER_NAME, AZ_COUNT (empty = every AZ), NANOCHAT_DIR,
# AWS_PROFILE (recorded as-is; empty means ambient credentials), EXPECTED_ACCOUNT.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REGION=""
STATE_REGION=""
GPU_INSTANCE_TYPE=""
EXPECTED_ACCOUNT_CLI=""
EXPECTED_ACCOUNT_ENV="${EXPECTED_ACCOUNT:-}"
DRY_RUN=0

CLUSTER_NAME="${CLUSTER_NAME:-nanochat-demo}"
AZ_COUNT="${AZ_COUNT:-}"
NANOCHAT_DIR="${NANOCHAT_DIR:-../nanochat}"

# On-Demand G and VT, vCPU-based. A p* type needs L-417A185B instead.
QUOTA_CODE=L-DB2E81BA

log()  { printf '\033[1;34m[configure]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[configure]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
usage: scripts/configure.sh --region <r> --expected-account <12-digit-id>
       [--gpu-instance-type <t>] [--state-region <r>] [--dry-run]

  --region              target region for the foundation and eks roots
  --expected-account    required target AWS account; may instead be set in the environment
  --gpu-instance-type   optional; narrows the NodePool and enables the quota check
  --state-region        where the tfstate bucket lives; defaults to --region
  --dry-run             print the four files instead of writing them, create nothing

env: CLUSTER_NAME, AZ_COUNT (empty = every AZ; set it to match an existing VPC),
     NANOCHAT_DIR, AWS_PROFILE, EXPECTED_ACCOUNT
EOF
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --region)            REGION="${2:?--region needs a value}"; shift 2 ;;
    --state-region)      STATE_REGION="${2:?--state-region needs a value}"; shift 2 ;;
    --gpu-instance-type) GPU_INSTANCE_TYPE="${2:?--gpu-instance-type needs a value}"; shift 2 ;;
    --expected-account)  EXPECTED_ACCOUNT_CLI="${2:?--expected-account needs a value}"; shift 2 ;;
    --dry-run)           DRY_RUN=1; shift ;;
    -h|--help)           usage 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage 64 ;;
  esac
done

[ -n "$REGION" ] || { printf 'ERROR: --region is required\n' >&2; usage 64; }
if [ -n "$EXPECTED_ACCOUNT_CLI" ] && [ -n "$EXPECTED_ACCOUNT_ENV" ] \
  && [ "$EXPECTED_ACCOUNT_CLI" != "$EXPECTED_ACCOUNT_ENV" ]; then
  die "--expected-account and EXPECTED_ACCOUNT name different accounts"
fi
EXPECTED_ACCOUNT="${EXPECTED_ACCOUNT_CLI:-$EXPECTED_ACCOUNT_ENV}"
[[ "$EXPECTED_ACCOUNT" =~ ^[0-9]{12}$ ]] \
  || die "set --expected-account or EXPECTED_ACCOUNT to the intended 12-digit AWS account ID"

# Co-located with the stack by default; the live setup passes --state-region
# us-east-1 because that bucket predates the region-per-key layout.
STATE_REGION="${STATE_REGION:-$REGION}"

command -v aws >/dev/null || die "aws cli not found"

# ------------------------------------------------------------ 1. the account --
# The caller declares the account independently of the credentials. Do not infer
# authorization from a profile name or a pre-existing generated config: either
# can be stale. This assertion happens before every S3 operation, including the
# first bucket existence check.
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" \
  || die "could not resolve the caller -- no usable credentials in the environment"
[ "$ACCOUNT_ID" = "$EXPECTED_ACCOUNT" ] \
  || die "credentials resolve to account $ACCOUNT_ID, expected $EXPECTED_ACCOUNT"
log "account $ACCOUNT_ID, region $REGION, state in $STATE_REGION"

# ------------------------------------------------------ 2. the 8-GPU assertion --
# var.gpu_count is the source; this script is not a fifth copy. A mismatch is not
# cosmetic: a checkpoint written by 8 ranks is unreadable by 4, so the replacement
# node crash-loops identically on every retry instead of degrading.
first_int() { grep -oE "$1" "$2" | head -1 | grep -oE '[0-9]+'; }

TF_VARS="$ROOT/terraform/live/eks/variables.tf"
WORKFLOW="$ROOT/k8s/workflow-base-train.yaml"
ENTRYPOINT="$ROOT/docker/entrypoint.sh"

GPU_COUNT="$(sed -n '/variable "gpu_count"/,/^}/p' "$TF_VARS" | grep -oE 'default *= *[0-9]+' | grep -oE '[0-9]+')"
[ -n "$GPU_COUNT" ] || die "no default for var.gpu_count in $TF_VARS"

k8s_gpus="$(first_int 'nvidia\.com/gpu: *[0-9]+' "$WORKFLOW")"
nproc="$(first_int 'NPROC:=[0-9]+' "$ENTRYPOINT")"
[ "$k8s_gpus" = "$GPU_COUNT" ] \
  || die "k8s/workflow-base-train.yaml requests ${k8s_gpus:-?} GPUs, var.gpu_count is $GPU_COUNT"
[ "$nproc" = "$GPU_COUNT" ] \
  || die "docker/entrypoint.sh NPROC defaults to ${nproc:-?}, var.gpu_count is $GPU_COUNT"

VCPU=""
if [ -n "$GPU_INSTANCE_TYPE" ]; then
  read -r gpus VCPU <<<"$(aws ec2 describe-instance-types --region "$REGION" \
    --instance-types "$GPU_INSTANCE_TYPE" \
    --query 'InstanceTypes[0].[GpuInfo.Gpus[0].Count,VCpuInfo.DefaultVCpus]' \
    --output text 2>/dev/null || true)"
  case "$gpus" in ''|None) die "$GPU_INSTANCE_TYPE does not exist in $REGION" ;; esac
  [ "$gpus" = "$GPU_COUNT" ] \
    || die "$GPU_INSTANCE_TYPE has ${gpus:-0} GPUs; demo requires $GPU_COUNT"
fi
log "8-GPU invariant holds: var.gpu_count, workflow, entrypoint${GPU_INSTANCE_TYPE:+, $GPU_INSTANCE_TYPE} all read $GPU_COUNT"

# ------------------------------------------- 3. offered here, and in which AZs --
# Offerings say the type is SOLD in an AZ, never that a host is free -- only
# find-capacity.sh --create answers that. This catches an impossible pair early.
if [ -n "$GPU_INSTANCE_TYPE" ]; then
  OFFERED_AZS="$(aws ec2 describe-instance-type-offerings --region "$REGION" \
    --location-type availability-zone \
    --filters "Name=instance-type,Values=$GPU_INSTANCE_TYPE" \
    --query 'InstanceTypeOfferings[].Location' --output text | tr '\t' ' ')"
  [ -n "$OFFERED_AZS" ] \
    || die "$GPU_INSTANCE_TYPE is not offered in any $REGION AZ -- pick another region or type"
  log "$GPU_INSTANCE_TYPE offered in: $OFFERED_AZS"
fi

# --------------------------------------------------------- 4. the quota check --
# TWO nodes: EC2 releases a slot at 'terminated', not 'shutting-down', so the
# drained node and its replacement are both held during the handoff. A warning,
# not a failure -- a limit increase takes days and this must stay usable.
if [ -n "$VCPU" ] && [ "$VCPU" != "None" ]; then
  need=$((VCPU * 2))
  quota="$(aws service-quotas get-service-quota --region "$REGION" \
    --service-code ec2 --quota-code "$QUOTA_CODE" \
    --query 'Quota.Value' --output text 2>/dev/null || echo 0)"
  quota="${quota%.*}"
  if [ "${quota:-0}" -lt "$need" ]; then
    warn "quota $QUOTA_CODE in $REGION is ${quota:-0} vCPU, the demo needs $need (2 x $GPU_INSTANCE_TYPE). Request an increase; this is not fatal."
  else
    log "quota $QUOTA_CODE in $REGION is $quota vCPU, need $need"
  fi
fi

# ------------------------------------------------------- 5. the state bucket --
# The S3 backend cannot create its own bucket. One per account, with state keyed
# per region, so no region suffix is needed in the bucket name.
STATE_BUCKET="${CLUSTER_NAME}-tfstate-${ACCOUNT_ID}"
if aws s3api head-bucket --bucket "$STATE_BUCKET" --region "$STATE_REGION" >/dev/null 2>&1; then
  # head-bucket FOLLOWS the cross-region redirect, so it says "yes" for a bucket
  # that lives elsewhere -- which is how backend.hcl ends up naming the wrong
  # region while everything still appears to work. Ask where it actually is.
  ACTUAL="$(aws s3api get-bucket-location --bucket "$STATE_BUCKET" \
              --query LocationConstraint --output text 2>/dev/null)"
  # None/null means us-east-1, the API's implicit default.
  [ "$ACTUAL" = "None" ] || [ "$ACTUAL" = "null" ] && ACTUAL=us-east-1
  if [ -n "$ACTUAL" ] && [ "$ACTUAL" != "$STATE_REGION" ]; then
    log "state bucket $STATE_BUCKET exists in $ACTUAL, not $STATE_REGION -- using $ACTUAL"
    log "  (pass --state-region $ACTUAL to silence this, or use a different CLUSTER_NAME)"
    STATE_REGION="$ACTUAL"
  else
    log "state bucket $STATE_BUCKET already exists in $STATE_REGION"
  fi
elif [ "$DRY_RUN" = 1 ]; then
  log "would create state bucket $STATE_BUCKET in $STATE_REGION"
else
  log "creating state bucket $STATE_BUCKET in $STATE_REGION"
  # Naming us-east-1 explicitly is an InvalidLocationConstraint error.
  if [ "$STATE_REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$STATE_BUCKET" --region "$STATE_REGION" >/dev/null
  else
    aws s3api create-bucket --bucket "$STATE_BUCKET" --region "$STATE_REGION" \
      --create-bucket-configuration "LocationConstraint=$STATE_REGION" >/dev/null
  fi
  # No put-bucket-encryption: SSE-S3 is the default since Jan 2023.
fi

# Enforce these on every non-dry run, not only bucket creation. That makes
# configure.sh repair drift instead of silently accepting a backend whose
# recovery or exposure controls were weakened out of band.
if [ "$DRY_RUN" = 1 ]; then
  log "would enforce versioning, public access blocking and TLS-only access on $STATE_BUCKET"
else
  aws s3api put-bucket-versioning --bucket "$STATE_BUCKET" --region "$STATE_REGION" \
    --versioning-configuration Status=Enabled >/dev/null
  aws s3api put-public-access-block --bucket "$STATE_BUCKET" --region "$STATE_REGION" \
    --public-access-block-configuration \
    'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true' >/dev/null

  # The backend uses TLS, and this bucket policy makes that invariant fail closed
  # for every other client too. Derive the ARN partition so the script remains
  # usable outside the standard aws partition.
  PARTITION="$(aws sts get-caller-identity --query Arn --output text | cut -d: -f2)"
  TLS_POLICY="$(printf '{
  "Version":"2012-10-17",
  "Statement":[{
    "Sid":"DenyInsecureTransport",
    "Effect":"Deny",
    "Principal":"*",
    "Action":"s3:*",
    "Resource":["arn:%s:s3:::%s","arn:%s:s3:::%s/*"],
    "Condition":{"Bool":{"aws:SecureTransport":"false"}}
  }]
}' "$PARTITION" "$STATE_BUCKET" "$PARTITION" "$STATE_BUCKET")"
  aws s3api put-bucket-policy --bucket "$STATE_BUCKET" --region "$STATE_REGION" \
    --policy "$TLS_POLICY" >/dev/null
  log "state bucket ready"
fi

# --------------------------------------------------------- 6. write the files --
WROTE=()
emit() { # emit <path>, content on stdin
  local path="$1"
  if [ "$DRY_RUN" = 1 ]; then
    printf '\n----- %s -----\n' "${path#"$ROOT"/}"
    cat
  else
    mkdir -p "$(dirname "$path")"
    cat >"$path"
    WROTE+=("${path#"$ROOT"/}")
  fi
}

# No timestamps: "idempotent" has to mean byte-identical to be checkable.
emit "$ROOT/config.env" <<EOF
# Generated by scripts/configure.sh -- the only writer. Gitignored.
# Do NOT hand-edit: backend.hcl and capacity.auto.tfvars render FROM this file,
# so an edit that is not a re-run gives you two sources for one value. Re-run it.
# Read by the Makefile and every script. Each key is overridable by an env var.
REGION=$REGION
STATE_REGION=$STATE_REGION
CLUSTER_NAME=$CLUSTER_NAME
GPU_COUNT=$GPU_COUNT
GPU_INSTANCE_TYPES=$GPU_INSTANCE_TYPE
EXPECTED_ACCOUNT=$EXPECTED_ACCOUNT
NANOCHAT_DIR=$NANOCHAT_DIR
AWS_PROFILE=${AWS_PROFILE:-}
AZ_COUNT=$AZ_COUNT
EOF

# use_lockfile is the whole locking story: no DynamoDB table to fall back on.
# No `key` -- the Makefile injects a region-scoped one per root.
for root in eks foundation; do
  emit "$ROOT/terraform/live/$root/backend.hcl" <<EOF
# Generated by scripts/configure.sh. Gitignored.
# \`terraform init\` gets this via -backend-config=backend.hcl, plus a second
# -backend-config carrying key=$root-<region>/terraform.tfstate from the Makefile.
bucket       = "$STATE_BUCKET"
region       = "$STATE_REGION"
encrypt      = true
use_lockfile = true
EOF
done

# The eks root's only region source. Foundation reads TF_VAR_aws_region, exported
# by the Makefile from this same file. Built outside the heredoc: an unquoted
# heredoc leaves \" backslashed inside a ${x:+...} expansion.
tfvars_types="[]"
[ -z "$GPU_INSTANCE_TYPE" ] || tfvars_types="[\"$GPU_INSTANCE_TYPE\"]"
emit "$ROOT/terraform/live/eks/capacity.auto.tfvars" <<EOF
# Generated by scripts/configure.sh, rewritten by find-capacity.sh when it opens
# an ODCR. Gitignored: a tracked copy is a second source for region and type.
aws_region = "$REGION"
# Empty list = select on Karpenter attributes alone, so any family with
# $GPU_COUNT GPUs, >20 GB of GPU memory and local NVMe is admissible.
gpu_instance_types = $tfvars_types
EOF

# ------------------------------------------------------------- 7. what's next --
if [ "$DRY_RUN" = 1 ]; then
  printf '\n'
  log "--dry-run: nothing written, nothing created"
else
  log "wrote: ${WROTE[*]}"
fi
cat >&2 <<EOF

  account       : $ACCOUNT_ID
  region        : $REGION
  state bucket  : s3://$STATE_BUCKET ($STATE_REGION), keyed {foundation,eks}-$REGION/
  gpu type      : ${GPU_INSTANCE_TYPE:-<attribute selection, no literal type>}
  az coverage   : ${AZ_COUNT:-every AZ in the region}

next: make foundation-plan && make foundation-show
after review: make foundation-apply
then: scripts/find-capacity.sh --create   # opens a BILLABLE reservation
then: export TF_VAR_cluster_endpoint_public_access_cidrs='["<your-egress-ip>/32"]'
then: make cluster-plan && make cluster-show
after review: make cluster-apply
EOF
