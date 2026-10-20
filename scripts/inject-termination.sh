#!/usr/bin/env bash
# Inject a termination into Karpenter for the node currently running the training
# pod, and watch the recovery propagate.
#
# Not AWS FIS: its aws:ec2:send-spot-instance-interruptions action only targets
# aws:ec2:spot-instance, so it cannot drive a node on on-demand or reserved
# capacity. The EventBridge event instead goes straight onto Karpenter's
# interruption queue, which drives the IDENTICAL taint/drain/replace path on any
# capacity type. Real Spot changes the trigger, not the behaviour under test.
set -euo pipefail

log() { printf '\033[1;34m[inject %s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$HERE/terraform/live/eks"

# Env wins over config.env, so stash the keys this script reads before sourcing.
env_REGION="${REGION:-}"
env_PROFILE="${AWS_PROFILE:-}"
# shellcheck source=/dev/null
[ -f "$HERE/config.env" ] && . "$HERE/config.env"
REGION="${env_REGION:-${REGION:-}}"
[ -n "$REGION" ] || die "no REGION -- run scripts/configure.sh, or pass REGION=<r>"
AWS_PROFILE="${env_PROFILE:-${AWS_PROFILE:-}}"
if [ -n "$AWS_PROFILE" ]; then export AWS_PROFILE; else unset AWS_PROFILE; fi

QUEUE_URL="$(cd "$TF_DIR" && terraform output -raw karpenter_interruption_queue_url)"
[ -n "$QUEUE_URL" ] || die "could not read the Karpenter interruption queue URL from terraform output"

# From the RUNNING pod, not items[0] of the nodepool: during a handoff two GPU
# nodes exist in no guaranteed order, so that query can hand back the replacement
# and interrupt the pod that just recovered.
POD="$(kubectl get pods -l workflows.argoproj.io/workflow \
         --field-selector status.phase=Running \
         -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "$POD" ] || die "no Running workflow pod. Is the training stage up yet?"
NODE="$(kubectl get pod "$POD" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
[ -n "$NODE" ] || die "pod $POD is not scheduled to a node yet"

# Only ever a GPU node: a CPU one would drain the prep stages and prove nothing.
kubectl get node "$NODE" -o jsonpath='{.metadata.labels.karpenter\.sh/nodepool}' 2>/dev/null \
  | grep -q '^gpu-nanochat$' \
  || die "node $NODE is not in nodepool gpu-nanochat (pod $POD may be a prep stage)"

INSTANCE_ID="$(kubectl get node "$NODE" -o jsonpath='{.spec.providerID}' | awk -F/ '{print $NF}')"
[ -n "$INSTANCE_ID" ] || die "could not resolve an instance ID from node $NODE"

# Partition off the caller's own ARN, not the 'aws' literal: resources[] below
# must be a faithful copy of the event EventBridge would have sent.
read -r ACCOUNT_ID CALLER_ARN <<<"$(aws sts get-caller-identity \
  --query '[Account,Arn]' --output text)"
PARTITION="$(printf '%s' "$CALLER_ARN" | cut -d: -f2)"

log "target node     : $NODE"
log "target instance : $INSTANCE_ID"
log "interruption q  : ${QUEUE_URL##*/}"

echo
kubectl get pods -l workflows.argoproj.io/workflow -o wide 2>/dev/null | head -8 || true
echo

# --yes for contexts with no TTY, where `read` hits EOF and aborts opaquely.
if [ "${1:-}" = "--yes" ]; then
  log "--yes given; injecting without a prompt"
else
  if ! read -r -p "Send a Spot interruption warning for ${INSTANCE_ID}? [y/N] " confirm; then
    die "no terminal to confirm on. Re-run with --yes."
  fi
  [[ "$confirm" == "y" || "$confirm" == "Y" ]] || die "aborted"
fi

BODY=$(cat <<EOF
{
  "version": "0",
  "id": "$(uuidgen | tr '[:upper:]' '[:lower:]')",
  "detail-type": "EC2 Spot Instance Interruption Warning",
  "source": "aws.ec2",
  "account": "${ACCOUNT_ID}",
  "time": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "region": "${REGION}",
  "resources": ["arn:${PARTITION}:ec2:${REGION}:${ACCOUNT_ID}:instance/${INSTANCE_ID}"],
  "detail": {
    "instance-id": "${INSTANCE_ID}",
    "instance-action": "terminate"
  }
}
EOF
)

log "enqueueing interruption warning"
aws sqs send-message --region "$REGION" \
  --queue-url "$QUEUE_URL" \
  --message-body "$BODY" \
  --query MessageId --output text

cat <<'EOF'

Injected. What to watch, in four terminals:

  1. Karpenter reacting (taint -> drain -> replacement NodeClaim):
       kubectl -n kube-system logs -l app.kubernetes.io/name=karpenter -f

  2. Node lifecycle:
       kubectl get nodeclaims -w

  3. The training pod draining and a fresh one resuming:
       kubectl get pods -w

  4. How much work was actually lost (the quantitative claim):
       aws s3 ls --recursive <S3_URI>/base_checkpoints/ | sort -k1,2

Expect: SIGTERM to the pod -> final checkpoint sync -> exit 1 -> Argo retry ->
pod schedules on the replacement node -> "RESUMING from step N" in its logs.
EOF
