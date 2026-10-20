#!/usr/bin/env bash
# One table: where a run's wall clock went, what each phase cost, and how much of
# the GPU hour was paid for but not training.
#
# Four sources, merged. Only the first is required -- a missing source costs you
# its rows and says so, it never costs you the table:
#
#   1. PHASE JSON lines from the pod's stdout        files, stdin, or kubectl logs
#   2. per-Pod startedAt/finishedAt on the Workflow  the image-pull row
#   3. Karpenter nodeclaim transition seconds        the node-boot row  (Prometheus)
#   4. DCGM_FI_DEV_POWER_USAGE                       GPU-idle cross-check (Prometheus)
#
# Source 1 is read from files or stdin on purpose, NOT from a fixed S3 key. How
# the lines are obtained -- kubectl logs for a live run, the archived-log object
# for an attempt whose node is gone -- is a fetch step, not part of the contract.
#
# SHELF LIFE -- read this before you wonder where the image-pull row went:
# source 2 exists only while the Workflow object does. Nothing in this repo
# archives Workflows (Argo's archive wants a Postgres instance, and the upstream
# ai-on-eks reference does not ship one either). So this is a post-run command
# with an expiry: once the Workflow is deleted, the image-pull number is
# unrecoverable and no amount of re-running gets it back. Run it while the run is
# still warm.
#
# Source 1 expires SOONER on a successful run: podGC is OnWorkflowSuccess, so the
# pods are reaped the moment the DAG goes green and the live path reports "has no
# pods left (podGC)". That is working as configured, not a failure. Pass the
# archived log instead -- it is in S3 under argo-logs/<workflow>/<pod>/ and
# outlives everything here.
#
# GPU-idle is defined from POWER, not utilization. DCGM_FI_DEV_GPU_UTIL can read
# 100% on a GPU doing almost nothing; an idle L40S draws ~35 W against a 350 W
# TDP, so a watt threshold is a physical measurement rather than a guess.
#
# Three things about the producer that shape what this can tell you:
#   - The lean fork intentionally does not modify scripts/base_train.py for
#     timing. Therefore current runs have no first_step or ckpt_saved events:
#     those rows render as unavailable, never as zero, and training includes
#     torch.compile. The parser still accepts those optional events so the
#     historically captured run remains reproducible.
#   - pod_start/restore_done/complete fire for the dataset and tokenizer stages
#     too, so a whole-workflow log holds three sets. Only one stage is read at a
#     time (STAGE below), because only one of them is on a GPU.
#   - ckpt_uploaded is "durable in S3 at", not "saved at". It fires when a periodic
#     sync_up made the step advance, so it trails the torch.save by up to
#     SYNC_INTERVAL (30s).

set -euo pipefail

RATE="${RATE:-30}"              # $/hr for the GPU node, and an order-of-magnitude
                                # figure for ONE family (g6e.48xlarge, ~$30). Every
                                # dollar column below is linear in it, so pass
                                # RATE= when the run was on other silicon: the same
                                # 48xlarge sizing spans ~$14 (g6) to ~$98 (p5).
IDLE_WATTS="${IDLE_WATTS:-60}"  # Calibration knob. Idle L40S ~35 W, busy ~300 W;
                                # 60 sits in the gap with room for a warm idle.
PROM_STEP="${PROM_STEP:-15}"    # query_range resolution, matches the scrape interval.
STAGE="${STAGE:-train}"         # Which stage's phases to read. train is the only
                                # one on a GPU, so it is the only one worth costing.

HERE="$(cd "$(dirname "$0")" && pwd)"
FIXTURE="$HERE/fixtures/timeline"

usage() {
  # The header comment block, which is the real documentation. Stops at `set -e`
  # so it cannot drift into the code the way a hardcoded line range does.
  sed -n '2,/^set -euo/p' "$0" | sed '$d;s/^# \{0,1\}//'
  cat <<EOF

usage: timeline.sh [-w WORKFLOW|WF.json] [-m PROM_URL|FIXTURE_DIR] [LOG ...|-]

  LOG ...   files holding the pod's stdout (archived log, kubectl logs > file).
            '-' reads stdin. Give NO log and the script goes live: it picks the
            newest pod of the workflow and runs kubectl logs on it.
  -w        Workflow name (live, needs kubectl) OR a path to a saved
            'kubectl get wf -o json'. Omit it and the image-pull row is omitted.
  -m        Prometheus base URL (e.g. http://localhost:9090 behind a
            port-forward) OR a directory of saved responses. Omit it and the
            node-boot row and the power cross-check are omitted.
  --check   render the committed fixture and assert the numbers. No cluster,
            no AWS, no network. This is the test for this script.

env: RATE=$RATE (\$/hr)  IDLE_WATTS=$IDLE_WATTS  PROM_STEP=$PROM_STEP  STAGE=$STAGE

ONE ATTEMPT PER TABLE. The PHASE lines carry no attempt field -- two retries emit
byte-identical sequences -- so identity comes only from which pod's log you
fetched. Concatenating two attempts cannot be undone here, so it is refused. For
the drained attempt, pass its archived log file.

  # live, after a run, with Grafana's Prometheus port-forwarded
  kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090 &
  make timeline ARGS='-m http://localhost:9090'

  # the attempt that was drained: its node is gone, its log is not
  aws s3 cp s3://\$BUCKET/argo-logs/<key> - | scripts/timeline.sh -w <wf-name> -
EOF
}

WF=""; PROM=""; LOGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -w) WF="${2:?-w needs a workflow name or a .json path}"; shift 2 ;;
    -m) PROM="${2:?-m needs a Prometheus URL or a fixture directory}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --check) exec "$0" --run-check ;;
    --run-check) CHECK=1; shift ;;
    -) LOGS+=(/dev/stdin); shift ;;
    -*) echo "unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *) LOGS+=("$1"); shift ;;
  esac
done

# --check is the whole script pointed at the fixture, so it exercises every source
# including the two that would otherwise need a cluster.
if [ -n "${CHECK:-}" ]; then
  out="$("$0" -w "$FIXTURE/wf.json" -m "$FIXTURE/prom" "$FIXTURE/attempt.log")"
  # Same input minus the two optional phases absent from the current lean fork,
  # to prove the normal current path renders instead of dying.
  degraded="$(grep -v '"phase":"\(first_step\|ckpt_saved\)"' "$FIXTURE/attempt.log" \
              | "$0" -m "$FIXTURE/prom" -)"
  # The fixture also holds a tokenizer triple. Rendering it is not useful -- the
  # table is GPU-shaped -- but it is the sharpest test of the absent-phase handling,
  # because almost every row has to come back unavailable.
  prep="$(STAGE=tokenizer "$0" "$FIXTURE/attempt.log")"
  printf '%s\n' "$out"
  fail=0
  check() { # $1 what, $2 haystack, rest: required substrings
    local what="$1" hay="$2"; shift 2
    for want in "$@"; do
      case "$hay" in *"$want"*) ;;
        *) echo "CHECK FAIL ($what): missing [$want]" >&2; fail=1 ;;
      esac
    done
  }
  # Every row of the target table, at the value the fixture encodes. The tokenizer
  # triple in the fixture means a broken stage filter shows up here as a wrong
  # s3-restore number rather than as a crash.
  # The expected output intentionally contains a literal dollar amount.
  # shellcheck disable=SC2016
  check full "$out" \
    'node boot (launch->ready)         73s        0.61' \
    'image pull                        62s        0.52' \
    's3 restore (sync_down)             8s        0.07' \
    'train launch (torchrun)            3s        0.03' \
    'torch.compile -> first step      141s        1.18' \
    'training                         986s        8.22' \
    'ckpt saved->durable (x15)        180s        1.50' \
    'drain final sync                  22s        0.18' \
    'GPU-idle: 5m09s of 21m35s (23%)  ~ $2.58' \
    'DCGM power: 25/78 samples under 60W -> 32% idle' \
    'drained at local step 375'
  # Without the two optional historical phases, and without the Workflow.
  # The absent rows must say so -- an earlier version printed a -57-year duration
  # here instead, because an awk subscript reference creates the key it tests.
  check degraded "$degraded" \
    'torch.compile -> first step       --          --   (needs PHASE train_launch/first_step)' \
    'ckpt saved->durable (x0)          --          --   (needs PHASE ckpt_saved; 15 reached S3)' \
    'image pull                        --          --   (needs the Workflow (-w))' \
    'training (incl. torch.compile)  1127s' \
    'missing: image pull'
  check prep-stage "$prep" \
    's3 restore (sync_down)            20s' \
    'train launch (torchrun)           --          --   (needs PHASE restore_done/train_launch)' \
    'GPU-idle: not computable without a training window'
  [ "$fail" = 0 ] && echo "--check OK"
  exit "$fail"
fi

# --- source 1: PHASE lines -------------------------------------------------
# Live only when no log file was named: passing a file means "offline", and this
# script must never reach for a cluster or an AWS credential uninvited.
if [ ${#LOGS[@]} -gt 0 ]; then
  RAW="$(cat "${LOGS[@]}")"
else
  # A saved Workflow JSON holds no container logs, and asking for one is offline
  # intent -- so bail here rather than letting the live branch below touch kubectl.
  if [ -f "$WF" ]; then
    echo "-w $WF is a saved Workflow: it has no logs in it. Name a log file too." >&2
    exit 2
  fi
  [ -n "$WF" ] || WF="$(kubectl get wf \
      -o jsonpath='{range .items[*]}{.metadata.creationTimestamp}{"\t"}{.metadata.name}{"\n"}{end}' \
      | sort | tail -1 | cut -f2)"
  [ -n "$WF" ] || { echo "no Workflow found, and no log file given. See --help." >&2; exit 1; }
  # The NEWEST pod, not every pod: `kubectl logs -l` would concatenate all the
  # retries into one unreadable timeline. Newest means the attempt that succeeded;
  # for the attempt that was drained, pass its archived log.
  POD="$(kubectl get pods -l "workflows.argoproj.io/workflow=$WF" \
          --sort-by=.metadata.creationTimestamp \
          -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
  [ -n "$POD" ] || { echo "workflow $WF has no pods left (podGC). Pass an archived log." >&2; exit 1; }
  echo "reading $POD of workflow $WF" >&2
  RAW="$(kubectl logs "$POD" --all-containers --tail=-1 2>/dev/null || true)"
fi

# grep -o tolerates a glued-on prefix; fromjson? makes a truncated line cost one
# line; the sub absorbs a pre-amendment emitter's `.3NZ`. select(.stage) is the
# load-bearing one -- dataset and tokenizer emit the same phases, and merging all
# three produces a plausible table that is pure fiction.
FACTS="$(printf '%s\n' "$RAW" | { grep -o 'PHASE {.*}' || true; } | sed 's/^PHASE //' \
  | jq -rR --arg s "$STAGE" 'fromjson? | select(.phase and .stage == $s)
            | "p \(.phase) \(.ts|sub("\\.[^Z]*Z$";"Z")|fromdateiso8601) \(.step // "-")"')"

if [ -z "$FACTS" ]; then
  echo "no PHASE lines for stage '$STAGE' in the input (STAGE= to pick another)." >&2
  exit 1
fi

n_start="$(printf '%s\n' "$FACTS" | grep -c '^p pod_start ' || true)"
if [ "$n_start" -gt 1 ]; then
  echo "input holds ${n_start} '$STAGE' attempts (${n_start}x pod_start), and the PHASE" >&2
  echo "lines carry no attempt field to split them by. Pass one attempt's log." >&2
  # "Pass one attempt's log" is only actionable once you know which objects those
  # are. A PREFIX, not a key: the node id equals the pod name only under Argo's v1
  # naming, and the `s3 ls` resolves it either way.
  if [ -n "$WF" ]; then
    if [ -f "$WF" ]; then WFJSON="$(cat "$WF")"
    else WFJSON="$(kubectl get wf "$WF" -o json 2>/dev/null || true)"; fi
    attempts="$(printf '%s' "${WFJSON:-{\}}" | jq -r --arg s "$STAGE" '
      [ (.status.nodes // {})[]
        | select(.type == "Pod" and ((.displayName // "") | startswith($s + "("))) ]
      | sort_by(.startedAt) | .[]
      | "  \(.displayName)\targo-logs/\(.id | sub("-[0-9]+$"; ""))/\(.id)/"' \
      2>/dev/null || true)"
    if [ -n "$attempts" ]; then
      echo "The attempts in that workflow, and where each one's stdout is archived:" >&2
      printf '%s\n' "$attempts" >&2
      echo "  B=\$(cd terraform/live/foundation && terraform output -raw bucket_name)" >&2
      echo "  aws s3 ls --recursive \"s3://\$B/<prefix-above>\"   # then: aws s3 cp <key> - | $0 -w $WF -" >&2
    fi
  fi
  exit 2
fi

ts_of() { printf '%s\n' "$FACTS" | awk -v p="$1" '$2==p {print $3; exit}'; }
T0="$(ts_of pod_start)"
T1="$(printf '%s\n' "$FACTS" | awk '{if ($3+0 > m) m = $3+0} END {print m}')"

# --- source 2: the Workflow object (image pull) ----------------------------
# A readable path is the fixture, anything else a live name -- that one -f test is
# what lets the fixture exercise this source with no cluster.
if [ -n "$WF" ] && [ -n "$T0" ]; then
  if [ -f "$WF" ]; then WFJSON="$(cat "$WF")"
  else WFJSON="$(kubectl get wf "$WF" -o json 2>/dev/null || true)"; fi
  # By TIME, not pod name: the contract carries no attempt field, so the only
  # link is that pod_start fell inside that node's window.
  FACTS="$FACTS
$(printf '%s' "${WFJSON:-{\}}" | jq -r --argjson t "$T0" '
    [ (.status.nodes // {}) | .[]
      | select(.type == "Pod" and .startedAt != null)
      | select((.startedAt|fromdateiso8601) <= $t)
      | select(.finishedAt == null or (.finishedAt|fromdateiso8601) >= $t) ]
    | if length == 0 then empty
      else .[0] | "wf \(.startedAt|fromdateiso8601)" end' 2>/dev/null || true)"
fi

# --- sources 3 and 4: Prometheus -------------------------------------------
promq() { # $1 fixture basename, $2 endpoint, rest: curl --data-urlencode args
  local fx="$1" ep="$2"; shift 2
  if [ -d "$PROM" ]; then cat "$PROM/$fx.json" 2>/dev/null || true
  else curl -sfG --max-time 10 "$PROM/api/v1/$ep" "$@" 2>/dev/null || true; fi
}

if [ -n "$PROM" ]; then
  # So "answered with no series" reads differently from "no -m". Conflating them
  # is how the type-label bug below survived a run.
  FACTS="$FACTS
promset 1"
  M=operator_nodeclaim_status_condition_transition_seconds
  # Gauge in some Karpenter versions, histogram in others; `or` takes whichever
  # exists. Initialized already contains Registered, which is the fallback for a
  # node that never finished initialising.
  # The label is `type`, NOT `condition`, despite the metric name (verified on
  # Karpenter 1.14.0). A bad matcher selects nothing rather than erroring, so the
  # only symptom was the node-boot row quietly never appearing.
  nc() { printf 'avg(%s{type="%s"}) or avg(%s_sum{type="%s"}/%s_count{type="%s"})' \
                "$M" "$1" "$M" "$1" "$M" "$1"; }
  BOOT="$(promq nodeclaim query --data-urlencode "query=$(nc Initialized) or $(nc Registered)" \
          | jq -r '.data.result[0].value[1] // empty' 2>/dev/null || true)"
  [ -z "$BOOT" ] || FACTS="$FACTS
boot $BOOT"

  # Power, not utilization: it cross-checks source 1. If a PHASE line says
  # training started while mean power is on the floor, that line is lying.
  PW="$(promq power query_range \
          --data-urlencode 'query=avg(DCGM_FI_DEV_POWER_USAGE)' \
          --data-urlencode "start=$T0" --data-urlencode "end=$T1" \
          --data-urlencode "step=$PROM_STEP" \
        | jq -r --argjson w "$IDLE_WATTS" '.data.result[0].values // []
            | select(length > 0)
            | "power \([.[] | select((.[1]|tonumber) < $w)] | length) \(length)"' 2>/dev/null || true)"
  [ -z "$PW" ] || FACTS="$FACTS
$PW"
fi

# --- render ----------------------------------------------------------------
# ASCII arrows on purpose: printf "%-30s" pads by BYTES on BSD awk, so a 3-byte
# U+2192 would shift every row it appears in.
printf '%s\n' "$FACTS" | awk -v rate="$RATE" -v watts="$IDLE_WATTS" '
function hms(s)  { if (s < 0) s = 0; return sprintf("%dm%02ds", int(s/60), int(s%60)) }
function usd(s)  { return s * rate / 3600 }
function row(label, secs, ok, why) {
  if (ok) printf "%-30s %5ds %11.2f\n", label, secs, usd(secs)
  else    printf "%-30s %5s %11s   (needs %s)\n", label, "--", "--", why
}
# NAMES, not a computed duration, and that is load-bearing: writing t["x"] in an
# argument list CREATES the key, so a caller passing t[b]-t[a] would see both as
# present and print the difference against zero as a ~-57-year duration.
function gap(a, b, label) {
  if ((a in t) && (b in t)) row(label, t[b] - t[a], 1, "")
  else                      row(label, 0, 0, "PHASE " a "/" b)
}

$1 == "p" {
  t[$2] = $3 + 0
  if ($2 == "drain_done")    dstep = $4
  if ($2 == "ckpt_saved")    saved[$4] = $3 + 0
  if ($2 == "ckpt_uploaded") { up++; if ($4 in saved) { ck += $3 - saved[$4]; ckn++ } }
}
$1 == "wf"    { wf0   = $2 + 0 }
$1 == "boot"  { boot  = $2 + 0 }
$1 == "promset" { promset = 1 }
$1 == "power" { pidle = $2 + 0; ptot = $3 + 0 }

END {
  # Where training stopped: `complete` for a clean run, `sigterm` for the one that
  # got drained. drain_done is after that and is its own row.
  tend = ("complete" in t) ? t["complete"] : (("sigterm" in t) ? t["sigterm"] : 0)
  last = 0; for (k in t) if (t[k] > last) last = t[k]
  # No first_step: fold compile into training and relabel, rather than reporting
  # a number that silently includes warmup. `in` tests, not a ternary -- the
  # untaken branch still creates its subscript (see gap()).
  tstart = 0; tlabel = "training"
  if ("first_step" in t)        tstart = t["first_step"]
  else if ("train_launch" in t) { tstart = t["train_launch"]; tlabel = "training (incl. torch.compile)" }

  printf "%-30s %5s %11s\n", "phase", "dur", "$ at $" rate "/hr"
  row("node boot (launch->ready)", boot, boot > 0, "Prometheus (-m)")
  if (wf0 > 0 && ("pod_start" in t)) row("image pull", t["pod_start"] - wf0, 1, "")
  else                               row("image pull", 0, 0, "the Workflow (-w)")
  gap("pod_start",    "restore_done", "s3 restore (sync_down)")
  gap("restore_done", "train_launch", "train launch (torchrun)")
  gap("train_launch", "first_step",   "torch.compile -> first step")
  row(tlabel,                      tend - tstart, tstart > 0 && tend > 0, "PHASE train_launch + complete/sigterm")
  # INSIDE the training window, so neither added nor subtracted below:
  # ckpt_uploaded is a DURABILITY time that trails torch.save by up to
  # SYNC_INTERVAL, and subtracting it would manufacture idle time.
  if (ckn > 0) printf "%-30s %5ds %11.2f   (inside training; saved->durable)\n", sprintf("ckpt saved->durable (x%d)", ckn), ck, usd(ck)
  else         printf "%-30s %5s %11s   (needs PHASE ckpt_saved; %d reached S3)\n", sprintf("ckpt saved->durable (x%d)", ckn), "--", "--", up
  gap("sigterm", "drain_done", "drain final sync")

  # Billed wall clock: meter start (pod creation, or node launch if Prometheus
  # told us) to the last thing logged.
  base = 0
  if (wf0 > 0)               base = wf0
  else if ("pod_start" in t) base = t["pod_start"]
  span = (base > 0) ? (last - base) + boot : 0
  busy = (tstart > 0 && tend > 0) ? tend - tstart : 0

  print ""
  if (busy > 0 && span > 0) {
    idle = span - busy
    printf "GPU-idle: %s of %s (%d%%)  ~ $%.2f burned not training\n", \
      hms(idle), hms(span), 100 * idle / span, usd(idle)
    print "  A FLOOR, not the total: this counts only time outside the training"
    print "  window. Stalls inside it -- checkpoint uploads, dataloader starvation --"
    print "  are invisible to the PHASE lines. The DCGM line below does see them."
  } else print "GPU-idle: not computable without a training window"

  if (ptot > 0) {
    printf "DCGM power: %d/%d samples under %dW -> %d%% idle over the sampled window\n", \
      pidle, ptot, watts, 100 * pidle / ptot
    print "  (window starts at pod_start, so it cannot see node boot; a big gap"
    print "   against the line above means a PHASE line is lying)"
  }

  print ""
  # LOCAL DISK, not S3. A failed final sync leaves S3 behind this number, which
  # the entrypoint logs loudly -- so it is not safe to read as the resume point.
  if (dstep != "" && dstep != "-") \
    printf "drained at local step %s (S3 may be behind it if the final sync failed)\n", dstep
  if (boot == 0 && !promset) print "missing: node boot      -- no Prometheus (-m)"
  if (boot == 0 && promset)  print "missing: node boot      -- Prometheus answered with no series. Either no"
  if (boot == 0 && promset)  print "                           NodeClaim in the retention window, or the karpenter"
  if (boot == 0 && promset)  print "                           ServiceMonitor is not scraping."
  if (wf0 == 0)  print "missing: image pull     -- no Workflow (-w). It may simply be gone: nothing"
  if (wf0 == 0)  print "                           archives Workflows. See --help, SHELF LIFE."
  if (ptot == 0) print "missing: power idle     -- no DCGM query (-m); the GPU-idle line above is"
  if (ptot == 0) print "                           derived from the PHASE lines instead."
}'
