#!/usr/bin/env bash
# Store the W&B API key in Secrets Manager. Read from stdin or WANDB_API_KEY --
# never a Terraform variable (it would land in state), never baked into the image.
set -euo pipefail

log() { printf '[wandb %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Env wins over config.env, so stash the keys this script reads before sourcing.
HERE="$(cd "$(dirname "$0")/.." && pwd)"
env_REGION="${REGION:-}"
env_CLUSTER_NAME="${CLUSTER_NAME:-${CLUSTER:-}}"
env_PROFILE="${AWS_PROFILE:-}"
# shellcheck source=/dev/null
[ -f "$HERE/config.env" ] && . "$HERE/config.env"
REGION="${env_REGION:-${REGION:-}}"
[ -n "$REGION" ] || die "no REGION -- run scripts/configure.sh, or pass REGION=<r>"
CLUSTER_NAME="${env_CLUSTER_NAME:-${CLUSTER_NAME:-nanochat-demo}}"
AWS_PROFILE="${env_PROFILE:-${AWS_PROFILE:-}}"
if [ -n "$AWS_PROFILE" ]; then export AWS_PROFILE; else unset AWS_PROFILE; fi

SECRET_NAME="${CLUSTER_NAME}/wandb-api-key"

KEY="${WANDB_API_KEY:-}"
if [ -z "$KEY" ]; then
  # -s so the key is not echoed to the terminal or captured in scrollback.
  read -rsp "W&B API key (input hidden): " KEY
  echo >&2
fi
[ -n "$KEY" ] || die "no key provided"
[ "${#KEY}" -ge 20 ] || die "that does not look like a W&B API key (too short)"

log "writing to Secrets Manager: ${SECRET_NAME}"
aws secretsmanager put-secret-value \
  --region "$REGION" \
  --secret-id "$SECRET_NAME" \
  --secret-string "$KEY" \
  --query 'VersionId' --output text >/dev/null \
  || die "secret ${SECRET_NAME} not found -- apply terraform/live/foundation first"

# NOT mirrored into a Kubernetes Secret: docker/entrypoint.sh reads this straight
# from Secrets Manager via Pod Identity, so a mirror is a stale second copy.
log "done. Submit with WANDB_RUN set to something other than 'dummy':"
log "  make run WANDB_RUN=nanochat-interrupt-demo"
