# How it works

Three pieces make "resume, not restart" true. Each is small; each is load-bearing;
each has a failure mode that looks like something else.

- **[A. Checkpointing](#a-checkpointing)** — what a step *is*, and the commit
  protocol that keeps a half-written one from being resumed onto.
- **[B. The Argo train config](#b-the-argo-train-config)** — what turns a drained
  pod into a retry that lands somewhere useful.
- **[C. The injection](#c-the-injection)** — how a node is killed on demand, so
  the recovery path can be exercised whenever you want.

The worked example throughout is run `<DEMO_RUN_ID>` (2026-10-09):
**0 of 400 steps lost**, recovering in **3m21s** — see [DEMO.md](DEMO.md).
Every log excerpt is real output; operational identities use the placeholders
documented in the capture README. The sanitized logs are in
[`captures/2026-10-09-run/`](captures/2026-10-09-run/).
That capture validates the drain and resume path; it predates the atomic local
checkpoint publication described below, which is covered by the repository
self-checks and unit tests.

---

## A. Checkpointing

### A step is atomically published by eight processes

Step 150 is `model_000150.pt` + `meta_000150.json` from rank 0, plus
`optim_000150_rank{0..7}.pt` written concurrently by all eight ranks. The
checkpoint-manager patch in the sibling nanochat checkout publishes every
artifact through a private temporary file followed by `fsync` and atomic
`os.replace`. A distributed barrier waits for all optimizer shards; rank 0 then
publishes metadata last and a second barrier releases the ranks:

```python
if rank == 0:
    _atomic_torch_save(model_data, model_path)
_atomic_torch_save(optimizer_data, optimizer_path)
_checkpoint_barrier()
if rank == 0:
    _atomic_json_save(meta_data, meta_path)
_checkpoint_barrier()
```

Final filenames therefore never expose a partially flushed `torch.save`, and
local `meta_NNNNNN.json` is the commit marker for a complete local step.

This is also why the NodePool pins the GPU count. Optimizer state is sharded
*per rank*, so a checkpoint written by 8 ranks cannot be read by 4. A resume onto
the wrong width does not degrade — it crash-loops identically on every retry. Hence
`karpenter.k8s.aws/instance-gpu-count In [8]` as a hard requirement rather than a
preference.

### S3 preserves the same commit marker

`docker/entrypoint.sh` excludes checkpoints from the broad directory sync. It
captures the set of locally committed steps, uploads the exact model and rank
set for each one, then uploads metadata strictly last:

```bash
sync_up() {
  aws s3 sync "${NANOCHAT_BASE_DIR}/" "${S3_URI}/" \
    --exclude 'base_checkpoints/*' --no-progress --only-show-errors || return 1
  for step in $(complete_steps "$(ls "$CKPT_DIR")"); do
    includes=(--include "model_${step}.pt")
    for r in $(seq 0 $((NPROC - 1))); do
      includes+=(--include "optim_${step}_rank${r}.pt")
    done
    aws s3 cp "${CKPT_DIR}/" "${S3_URI}/base_checkpoints/d${DEPTH}/" \
      --recursive --exclude '*' "${includes[@]}"
    aws s3 cp "${CKPT_DIR}/meta_${step}.json" \
      "${S3_URI}/base_checkpoints/d${DEPTH}/meta_${step}.json"
  done
}
```

The committed set is captured only after the trainer's rank barrier. This avoids
a directory scan starting before the final shard appears and then publishing the
new metadata after having missed that shard. In both local storage and S3:

> **"`meta_NNNNNN.json` is present" implies the model and the exact optimizer
> rank set `0..NPROC-1` already landed.**

### Selecting a resume point

One function, applied to both a local `ls` and an `aws s3 ls`, so the two can
never disagree about what "complete" means:

```bash
complete_step() {
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
    return 0
  done
}
```

Highest step with a meta file, a model file, and every required optimizer rank.
Counting files is insufficient: ranks `0..6` plus rank 8 must not stand in for a
missing rank 7. Checking only `model_*.pt` would return a step
`load_checkpoint` cannot open: `base_train.py` reads
`meta_data["dataloader_state_dict"]`, and each rank loads its own shard.

It has two runnable checks — no cluster, S3, or GPU:

```bash
S3_URI=- docker/entrypoint.sh ckpt-selfcheck
# ckpt-selfcheck OK
S3_URI=- docker/entrypoint.sh sync-selfcheck
# sync-selfcheck OK
```

The fixtures reject a partial step, a wrong rank set, and an upload that exposes
metadata before its payload. The nanochat unit tests separately verify atomic
publication order and that an interrupted artifact write cannot create metadata.

### Downloading one step, not the whole history

```bash
sync_down() {
  aws s3 sync "${S3_URI}/" "${NANOCHAT_BASE_DIR}/" \
    --exclude 'base_checkpoints/*' --no-progress --only-show-errors || return 1
  step="$(complete_step "$(aws s3 ls "${S3_URI}/base_checkpoints/d${DEPTH}/" | awk '{print $NF}')")"
  [ -n "$step" ] || return 0
  aws s3 cp "${S3_URI}/base_checkpoints/d${DEPTH}/" "${CKPT_DIR}/" --recursive \
    --exclude '*' --include "meta_${step}.json" --include "model_${step}.pt" \
    --include "optim_${step}_rank*.pt" --no-progress --only-show-errors || return 1
}
```

A finished 400-step prefix is 32.5 GiB, of which 31.5 GiB is 16 retained
checkpoints. **A resume reads exactly one.** The waste from a flat sync grows
linearly with `num-iterations` while the benefit stays flat — at 2000 iterations
it would be 160 GiB, longer to download than the recovery it is part of. Measured
on this run: `s3 restore (sync_down)` took **7s**.

### What the captured run looked like

The October 9 capture used optional timing instrumentation in `base_train.py`
that is not present in the current lean nanochat fork. It recorded the gap
between a step being saved locally and the same step becoming durable:

```
PHASE {"ts":"2026-10-09T09:25:05Z","phase":"ckpt_saved","stage":"train","step":75}
PHASE {"ts":"2026-10-09T09:25:18Z","phase":"ckpt_uploaded","stage":"train","step":75}
PHASE {"ts":"2026-10-09T09:25:20Z","phase":"ckpt_saved","stage":"train","step":100}
PHASE {"ts":"2026-10-09T09:25:34Z","phase":"ckpt_saved","stage":"train","step":125}
PHASE {"ts":"2026-10-09T09:25:48Z","phase":"ckpt_saved","stage":"train","step":150}
PHASE {"ts":"2026-10-09T09:25:55Z","phase":"sigterm","stage":"train"}
```

In that historical capture, `ckpt_saved` meant local disk and `ckpt_uploaded`
meant durable in S3. The current fork still emits `ckpt_uploaded` from the
`vanilla-eks-spot-training` wrapper, but deliberately does not add `ckpt_saved`
to nanochat.
Checkpoint completeness and resume do not depend on either log line.

And the resume, from `attempt2.log`:

```
[train 09:29:15] RESUMING from step 150
Resuming optimization from step 150
```

Step 150 was saved at 09:25:48 and SIGTERM arrived at 09:25:55 — **7 seconds
later**. The drain handler's final sync published it, so nothing was lost.

---

## B. The Argo train config

### retryStrategy is what makes a drain a resume

`k8s/workflow-base-train.yaml`:

```yaml
retryStrategy:
  limit: "10"
  retryPolicy: Always
  expression: "lastRetry.exitCode != '64'"
  backoff:
    duration: "30s"
    factor: "2"
```

Three decisions, each with a failure mode:

- **`Always`, not `OnError`.** Argo classifies drain-deleted pods inconsistently
  between `Error` and `Failed`. `Always` covers both; `OnError` silently misses
  about half of real interruptions.
- **`expression` excluding exit 64.** The entrypoint exits `64` (`EX_USAGE`) when
  the config cannot work — today only an unreadable W&B secret. That failure is
  identical on all ten attempts, so without this a missing secret is answered with
  **ten GPU nodes and ~8h of exponential backoff**. A drained pod has no exit code
  at all, so it still matches and still retries.
- **No `maxDuration`.** Argo measures it from the *first* attempt's start, not per
  attempt, so any value shorter than the whole run turns a late interruption into
  a hard failure with no retry pod created. It would also need to scale with
  `num-iterations`.

### The grace period has to nest correctly

```yaml
podSpecPatch: |
  terminationGracePeriodSeconds: 110
```

against the NodePool's node-level window in `terraform/live/eks/karpenter.tf`:

```hcl
terminationGracePeriod = "5m"
```

The pod's 110s sits **inside** the node's 5m, so the node never disappears
mid-drain. Karpenter made that explicit on this run:

```
"message":"annotated nodeclaim",
"karpenter.sh/nodeclaim-termination-timestamp":"2026-10-09T09:30:55Z"
```

SIGTERM landed at 09:25:55; the node was not going anywhere until 09:30:55. That
five-minute floor is what let the final sync finish, and it is the difference
between "one save interval lost" and "nothing lost".

Inside the pod, the handler spends that budget deliberately:

```bash
on_term() {
  phase sigterm
  kill "$UPLOADER_PID" 2>/dev/null || true   # stop the periodic sync FIRST
  wait "$UPLOADER_PID" 2>/dev/null || true
  # 25s of the pod's 110s: the multi-GB final sync needs the rest.
  if [ -n "$TRAIN_PID" ] && kill -0 "$TRAIN_PID" 2>/dev/null; then
    kill -TERM "$TRAIN_PID" 2>/dev/null || true
    for _ in $(seq 1 25); do kill -0 "$TRAIN_PID" 2>/dev/null || break; sleep 1; done
  fi
  sync_up && log "drained at step $(last_step); exiting 1 so the stage retries"
  phase drain_done "$(last_step)"
  exit 1
}
```

Stopping the background uploader first is not tidiness: two `aws s3 sync` runs
over one tree race, and the background one could publish a `meta` marker for a
step the foreground pass is still writing — defeating section A's invariant from
the inside.

Waiting only 25s for the trainer is the right trade in the other direction.
`--save-every` exists so that losing an in-flight save costs one interval; losing
the *upload* costs every step since the last durable one.

### Hyperparameters must be identical across retries

```yaml
- name: NUM_ITERATIONS
  value: "{{workflow.parameters.num-iterations}}"
```

nanochat's LR, Muon momentum and weight-decay schedules are pure functions of the
step **and of `num_iterations`**, and are *not* stored in the checkpoint. Resuming
with a different value silently trains a different model. Argo passes the same
workflow parameter to every retry, which is what keeps that honest — and it is why
raising `num-iterations` between a kill and its retry is the one edit that is
unsafe.

### Where the timings survive

The `vanilla-eks-spot-training` wrapper emits the boundaries it can observe
without changing nanochat: pod start, restore completion, train launch, S3
checkpoint publication, SIGTERM, drain completion and stage completion. Those
lines are archived with the pod logs.

The current lean fork intentionally does not add `first_step` or `ckpt_saved`
instrumentation inside `scripts/base_train.py`. Consequently, `make timeline`
reports the exact compile and local-save-to-S3 rows as unavailable and labels the
training window `training (incl. torch.compile)`. This changes only timing
resolution; checkpoint creation, drain, upload and resume use checkpoint files
and metadata rather than these log events.

The historical October 9 capture includes the optional internal events, so its
recorded measurements remain reproducible: 55s resumed and 84s cold to complete
the first step.

> **The drained attempt's log is truncated at the drain.** `sigterm` is present,
> `drain_done` is not — Kubernetes signals every container simultaneously, so
> Argo's `wait` sidecar uploads the log and exits while the main container still
> has 110s of grace. Consequence: **S3 is ahead of that log.** Its last
> `ckpt_uploaded` is 75; S3 received 150. Read the resume point off the next
> attempt or off S3, never off the drained tail.

---

## C. The injection

### Why the event is injected

The recovery path is identical on Spot and on reserved capacity, because Karpenter
reacts to the same interruption event either way. The demo pins capacity so the
timings are reproducible, and injects the event so the interruption lands when you
ask rather than when the market decides. To run it on Spot instead,
[DEMO.md](DEMO.md)'s Spot section lists what to change.

The event goes **directly onto the queue Karpenter already polls**. That is the
same queue a real interruption arrives on: the karpenter submodule's EventBridge
rule `KarpenterSpotInterrupt` matches
`detail-type: ["EC2 Spot Instance Interruption Warning"]` and targets the SQS queue
`scripts/inject-termination.sh` writes to. A real Spot interruption and the
injected one are the *same message on the same queue* — verified live against the
running cluster. Karpenter cannot tell the difference, because for Karpenter the
queue *is* the interface.

AWS FIS is not a substitute: `aws:ec2:send-spot-instance-interruptions` only
targets resource type `aws:ec2:spot-instance`, so it cannot drive a node running
on on-demand or reserved capacity.

### Resolving the target

```bash
POD="$(kubectl get pods -l workflows.argoproj.io/workflow \
         --field-selector status.phase=Running \
         -o jsonpath='{.items[0].metadata.name}')"
NODE="$(kubectl get pod "$POD" -o jsonpath='{.spec.nodeName}')"

kubectl get node "$NODE" -o jsonpath='{.metadata.labels.karpenter\.sh/nodepool}' \
  | grep -q '^gpu-nanochat$' \
  || die "node $NODE is not in nodepool gpu-nanochat"

INSTANCE_ID="$(kubectl get node "$NODE" -o jsonpath='{.spec.providerID}' | awk -F/ '{print $NF}')"
```

From the **running pod**, not from `items[0]` of the GPU nodepool. During a handoff
two GPU nodes exist in no guaranteed order, so the nodepool query can hand back the
*replacement* — interrupting the pod that just recovered and making the demo look
like a loop. The nodepool label check is a second guard: a mis-resolved CPU node
would drain the prep stages and prove nothing.

### The message

```bash
read -r ACCOUNT_ID CALLER_ARN <<<"$(aws sts get-caller-identity --query '[Account,Arn]' --output text)"
PARTITION="$(printf '%s' "$CALLER_ARN" | cut -d: -f2)"
```

```json
{
  "version": "0",
  "detail-type": "EC2 Spot Instance Interruption Warning",
  "source": "aws.ec2",
  "account": "<ACCOUNT_ID>",
  "region": "<REGION>",
  "resources": ["arn:<PARTITION>:ec2:<REGION>:<ACCOUNT_ID>:instance/<INSTANCE_ID>"],
  "detail": { "instance-id": "<INSTANCE_ID>", "instance-action": "terminate" }
}
```

The partition is read off the caller's own ARN rather than written as the literal
`aws`, because `resources[]` has to be a faithful copy of what EventBridge would
have sent — and in `aws-cn` or `aws-us-gov` it is not `arn:aws:`.

### Karpenter's response, with identifiers redacted

```
09:25:55.764  initiating delete from interruption message
              queue=<INTERRUPTION_QUEUE>  messageKind=spot_interrupted
              action=CordonAndDrain  NodeClaim=<NODECLAIM_1>
09:25:55.785  annotated nodeclaim
              karpenter.sh/nodeclaim-termination-timestamp=2026-10-09T09:30:55Z
09:25:55.837  tainted node  taint.Key=karpenter.sh/disrupted  taint.Effect=NoSchedule
09:26:49.481  launched nodeclaim      (the replacement)
09:27:47.606  registered nodeclaim
09:27:58.493  initialized nodeclaim   (71s boot)
```

`messageKind=spot_interrupted` is the proof the path is identical: Karpenter
classified an injected message exactly as it would a real one. **Only the trigger
differs; the taint → drain → provision-replacement behaviour under test does not.**

### The two reservation slots

```bash
COUNT="${COUNT:-2}"
```

EC2 releases an ODCR slot when the instance reaches `terminated`, **not**
`shutting-down`. Argo creates the retry pod as soon as the drained one exits, so
Karpenter asks for a replacement while the old instance still holds its slot. With
one slot the NodeClaim fails and retries on backoff, and a clean handoff looks like
a multi-minute stall.

Observed on this run — both nodes reserved, simultaneously:

<!-- portable-ok: recorded output -- two nodes reserved at once is the claim being evidenced -->
```
$ kubectl get nodeclaims
<NODECLAIM_1>  g6e.48xlarge  reserved  ...  True  14m   # draining
<NODECLAIM_2>  g6e.48xlarge  reserved  ...  True  8m    # training
```

And the slot accounting, ~12 minutes after the old instance began shutting down:

```
$ aws ec2 describe-capacity-reservations --query '...[AvailableInstanceCount,TotalInstanceCount]'
1       2
```

Still `1 of 2`, because the instance was `shutting-down` rather than `terminated` —
the mechanism this `COUNT=2` exists to absorb, visible in the wild.

---

## Reading the historical result

The committed October 9 logs include optional `first_step` and `ckpt_saved`
events. Replaying them therefore produces two rows that a new run with the lean
fork intentionally leaves unavailable. The original Prometheus responses were
not retained, so this offline replay deliberately leaves node boot and GPU power
unavailable:

```bash
STAGE=train scripts/timeline.sh -w docs/captures/2026-10-09-run/wf.json \
  docs/captures/2026-10-09-run/attempt2.log
```

```
phase                            dur $ at $30/hr
node boot (launch->ready)         --          --   (needs Prometheus (-m))
image pull                       143s        1.19
s3 restore (sync_down)             7s        0.06
train launch (torchrun)            0s        0.00
torch.compile -> first step       55s        0.46
training                         217s        1.81
ckpt saved->durable (x4)          22s        0.18   (inside training; saved->durable)
```

`ckpt saved->durable` sits *inside* the training window, so it is neither added to
the total nor subtracted from busy time. It is a durability lag — the periodic
`sync_up` poll noticing a step advanced — not an upload duration, and subtracting a
number inflated by a polling interval would manufacture idle time.

For a current run, `torch.compile -> first step` and `ckpt saved->durable` show
`--`, while the training row is labeled `training (incl. torch.compile)`.

See [DEMO.md](DEMO.md) to run it, [ARCHITECTURE.md](ARCHITECTURE.md) for where
state lives, and [PRODUCTION-CHECKLIST.md](PRODUCTION-CHECKLIST.md) for what to
change before production.
