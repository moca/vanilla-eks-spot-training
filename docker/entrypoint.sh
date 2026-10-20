#!/usr/bin/env bash
# Resumable nanochat stage runner.  Usage: entrypoint.sh <dataset|tokenizer|train>
#
# Every stage is idempotent or resumable, so a kill costs at most one save
# interval. State lives in S3; local disk is scratch, because the node is what
# disappears. Self-checks: `phase-selfcheck`, `ckpt-selfcheck`, `sync-selfcheck`.
set -euo pipefail

STAGE="${1:?usage: entrypoint.sh <dataset|tokenizer|train>}"

: "${S3_URI:?S3_URI is required, e.g. s3://bucket/run-name}"
: "${NANOCHAT_BASE_DIR:=/data/nanochat}"
: "${NPROC:=8}"
: "${DEPTH:=12}"
: "${NUM_ITERATIONS:=400}"
: "${SAVE_EVERY:=25}"
: "${DEVICE_BATCH_SIZE:=8}"
: "${MAX_SEQ_LEN:=1024}"
: "${TOTAL_BATCH_SIZE:=65536}"
: "${NUM_SHARDS:=8}"
: "${SYNC_INTERVAL:=30}"
: "${TOK_MAX_CHARS:=500000000}"
: "${WANDB_RUN:=dummy}"
: "${CLUSTER_NAME:=nanochat-demo}"
: "${WANDB_SECRET_ID:=${CLUSTER_NAME}/wandb-api-key}"

export NANOCHAT_BASE_DIR OMP_NUM_THREADS=1

CKPT_DIR="${NANOCHAT_BASE_DIR}/base_checkpoints/d${DEPTH}"
TOKENIZER_DIR="${NANOCHAT_BASE_DIR}/tokenizer"

log() { printf '[%s %s] %s\n' "$STAGE" "$(date -u +%H:%M:%S)" "$*"; }
# Exit 1: Argo retries any non-zero, which is right for a transient S3 failure.
die() { log "FATAL: $*"; exit 1; }

# One JSON line per phase boundary on stdout -- durable and per-attempt now that
# the workflow archives logs. These are the events that used to die with the node.
#
# DO NOT DELETE THE `|| :`: it covers EPIPE/EBADF when a log reader hangs up.
# `phase sigterm` is on_term's FIRST statement, so without it a dead reader kills
# the handler before it drains. Whole-second ts because jq's fromdateiso8601
# rejects a fraction and BSD/GNU date agree on it.
#
# Self-check -- no cluster, no S3, no real stage:
#   S3_URI=- docker/entrypoint.sh phase-selfcheck | sed 's/^PHASE //' \
#     | jq -se 'map(has("step")) == [false, true]
#               and all(.[]; (.ts | test("^[0-9]{4}(-[0-9]{2}){2}T([0-9]{2}:){2}[0-9]{2}Z$"))
#                            and (.ts | fromdateiso8601) > 0)'
phase() { printf 'PHASE {"ts":"%s","phase":"%s","stage":"%s"%s}\n' \
  "$(date -u +%FT%TZ)" "$1" "$STAGE" "${2:+,\"step\":$2}" || :; }

if [ "$STAGE" = phase-selfcheck ]; then phase pod_start; phase train_launch 375; exit 0; fi

phase pod_start

# Straight from Secrets Manager under the pod's own identity. Not a k8s Secret
# (copies the value into etcd and drifts on rotation), and not the Secrets Store
# CSI driver -- a DaemonSet plus a Helm release plus a SecretProviderClass to
# deliver ONE value read ONCE. Reach for it with several secrets or several
# teams; neither is true here.
if [ -z "${WANDB_API_KEY:-}" ] && [ "${WANDB_RUN}" != "dummy" ]; then
  # stderr to a file, not /dev/null: it is the only thing that names WHY. Cost a
  # GPU run on 2026-10-01 (a secret container with no version). The value itself
  # still never reaches the log.
  if WANDB_API_KEY="$(aws secretsmanager get-secret-value \
        --secret-id "$WANDB_SECRET_ID" \
        --query SecretString --output text 2>/tmp/wandb-secret.err)"; then
    export WANDB_API_KEY
    log "fetched W&B key from Secrets Manager (${WANDB_SECRET_ID})"
  else
    # FATAL: 400 GPU-steps with no loss curve is the more expensive outcome, not
    # the cheaper one. Use WANDB_RUN=dummy to train without W&B on purpose.
    # Here rather than in wandb.init(), the earliest the key is knowable, so a
    # config error costs two seconds instead of minutes.
    # Exit 64 (EX_USAGE): k8s/workflow-base-train.yaml's retryStrategy excludes
    # it, because this failure is identical on all ten retries.
    log "FATAL: cannot read ${WANDB_SECRET_ID}, and WANDB_RUN=${WANDB_RUN} asks for W&B"
    log "FATAL: $(tr -d '\n' < /tmp/wandb-secret.err | tail -c 300)"
    exit 64
  fi
fi

# All complete steps, newest first, over a newline-separated list of BASENAMES.
# A complete step has the exact rank set 0..NPROC-1, not merely NPROC files:
# ranks 0..6 plus rank 8 must never stand in for a missing rank 7.
complete_steps() {
  local names="$1" s r n complete
  for s in $(printf '%s\n' "$names" \
               | sed -n 's/^meta_\([0-9]\{6\}\)\.json$/\1/p' | sort -rn); do
    printf '%s\n' "$names" | grep -qx "model_${s}\.pt" || continue
    n=$(printf '%s\n' "$names" | grep -cEx "optim_${s}_rank[0-9]+\.pt" || true)
    [ "$n" -eq "$NPROC" ] || continue
    complete=1
    for r in $(seq 0 $((NPROC - 1))); do
      printf '%s\n' "$names" | grep -qx "optim_${s}_rank${r}\.pt" \
        || { complete=0; break; }
    done
    [ "$complete" -eq 1 ] || continue
    echo "$s"
  done
}

# Highest complete step. ONE rule for both local disk and S3 callers.
complete_step() {
  complete_steps "$1" | sed -n '1p'
}

# Checkpoints are excluded from the broad sync. nanochat publishes each local
# artifact with an atomic rename and writes meta only after every rank finishes.
# Capture that committed set first, upload its stable payload concurrently, then
# upload meta last. A directory-wide sync could start before the rank barrier,
# miss a shard that appears during its scan, then see and publish the new meta.
sync_up() {
  aws s3 sync "${NANOCHAT_BASE_DIR}/" "${S3_URI}/" \
    --exclude 'base_checkpoints/*' --no-progress --only-show-errors || return 1

  [ -d "$CKPT_DIR" ] || return 0

  local names remote_names step r
  local includes
  names="$(ls "$CKPT_DIR" 2>/dev/null || true)"
  [ -n "$names" ] || return 0
  remote_names="$(aws s3 ls "${S3_URI}/base_checkpoints/d${DEPTH}/" \
                    | awk '{print $NF}' || true)"

  for step in $(complete_steps "$names"); do
    printf '%s\n' "$remote_names" | grep -qx "meta_${step}\.json" && continue

    includes=(--include "model_${step}.pt")
    for r in $(seq 0 $((NPROC - 1))); do
      includes+=(--include "optim_${step}_rank${r}.pt")
    done
    aws s3 cp "${CKPT_DIR}/" "${S3_URI}/base_checkpoints/d${DEPTH}/" \
      --recursive --exclude '*' "${includes[@]}" \
      --no-progress --only-show-errors || return 1
    aws s3 cp "${CKPT_DIR}/meta_${step}.json" \
      "${S3_URI}/base_checkpoints/d${DEPTH}/meta_${step}.json" \
      --no-progress --only-show-errors || return 1
    remote_names="${remote_names}"$'\n'"meta_${step}.json"
  done
}

# Unpadded, because that is what --resume-from-step takes.
last_step() {
  local s
  s="$(complete_step "$(ls "$CKPT_DIR" 2>/dev/null || true)")"
  # shellcheck disable=SC2001
  [ -z "$s" ] || echo "$s" | sed 's/^0*//'
}

# Everything EXCEPT the checkpoints, then exactly one checkpoint step. A flat
# sync pulled 31.5 of 32.5 GiB to use 2.0 (measured 2026-10-01), and the waste
# grows with num-iterations while the benefit stays flat; selecting one complete
# checkpoint keeps restore cost bounded to the state needed for one resume.
# Newest-COMPLETE, not newest: the commit-marker rule skips a half-synced step.
sync_down() {
  aws s3 sync "${S3_URI}/" "${NANOCHAT_BASE_DIR}/" \
    --exclude 'base_checkpoints/*' --no-progress --only-show-errors || return 1

  # `aws s3 ls` exits 1 on an empty prefix, which is just a fresh run.
  local step
  step="$(complete_step "$(aws s3 ls "${S3_URI}/base_checkpoints/d${DEPTH}/" \
                             | awk '{print $NF}' || true)")"
  [ -n "$step" ] || return 0

  aws s3 cp "${S3_URI}/base_checkpoints/d${DEPTH}/" "${CKPT_DIR}/" --recursive \
    --exclude '*' \
    --include "meta_${step}.json" \
    --include "model_${step}.pt" \
    --include "optim_${step}_rank*.pt" \
    --no-progress --only-show-errors || return 1
}

# Self-check for the rule above -- no cluster, no S3, no GPU:
#   S3_URI=- docker/entrypoint.sh ckpt-selfcheck
# Here, not beside phase-selfcheck, because complete_step is defined above.
if [ "$STAGE" = ckpt-selfcheck ]; then
  shards() { local s=$1 n=$2 r; for r in $(seq 0 $((n - 1))); do printf 'optim_%s_rank%s.pt\n' "$s" "$r"; done; }
  # Step 125 is mid-upload: meta and model landed, one optim shard did not --
  # what an interrupted pod's final sync leaves behind.
  NAMES="$(printf 'meta_000100.json\nmodel_000100.pt\n'; shards 000100 8
           printf 'meta_000125.json\nmodel_000125.pt\n'; shards 000125 7)"
  [ "$(complete_step "$NAMES")" = 000100 ] || { echo "FAIL: took the partial step"; exit 1; }
  WRONG_RANKS="$(printf 'meta_000125.json\nmodel_000125.pt\n'; shards 000125 7
                 printf 'optim_000125_rank8.pt\n')"
  [ -z "$(complete_step "$WRONG_RANKS")" ] \
    || { echo "FAIL: counted the wrong rank set as complete"; exit 1; }
  EXTRA_RANK="$(printf 'meta_000125.json\nmodel_000125.pt\n'; shards 000125 8
                printf 'optim_000125_rank8.pt\n')"
  [ -z "$(complete_step "$EXTRA_RANK")" ] \
    || { echo "FAIL: accepted an optimizer rank outside the world size"; exit 1; }
  # A commit marker with nothing behind it, and the fresh-run case.
  [ -z "$(complete_step 'meta_000100.json')" ] || { echo "FAIL: took a bare marker"; exit 1; }
  [ -z "$(complete_step '')" ] || { echo "FAIL: invented a step from nothing"; exit 1; }
  echo "ckpt-selfcheck OK"
  exit 0
fi

if [ "$STAGE" = sync-selfcheck ]; then
  SELF_DIR="$(mktemp -d)"
  trap 'rm -rf "$SELF_DIR"' EXIT
  NANOCHAT_BASE_DIR="$SELF_DIR/nanochat"
  CKPT_DIR="${NANOCHAT_BASE_DIR}/base_checkpoints/d${DEPTH}"
  CALLS="$SELF_DIR/aws-calls"
  mkdir -p "$CKPT_DIR"

  for name in meta_000100.json model_000100.pt; do
    : >"$CKPT_DIR/$name"
  done
  for r in $(seq 0 $((NPROC - 1))); do
    : >"$CKPT_DIR/optim_000100_rank${r}.pt"
  done
  # Newer but incomplete: it must never be uploaded.
  : >"$CKPT_DIR/meta_000125.json"
  : >"$CKPT_DIR/model_000125.pt"
  for r in $(seq 0 $((NPROC - 2))); do
    : >"$CKPT_DIR/optim_000125_rank${r}.pt"
  done

  aws() {
    printf '%s\n' "$*" >>"$CALLS"
    [ "${1:-} ${2:-}" != "s3 ls" ]
  }

  sync_up || { echo "FAIL: fake sync failed"; exit 1; }
  [ "$(wc -l <"$CALLS" | tr -d ' ')" -eq 4 ] \
    || { echo "FAIL: unexpected AWS call count"; cat "$CALLS"; exit 1; }
  ! grep -q '000125' "$CALLS" \
    || { echo "FAIL: uploaded an incomplete step"; cat "$CALLS"; exit 1; }
  payload_line="$(grep -n -- '--include model_000100.pt' "$CALLS" | cut -d: -f1)"
  marker_line="$(grep -n 'meta_000100.json' "$CALLS" | cut -d: -f1)"
  [ -n "$payload_line" ] && [ -n "$marker_line" ] && [ "$payload_line" -lt "$marker_line" ] \
    || { echo "FAIL: commit marker was not uploaded last"; cat "$CALLS"; exit 1; }
  for r in $(seq 0 $((NPROC - 1))); do
    grep -q -- "--include optim_000100_rank${r}.pt" "$CALLS" \
      || { echo "FAIL: rank ${r} was not uploaded"; cat "$CALLS"; exit 1; }
  done
  echo "sync-selfcheck OK"
  exit 0
fi

mkdir -p "$NANOCHAT_BASE_DIR"

# Without this the failure is invisible: training runs to completion having
# persisted nothing. Write a marker rather than list -- `aws s3 ls` exits 1 on an
# empty prefix, and listing never proves write access anyway.
log "preflight: checking write access to ${S3_URI}"
printf 'preflight %s\n' "$(date -u +%FT%TZ)" \
  | aws s3 cp - "${S3_URI}/.preflight" >/dev/null \
  || die "cannot write to ${S3_URI} -- no credentials, no region, or no permission"

log "pulling state from ${S3_URI}"
sync_down || die "initial sync from ${S3_URI} failed"
# No step: last_step decides that below, and train_launch reports it.
phase restore_done

case "$STAGE" in

  # --- Idempotent per shard upstream; nothing to add. ---------------------
  dataset)
    log "downloading ${NUM_SHARDS} shards"
    python -m nanochat.dataset -n "$NUM_SHARDS"
    sync_up || die "shards downloaded but not persisted to ${S3_URI}"
    log "done"
    phase complete
    ;;

  # --- No upstream resume, so the stage is ATOMIC: fully present, or redone
  # from scratch. Minutes, not hours. -------------------------------------
  tokenizer)
    if [ -f "${TOKENIZER_DIR}/tokenizer.pkl" ] && [ -f "${TOKENIZER_DIR}/token_bytes.pt" ]; then
      log "tokenizer already complete, skipping"
      phase complete
      exit 0
    fi
    log "training tokenizer (partial output from a previous kill is not reusable)"
    rm -rf "$TOKENIZER_DIR"
    python -m scripts.tok_train --max-chars="$TOK_MAX_CHARS"
    sync_up || die "tokenizer trained but not persisted to ${S3_URI}"
    log "done"
    phase complete
    ;;

  # --- The interesting one: auto-resume from the last checkpoint. ----------
  train)
    TRAIN_PID=""

    # Without this an abrupt kill loses every checkpoint since the run started.
    (
      uploaded=""
      while true; do
        sleep "$SYNC_INTERVAL"
        # Non-fatal -- the next tick retries -- but never silent.
        if sync_up; then
          # This pass is the only thing that knows a step became DURABLE, so
          # ckpt_uploaded is emitted here, not where nanochat wrote the file.
          step="$(last_step || true)"
          [ -z "$step" ] || [ "$step" = "$uploaded" ] \
            || { phase ckpt_uploaded "$step"; uploaded="$step"; }
        else
          log "WARNING: periodic sync failed; will retry in ${SYNC_INTERVAL}s"
        fi
      done
    ) &
    UPLOADER_PID=$!
    # shellcheck disable=SC2064
    trap "kill $UPLOADER_PID 2>/dev/null || true" EXIT

    # On drain: let the trainer finish any in-flight save, push to S3, exit
    # non-zero so Argo retries.
    on_term() {
      phase sigterm
      log "SIGTERM -- draining"
      # FIRST: two syncs over one tree race, and the background one could publish
      # a meta marker for a step the foreground pass is still writing.
      kill "$UPLOADER_PID" 2>/dev/null || true
      wait "$UPLOADER_PID" 2>/dev/null || true

      # 25s of the pod's 110s: the multi-GB final sync needs the rest. Losing the
      # in-flight save costs one interval; losing the upload costs every step.
      if [ -n "$TRAIN_PID" ] && kill -0 "$TRAIN_PID" 2>/dev/null; then
        kill -TERM "$TRAIN_PID" 2>/dev/null || true
        for _ in $(seq 1 25); do
          kill -0 "$TRAIN_PID" 2>/dev/null || break
          sleep 1
        done
      fi

      log "final checkpoint sync"
      if sync_up; then
        log "drained at step $(last_step); exiting 1 so the stage retries"
      else
        # Loud: silently, the retry resumes from an older step -- or from
        # scratch -- while everything still looks fine.
        log "ERROR: final sync FAILED -- S3 is behind local state"
      fi
      # After the sync: (sigterm, drain_done) is how long the drain took. The
      # step is local disk's; the ERROR line above says if S3 is behind it.
      phase drain_done "$(last_step)"
      exit 1
    }
    trap on_term TERM INT

    # From the environment, so IDENTICAL across retries. nanochat's LR, Muon
    # momentum and weight-decay schedules are pure functions of step AND
    # num_iterations and are NOT in the checkpoint, so a changed value here
    # silently produces a different model.
    TRAIN_ARGS=(
      --depth="$DEPTH"
      --num-iterations="$NUM_ITERATIONS"
      --device-batch-size="$DEVICE_BATCH_SIZE"
      --max-seq-len="$MAX_SEQ_LEN"
      --total-batch-size="$TOTAL_BATCH_SIZE"
      --save-every="$SAVE_EVERY"
      --run="$WANDB_RUN"
    )
    # No --fp8: nanochat documents it as H100+ only.

    STEP="$(last_step)"
    if [ -n "$STEP" ]; then
      log "RESUMING from step ${STEP}"
      TRAIN_ARGS+=(--resume-from-step="$STEP")
    else
      log "starting fresh"
    fi

    log "torchrun --standalone --nproc_per_node=${NPROC} -m scripts.base_train -- ${TRAIN_ARGS[*]}"
    phase train_launch "$STEP"
    torchrun --standalone --nproc_per_node="$NPROC" -m scripts.base_train -- "${TRAIN_ARGS[@]}" &
    TRAIN_PID=$!
    set +e
    wait "$TRAIN_PID"
    TRAIN_RC=$?
    set -e
    TRAIN_PID=""

    log "base_train exited rc=${TRAIN_RC}; final sync"
    sync_up || die "training finished but the final sync to ${S3_URI} failed"

    [ "$TRAIN_RC" -eq 0 ] || { log "FAILED rc=${TRAIN_RC}"; exit "$TRAIN_RC"; }
    log "COMPLETE at step $(last_step)"
    phase complete "$(last_step)"
    ;;

  *)
    echo "unknown stage: $STAGE (expected dataset|tokenizer|train, or a selfcheck)" >&2
    exit 64
    ;;
esac
