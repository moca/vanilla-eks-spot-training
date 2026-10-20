#!/usr/bin/env bash
# Find a region/AZ where we can actually get an 8-GPU node, and open an ODCR there.
#
# Two independent failure modes with different fixes: no quota (limit increase,
# days) and no free hosts (move region, minutes). Phase 1 is read-only and says
# which you are hitting. Phase 2 is the only real capacity probe there is --
# there is no dry-run for CreateCapacityReservation.
#
# Usage:
#   scripts/find-capacity.sh                 # report only, no charges
#   scripts/find-capacity.sh --probe         # create+cancel each row to MEASURE
#   scripts/find-capacity.sh --create        # open the first ODCR that succeeds
#
# --probe surveys regions you have not chosen yet; once chosen, --create costs the
# same on success and KEEPS what it proved instead of racing to reacquire it.
#
# Env overrides: REGIONS, INSTANCE_TYPES, COUNT, HOURS, RATE
set -euo pipefail

log()  { printf '\033[1;34m[capacity]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[capacity]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# REQUIRED, not optional: this creates billable reservations, so it needs a
# declared target account to assert against. An absent config is a missing guard.
CONFIG="$(cd "$(dirname "$0")/.." && pwd)/config.env"
[ -f "$CONFIG" ] || die "no $CONFIG -- run scripts/configure.sh --region <r> --expected-account <12-digit-id> first"

# Env wins over config.env, so stash what the caller exported before sourcing.
env_REGIONS="${REGIONS:-}"
env_TYPES="${INSTANCE_TYPES:-}"
env_ACCOUNT="${EXPECTED_ACCOUNT:-}"
env_PROFILE="${AWS_PROFILE:-}"
env_CLUSTER="${CLUSTER_NAME:-}"
RATE_ENV="${RATE:-}"
# shellcheck source=/dev/null
. "$CONFIG"

# An ambient AWS_PROFILE may win. The assertion below is what stops it
# reaching the wrong account, and it is stronger than a pinned profile name.
AWS_PROFILE="${env_PROFILE:-${AWS_PROFILE:-}}"
if [ -n "$AWS_PROFILE" ]; then export AWS_PROFILE; else unset AWS_PROFILE; fi

EXPECTED_ACCOUNT="${env_ACCOUNT:-${EXPECTED_ACCOUNT:-}}"
[ -n "$EXPECTED_ACCOUNT" ] \
  || die "EXPECTED_ACCOUNT is empty in $CONFIG -- re-run scripts/configure.sh"

# Must match var.cluster_name: the EC2NodeClass selects the ODCR by this tag.
CLUSTER_NAME="${env_CLUSTER:-${CLUSTER_NAME:-nanochat-demo}}"

# One region by default: config.env names the target. A multi-region sweep is the
# --probe case and takes an explicit list:
#   REGIONS="<r1> <r2>" scripts/find-capacity.sh --probe
# No preferred ordering is recommended here -- pools move daily, so measure.
REGIONS="${env_REGIONS:-${REGION:-}}"
[ -n "$REGIONS" ] || die "no REGION in $CONFIG and no REGIONS in the environment"

# Normally empty because runtime selection is attribute-based, but
# CreateCapacityReservation needs one concrete type, so fall back to the 8-GPU
# 'g' types. No 12xlarge (4 GPUs, incompatible with the fixed world size); no g7e
# (zero free hosts at every sizing on 2026-09-29 and 2026-10-08).
INSTANCE_TYPES="${env_TYPES:-${GPU_INSTANCE_TYPES:-}}"
INSTANCE_TYPES="${INSTANCE_TYPES:-g6e.48xlarge g5.48xlarge g6.48xlarge}"

# Two, not one: EC2 releases a slot at 'terminated', not 'shutting-down', so the
# drained node and its replacement both hold one during the handoff. With one
# slot the NodeClaim fails and the demo shows a stall that reads as a bug.
COUNT="${COUNT:-2}"
# 0 = EndDateType=unlimited: never expires, bills until cancelled. Worth it when
# capacity is scarcer than money -- an EXPIRED reservation cannot be modified,
# only re-created, which re-rolls the capacity dice.
HOURS="${HOURS:-4}"

# Order-of-magnitude only; real rates vary 10-20% by region. Per-family because
# the 48xlarge spread is ~$13-98/hr. us-east-1, 2026-10-08.
rate_for() {
  case "$1" in
    p5*)     echo 98 ;;
    p4d*)    echo 33 ;;
    g6e*)    echo 30 ;;
    g5*)     echo 17 ;;
    g6*)     echo 14 ;;
    # Unknown: assume the worst. The dangerous error is "cheaper than it is".
    *)       echo 98 ;;
  esac
}

# NOT interchangeable: L-DB2E81BA covers G and VT only, so asking it about a p*
# type made the GATES column say "quota fits" off another pool's number.
quota_code_for() {
  case "$1" in
    p*) echo L-417A185B ;;  # On-Demand P
    *)  echo L-DB2E81BA ;;  # On-Demand G and VT
  esac
}

TFVARS="$(cd "$(dirname "$0")/.." && pwd)/terraform/live/eks/capacity.auto.tfvars"

CREATE=0
PROBE=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --create) CREATE=1 ;;
    # Measure real capacity without keeping any: create, record, cancel at once.
    --probe) PROBE=1; CREATE=1 ;;
    # For contexts with no TTY. Typing this flag IS the confirmation -- not for
    # an agent or CI to supply on your behalf, because it confirms a charge.
    --yes) ASSUME_YES=1 ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; exit 64 ;;
  esac
done

command -v aws >/dev/null || die "aws cli not found"
# Fatal, and before any billable call: a wrong profile, a stale SSO session or a
# copied config.env stops here rather than billing someone else.
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
[ "$ACCOUNT" = "$EXPECTED_ACCOUNT" ] \
  || die "ambient credentials resolve to account $ACCOUNT, but $CONFIG expects $EXPECTED_ACCOUNT"
log "account $ACCOUNT (profile ${AWS_PROFILE:-ambient}), reserving ${COUNT}x for ${HOURS}h"
echo

# ---------------------------------------------------------------- phase 1 ----
# Rows clearing the quota and offering gates. NOT a statement that capacity
# exists: no public API reports free hosts, so every row is 'worth attempting'.
CANDIDATES=()
printf '%-16s %-16s %-22s %-8s %s\n' REGION TYPE AZ QUOTA 'GATES'

for region in $REGIONS; do
  for itype in $INSTANCE_TYPES; do
    vcpus="$(aws ec2 describe-instance-types --region "$region" \
               --instance-types "$itype" \
               --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus' \
               --output text 2>/dev/null || true)"
    # Empty/None: the type does not exist in this region.
    case "$vcpus" in ''|None) continue ;; esac

    need=$((vcpus * COUNT))
    qcode="$(quota_code_for "$itype")"
    quota="$(aws service-quotas get-service-quota --region "$region" \
               --service-code ec2 --quota-code "$qcode" \
               --query 'Quota.Value' --output text 2>/dev/null || echo 0)"
    quota="${quota%.*}"

    if [ "${quota:-0}" -lt "$need" ]; then
      printf '%-16s %-16s %-22s %-8s %s\n' "$region" "$itype" '-' "$quota" \
        "SKIP: need $need vCPU, request an increase for $qcode"
      continue
    fi

    azs="$(aws ec2 describe-instance-type-offerings --region "$region" \
             --location-type availability-zone \
             --filters "Name=instance-type,Values=$itype" \
             --query 'sort(InstanceTypeOfferings[].Location)' --output text 2>/dev/null || true)"
    if [ -z "$azs" ]; then
      printf '%-16s %-16s %-22s %-8s %s\n' "$region" "$itype" '-' "$quota" \
        "SKIP: not offered in any AZ"
      continue
    fi

    for az in $azs; do
      printf '%-16s %-16s %-22s %-8s %s\n' "$region" "$itype" "$az" "$quota" \
        "quota+offered ($qcode), capacity UNKNOWN (need $need vCPU)"
      CANDIDATES+=("$region|$itype|$az")
    done
  done
done

echo
[ "${#CANDIDATES[@]}" -gt 0 ] || die "nothing clears both the quota and offering gates. The SKIP lines above name the quota code to raise."
log "${#CANDIDATES[@]} row(s) clear quota + offering -- none of them is known to have capacity"

# Priced off the row we would attempt FIRST, so the estimate follows the order.
IFS='|' read -r _ TYPE1 _ <<<"${CANDIDATES[0]}"
RATE="${RATE_ENV:-$(rate_for "$TYPE1")}"
EST=$((RATE * COUNT * HOURS))
# Per-second billing with a 60s minimum, so a create+cancel costs a minute. Up.
PROBE_EST=$(((RATE * COUNT + 59) / 60))

if [ "$CREATE" -eq 0 ]; then
  cat <<EOF

Report only -- nothing created, nothing charged.

READ 'GATES' LITERALLY: the quota fits and the type is sold in that AZ. It does
NOT mean a host is free. Asking for the reservation is the only probe there is.

  scripts/find-capacity.sh --probe    # measure, ~\$${PROBE_EST} per row that HAS capacity
  scripts/find-capacity.sh --create   # keep the first one that succeeds
EOF
  exit 0
fi

# ---------------------------------------------------------------- phase 2 ----
if [ "$PROBE" -eq 1 ]; then
  cat <<EOF

Probe = create, record, cancel immediately. Nothing lasting is reserved, but it
is not free: each row that SUCCEEDS costs ~\$${PROBE_EST} (${COUNT} x \$${RATE}/hr for a
minute, priced for ${TYPE1}). Failures cost nothing. Worst case, every row:
~\$$((PROBE_EST * ${#CANDIDATES[@]})).

Survey only -- if the region is already chosen, --create costs the same on
success and keeps what it proved.

EOF
elif [ "$HOURS" -eq 0 ]; then
  cat <<EOF

*** OPEN-ENDED RESERVATION -- NOTHING WILL STOP THE METER BUT YOU ***

EndDateType=unlimited bills at the full On-Demand rate from creation, whether or
not anything is running in it, until you cancel:

  ${COUNT}x ${TYPE1}  ~\$$((RATE * COUNT))/hr  ~\$$((RATE * COUNT * 24))/day  ~\$$((RATE * COUNT * 24 * 7))/week

A forgotten weekend is ~\$$((RATE * COUNT * 24 * 2)). Use \`make odcr\` and \`make odcr-cancel\`.

EOF
else
  cat <<EOF

An ODCR bills at the full On-Demand rate from creation, whether or not anything
runs in it. ${TYPE1} is ~\$${RATE}/hr, so ${COUNT}x for ${HOURS}h is ~\$${EST} -- budget more,
'limited' expires within an HOUR of the stated time.

--end-date-type limited self-cancels after ${HOURS}h; --instance-match-criteria
targeted means only workloads naming the reservation can consume it.

Do NOT let it lapse: an expired reservation can only be re-created, which
re-rolls the capacity dice. Extend instead:
  aws ec2 modify-capacity-reservation --region <r> --capacity-reservation-id <id> \\
    --end-date-type unlimited

EOF
fi

if [ "$ASSUME_YES" -eq 1 ]; then
  log "--yes given, proceeding without a prompt"
else
  # No TTY aborts correctly, but say why -- a silent abort reads as a failure.
  if ! read -r -p "Proceed? [y/N] " confirm; then
    die "no terminal to confirm on. Re-run with --yes if you accept the charge."
  fi
  [[ "$confirm" == "y" || "$confirm" == "Y" ]] || die "aborted"
fi

if [ "$HOURS" -eq 0 ]; then
  END_DATE="never (unlimited)"
  END_ARGS=(--end-date-type unlimited)
else
  END_DATE="$(date -u -v+"${HOURS}"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
              || date -u -d "+${HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)"
  END_ARGS=(--end-date-type limited --end-date "$END_DATE")
fi

# Echoes the reservation id, or the AWS error and non-zero. project=$CLUSTER_NAME
# is what karpenter.tf's capacityReservationSelectorTerms matches -- a mismatch
# means the node silently launches on-demand.
try_reserve() {
  aws ec2 create-capacity-reservation --region "$1" \
    --instance-type "$2" \
    --instance-platform Linux/UNIX \
    --availability-zone "$3" \
    --instance-count "$COUNT" \
    --instance-match-criteria targeted \
    "${END_ARGS[@]}" \
    --tag-specifications \
      "ResourceType=capacity-reservation,Tags=[{Key=Name,Value=$CLUSTER_NAME},{Key=project,Value=$CLUSTER_NAME}]" \
    --query 'CapacityReservation.CapacityReservationId' \
    --output text 2>&1
}

# Compresses an AWS error blob to the distinction that matters.
classify() {
  case "$1" in
    *InsufficientInstanceCapacity*|*InsufficientCapacity*) echo "NO CAPACITY" ;;
    *RequestLimitExceeded*)                                echo "THROTTLED" ;;
    *VcpuLimitExceeded*|*MaxCapacityReservation*)          echo "QUOTA" ;;
    *)                                                     echo "ERROR: ${1##*: }" ;;
  esac
}

if [ "$PROBE" -eq 1 ]; then
  RESULTS=()
  FOUND=0
  for c in "${CANDIDATES[@]}"; do
    IFS='|' read -r region itype az <<<"$c"
    log "probing $itype in $az"

    # Retry throttles rather than recording them: a wide sweep is dozens of
    # serial calls, and RequestLimitExceeded reads as a false 'no capacity'.
    verdict=""
    for attempt in 1 2 3; do
      if out="$(try_reserve "$region" "$itype" "$az")"; then
        # Cancel at once: the point was the answer, not the capacity.
        aws ec2 cancel-capacity-reservation --region "$region" \
          --capacity-reservation-id "$out" >/dev/null 2>&1 \
          || warn "PROBE LEAKED $out in $region -- cancel it by hand, it is billing"
        verdict="HAS CAPACITY (${COUNT}x)"
        FOUND=$((FOUND + 1))
        break
      fi
      verdict="$(classify "$out")"
      [ "$verdict" = "THROTTLED" ] || break
      warn "throttled, retry $attempt in $((attempt * 10))s"
      sleep $((attempt * 10))
    done

    RESULTS+=("$region|$itype|$az|$verdict")
  done

  echo
  printf '%-16s %-16s %-22s %s\n' REGION TYPE AZ 'ACTUAL CAPACITY'
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r g t a v <<<"$r"
    printf '%-16s %-16s %-22s %s\n' "$g" "$t" "$a" "$v"
  done
  echo
  log "$FOUND of ${#RESULTS[@]} row(s) had capacity; cost ~\$$((FOUND * PROBE_EST))"
  log "nothing is reserved now. Re-run with --create, narrowed to a row that passed."
  exit 0
fi

for c in "${CANDIDATES[@]}"; do
  IFS='|' read -r region itype az <<<"$c"
  log "trying $itype in $az"

  if out="$(try_reserve "$region" "$itype" "$az")"; then
    log "GOT IT: $out"
    # gpu_instance_types only NARROWS, and instance-category 'g' is one of the
    # requirements, so a reserved p-type intersects to nothing: the ODCR
    # bills while the NodeClaim sits Pending. Say it now, not in 20 minutes.
    case "$itype" in
      g*) ;;
      *) warn "$itype is outside instance-category 'g' -- widen that requirement in terraform/live/eks/karpenter.tf or this reservation cannot be consumed" ;;
    esac
    cat >"$TFVARS" <<EOF
# Generated by scripts/find-capacity.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# ODCR ${out} expires: ${END_DATE}. Regenerate after it ends.
aws_region         = "${region}"
gpu_instance_types = ["${itype}"]
EOF
    cat <<EOF

Wrote $TFVARS

  region          : $region
  availability zone: $az
  instance type   : $itype
  reservation     : $out
  expires         : $END_DATE

The clock is now running. Run the demo and release the reservation:

  make run          # submit the DAG
  make inject       # interrupt, watch the replacement land in the reservation
  aws ec2 cancel-capacity-reservation --region $region --capacity-reservation-id $out

Open this LAST: the cluster build and image push need no GPU, so running them
first keeps them off the meter. Otherwise you pay ~\$${RATE}/hr/instance to watch
terraform apply.

If it expires mid-demo, running instances are not terminated, just unreserved.
The NodePool falls back to on-demand so the run continues -- but with no
second reserved slot for the handoff, "resumes within one save interval" drops
from by-design to best-effort, at full price. Confirm which you got:

  kubectl get node -l karpenter.sh/nodepool=gpu-nanochat \\
    -o jsonpath='{.items[*].metadata.labels.karpenter\\.sh/capacity-type}'

'limited' expires within an HOUR of the stated time, so a ${HOURS}h window can
bill closer to $((HOURS + 1)).
EOF
    exit 0
  fi

  verdict="$(classify "$out")"
  warn "$az: $verdict"
  [ "$verdict" = "THROTTLED" ] && sleep 10
done

die "every row refused. Nothing was charged. Retry later, widen REGIONS/INSTANCE_TYPES, or drop COUNT."
