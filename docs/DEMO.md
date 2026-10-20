# Demo runbook

Training an LLM on EKS, killing the node mid-run, and watching it **resume** —
not restart.

Commands first, with real output under each. §6's timings and log excerpts come
from one worked run, `<DEMO_RUN_ID>`; its sanitized evidence artifacts are under
[`captures/2026-10-09-run/`](captures/2026-10-09-run/).

Nothing here is pinned to one account. `scripts/configure.sh --region <r>
--expected-account <12-digit-id>` verifies the active credentials against the
account you named, then writes the account, region and instance type into
`config.env`. Every script and the Makefile assert that identity afterward.
Sample outputs below show the region and instance type they happened to be
recorded in; substitute your own.

**What this demonstrates:** every orchestrator can relaunch a failed job.
None of them can *resume* one. Resume is application work — checkpoint layout,
commit protocol, constant world size — and that is what the fork provides. The
infrastructure's job is only to make the relaunch land somewhere useful, fast.

---

## 0. What you need

| | |
|---|---|
| Credentials | an explicitly chosen AWS account; `configure.sh` requires its 12-digit ID and refuses credentials for any other account before touching S3 |
| Tools | `terraform ~> 1.14`, `awscli v2`, `kubectl`, `docker`, `make`, `git` |
| Source | this repo plus [`moca/nanochat`](https://github.com/moca/nanochat) branch `iteration/observability`, pinned to `a0f52493e96f46071ca35d94b60d95231a5a47ec`, as a **sibling** (default `../nanochat`, configurable with `NANOCHAT_DIR`); both checkouts must be clean |
| Optional | a W&B API key, for the loss curve (skip it: `WANDB_RUN` defaults to `dummy`) |

```bash
aws sts get-caller-identity --query Account --output text  # verify this is your intended account
make printtag                                               # <12-char fork SHA>-<12-char repo SHA>
```

`make image` and `make run` fail closed if either checkout is missing Git
metadata or has modified/untracked files. Release from committed source; a copied
directory without `.git` cannot produce a traceable image tag.

> **`AWS_PROFILE` must be in the ENVIRONMENT, not only `config.env`.** The Makefile
> derives `ECR` and `BUCKET` via `$(shell terraform output ...)`, and GNU Make 3.81
> (what macOS ships) does not pass exported variables to `$(shell)`. So
> `config.env` alone satisfies the account assertion — that runs in a recipe — and
> still leaves both empty. Use `AWS_PROFILE=<p> make image`.

Cost while running: **~$30/hr** per 8-GPU node, and the reservation holds
**two**, so **~$60/hr** from the moment it is created — whether or not anything is
running in it. Read §7 before you start.

---

## 1. Capacity first — this is the real constraint

8-GPU capacity is scarce. Nothing else matters if you cannot get it, so probe
before building anything.

The demo pins capacity with a reservation so the recovery timings are
reproducible run to run. To run it on Spot instead, read
[Running it on Spot](#running-it-on-spot) at the end of this section first — you
skip the reservation entirely.

```bash
# Read-only. Costs nothing. Shows which regions clear the On-Demand-G quota.
scripts/find-capacity.sh
```

One run of it looked like this. It separates two constraints that are easy to
conflate:

<!-- portable-ok: dated measurement -- the whole value is in naming which regions -->
```
ap-northeast-2   g6e.48xlarge  2 AZs   quota 768   quota+offered
ap-south-1       g6e.48xlarge  2 AZs   quota 768   quota+offered
us-east-1        g6e.48xlarge  4 AZs   quota 768   quota+offered
us-west-2        g6e.48xlarge    -     quota 128   SKIP: needs an increase
ap-northeast-1   g6e.48xlarge    -     quota  64   SKIP: needs an increase
eu-west-1        -- the type is not offered in this region at all --
```

So **quota is not the binding constraint in three regions, and the type is sold
in eight AZs.** What is scarce is a *free host*, and no public API reports that:

<!-- portable-ok: dated measurement -- naming the regions probed IS the finding -->
```
2026-10-08  probe, 24 rows across ap-south-1 + us-east-1  ->  0 with capacity
2026-10-08  probe, 2 rows in ap-northeast-2               ->  1 with capacity (AZ b)
```

Pools move daily. Re-measure; do not read either block as standing advice.

Read the `GATES` column literally: `quota+offered, capacity UNKNOWN` means the
quota fits and the type is sold in that AZ. It does **not** mean a host is free —
no public API reports that.

```bash
# Real measurement: creates each reservation, records, cancels immediately.
# ~$1 per row that HAS capacity, $0 for rows that do not (nothing is provisioned).
REGIONS=<your-region> scripts/find-capacity.sh --probe --yes
```

Then take the capacity. **Do this LAST** — see §7 for why ordering matters.

```bash
REGIONS=<your-region> INSTANCE_TYPES=<8-gpu-type> COUNT=2 HOURS=4 \
  scripts/find-capacity.sh --create --yes
```

| Arg | Why |
|---|---|
| `INSTANCE_TYPES=<8-gpu-type>` | pins 8 GPUs; without it a failure silently downgrades you to a 4-GPU type |
| `COUNT=2` | the replacement needs a slot while the drained instance still holds one |
| `HOURS=4` | self-expiring. `HOURS=0` = unlimited, bills until you cancel |

On success it writes `terraform/live/eks/capacity.auto.tfvars` and prints the
cancel command. The reservation used in the §6 run:

<!-- portable-ok: recorded output -- the instance type and AZ are material to the measurement -->
```
<CAPACITY_RESERVATION_ID>   g6e.48xlarge   ap-northeast-2b   targeted   2/2 available
```

### Running it on Spot

Spot is the cheaper way to run this, and a training job that can resume is the
workload best suited to it. The recovery path does not change: Karpenter reacts
to the same interruption message either way. **This path is documented here, not
validated — the run in §6 was on reserved capacity.** For what Spot costs in
your region, read [Spot pricing](https://aws.amazon.com/ec2/spot/pricing/).

Two edits, in your own checkout:

| File | Change | Why |
|---|---|---|
| `terraform/live/eks/main.tf` | `local.capacity_types`: `["reserved", "on-demand"]` → `["spot", "on-demand"]` | That local is what the NodePool's `karpenter.sh/capacity-type` requirement reads, in `terraform/live/eks/karpenter.tf`. `reserved` must come out: Karpenter prioritises it natively, so a reservation would still win |
| `scripts/configure.sh` | add back an `AWSServiceRoleForEC2Spot` step — `aws iam create-service-linked-role --aws-service-name spot.amazonaws.com`, ignoring `InvalidInput`, which means it already exists | It was dropped when `configure.sh` absorbed `bootstrap.sh`, because nothing launches Spot today. The `terraform-aws-modules` Karpenter submodule does **not** create it |

One prerequisite that no file change provides: the *All G and VT Spot Instance
Requests* quota has to cover **two** nodes' worth of vCPU, not one. The
replacement boots while the drained node still exists — the same reason the
reservation path uses `COUNT=2`.

Then skip the reservation: do not run `find-capacity.sh --create`, and leave
`capacity.auto.tfvars` holding only `aws_region`.

**What already works unmodified — this is the interesting part:**

| Component | Status |
|---|---|
| Interruption routing | Already wired. The Karpenter submodule's EventBridge rule `KarpenterSpotInterrupt` matches `detail-type: ["EC2 Spot Instance Interruption Warning"]` and targets the same SQS queue `make inject` writes to. A real Spot interruption and the injected one are the **same message on the same queue**, which is why the recovery path needs no change at all |
| Drain window | The NodePool's `terminationGracePeriod` is `5m`, already longer than Spot's 2-minute notice |
| Instance selection | The NodePool selects on *attributes* — GPU count, GPU memory, local NVMe — so leaving `gpu_instance_types = []` lets Karpenter pick among every qualifying family. On Spot that is correct practice rather than a loose default: more pools means fewer interruptions |

`make inject` stays useful on Spot. It makes recovery testable on demand, rather
than whenever the market decides.

---

## 2. Build the infrastructure

```bash
scripts/configure.sh --region <r> --expected-account <12-digit-id>
export TF_VAR_cluster_endpoint_public_access_cidrs='["<your-egress-ip>/32"]'
make foundation     # save the exact VPC/S3/ECR plan under .terraform-plans/
make foundation-show
make foundation-apply
make cluster        # save the exact EKS/observability/Argo plan
make cluster-show
make cluster-apply
make kubeconfig
```

`make foundation` and `make cluster` are compatibility aliases for their
`*-plan` targets. They never apply directly. The artifact names include the
expected AWS account and region; `*-show` renders the exact saved binary plan,
and `*-apply` consumes that same file without replanning. Re-run the plan target
after changing code or configuration, then review it again before applying.
Plans may contain sensitive values, so `.terraform-plans/` is gitignored and
the workflow restricts the directory and artifacts to the current user.

Verify before spending GPU time — the NodePool silently not working is the
expensive failure mode:

```bash
kubectl get ec2nodeclass,nodepool
kubectl get ec2nodeclass gpu-nanochat -o jsonpath='{.status.capacityReservations}' | jq
```

Expected — the last block is the one that matters:

<!-- portable-ok: recorded output -- this block IS the evidence the selector resolved -->
```
EC2NodeClass gpu-nanochat   Ready=True
NodePool     gpu-nanochat   Ready=True, NodeClassReady=True

[{"availabilityZone":"ap-northeast-2b","id":"<CAPACITY_RESERVATION_ID>",
  "instanceMatchCriteria":"targeted","instanceType":"g6e.48xlarge",
  "state":"active"}]
```

If `capacityReservations` is empty, Karpenter has not resolved the ODCR and
`capacity-type: reserved` can never schedule. Check the reservation's
`project=nanochat-demo` tag.

---

## 3. Build and push the training image

```bash
make image    # ~4.4 GB compressed / 12.5 GB on disk; ~5 min warm, ~20 min cold
```

The tag is `<fork-sha>-<repo-sha>` because the image depends on both repos.
`make run` refuses to submit a tag that is not in ECR, so if you have committed
since your last build, re-run `make image`.

---

## 4. Optional: W&B, for the loss curve

**Genuinely optional — skip this whole section if you want.** `WANDB_RUN` defaults
to `dummy`, which both the entrypoint and nanochat read as "W&B disabled": no key
is fetched, no Secrets Manager call is made, and `make wandb-key` never has to run.
The interruption and the resume are unaffected — the loss curve is a nicety, not
part of the mechanism.

```bash
make run                  # dummy: no W&B, no key needed
make run WANDB_RUN=my-run # W&B on, and the key below becomes required
```

So set a key only if you want the curve:

```bash
make wandb-key      # prompts, hidden input; writes to Secrets Manager
```

Pick one and stay with it for a given run. Naming a run with no readable key is
the one combination that fails: it is treated as a request you cannot satisfy, so
the DAG stops on a CPU node ~2 min in (exit 64) rather than burning 400 GPU-steps
with no curve to show.

The pod reads the key at startup via EKS Pod Identity — there is no Kubernetes
Secret and no CSI driver. Verify the whole credential path with a throwaway pod
(seconds, runs on the CPU nodes, catches a broken image before any GPU cost):

```bash
kubectl run awstest --rm -it --restart=Never \
  --overrides='{"spec":{"serviceAccountName":"argo-workflow"}}' \
  --image=$(cd terraform/live/foundation && terraform output -raw ecr_repository_url):$(make -s printtag 2>/dev/null || echo latest) \
  --command -- bash -c 'aws sts get-caller-identity && aws s3 ls'
```

---

## 5. Run it

```bash
make run                                    # no W&B
make run WANDB_RUN=my-run                   # with the loss curve (needs §4)
```

`WANDB_RUN` is `dummy` unless you set it, and `dummy` means W&B off in both the
entrypoint and nanochat. Each run gets its own `RUN_ID` S3 prefix, so a second
run does not "resume" the previous one straight to completion.

The DAG is `dataset → tokenizer → train`. The first two run on the CPU system
nodes and take ~2 minutes. Then the train step requests 8 GPUs:

<!-- portable-ok: recorded Karpenter output -- capacity-type=reserved is the point of showing it -->
```
15:45:33  Karpenter: computed new nodeclaim(s) to fit pod(s)
15:45:35  launched nodeclaim   capacity-type: reserved   g6e.48xlarge
15:46:37  registered nodeclaim
15:46:48  initialized          allocatable: nvidia.com/gpu: 8
```

**~75 seconds from pending pod to schedulable GPU node.** Watch it:

```bash
kubectl get pods -w
kubectl get nodeclaims -o wide
make watch        # karpenter logs + nodeclaims + pods in one shot
```

Confirm you actually got reserved capacity, not plain on-demand:

```bash
kubectl get nodeclaims -o custom-columns='NAME:.metadata.name,CAPACITY:.metadata.labels.karpenter\.sh/capacity-type,TYPE:.metadata.labels.node\.kubernetes\.io/instance-type'
# CAPACITY must read "reserved"
```

The DCGM exporter only exists while a GPU node does, so this is the one window in
which GPU metrics can be confirmed. Ask **Prometheus**, not Kubernetes — a healthy
ServiceMonitor object is not evidence anything is scraping it:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
curl -s localhost:9090/api/v1/targets | grep -c dcgm      # expect >0, health "up"
curl -s --get localhost:9090/api/v1/query \
  --data-urlencode 'query=DCGM_FI_DEV_POWER_USAGE'        # expect 8 results
```

Wait until training is past a checkpoint or two. `save-every` is 25 steps of 400:

```bash
POD=$(kubectl get pods -l workflows.argoproj.io/workflow \
        --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
kubectl logs -f "$POD" -c main | grep -E '^Step'
```

**Inject around step 100–150.** Injecting near the end works but leaves no
post-recovery training to watch — in the run below it landed at ~390 and only ~10
steps remained.

---

## 6. The interruption

```bash
# Record what exists BEFORE, so "how much was lost" is measurable
B=$(cd terraform/live/foundation && terraform output -raw bucket_name)
P=$(aws s3 ls "s3://$B/runs/" | tail -1 | awk '{print $2}')
aws s3 ls --recursive "s3://$B/runs/$P" | grep -oE 'meta_[0-9]{6}' | sort -u | tail -3

make inject          # prompts; add --yes for no TTY
```

### Why injecting the event tests the real path

It places a real EventBridge `EC2 Spot Instance Interruption Warning` onto
Karpenter's interruption SQS queue for the running node's instance ID — the same
queue a real Spot interruption lands on.

FIS's `aws:ec2:send-spot-instance-interruptions` only targets
`aws:ec2:spot-instance`, and this demo pins capacity so its timings are
reproducible, so the event is injected directly instead. Karpenter polls that
queue and acts on what it finds, so this drives the **identical** taint → drain →
provision-replacement path on any capacity type. Only the trigger differs; the
behaviour under test does not.

### What recovery looks like

Run `<DEMO_RUN_ID>`, 8 GPUs, `--save-every 25`, 400 iterations. Sanitized
artifacts: [`captures/2026-10-09-run/`](captures/2026-10-09-run/).

This historical run used optional `first_step` and `ckpt_saved` timing
instrumentation inside nanochat. The current lean fork omits those two log-only
hooks; checkpointing and recovery are unchanged.

| Time (UTC) | Event | Source |
|---|---|---|
| 09:25:48 | `ckpt_saved step 150` — last save before the kill | pod stdout |
| **09:25:54** | **interruption enqueued** | `make inject` |
| 09:25:55.764 | Karpenter: `initiating delete from interruption message`, `messageKind=spot_interrupted`, `action=CordonAndDrain` | karpenter |
| 09:25:55.837 | node tainted `karpenter.sh/disrupted:NoSchedule` | karpenter |
| 09:25:55.9 | `torchrun` relays SIGTERM to all 8 ranks | pod stdout |
| 09:26:05 | drained attempt exits 1; Argo creates the retry | Workflow |
| 09:26:49 | replacement nodeclaim launched on reserved capacity | karpenter |
| 09:27:58 | replacement `initialized` (71s boot) | karpenter |
| **09:29:15** | **`RESUMING from step 150`** | pod stdout |
| 09:30:10 | `first_step step 150` — productive again | pod stdout |
| 09:33:47 | `complete step 400` | pod stdout |
| 09:33:58 | workflow `Succeeded` | Workflow |

**3m21s from injection to a resumed trainer; about 4m15s to the first productive
step.** The replayable phase rows measure a 143s image pull, 7s restore, and 55s
from train launch to first step. Karpenter records 71s from replacement
NodeClaim creation to `initialized`; these windows overlap and are not additive.

**Steps lost: 0 of 400.** Step 150 was saved locally 7s before SIGTERM. The S3
marker listing timestamps it at 09:26:05 UTC — about 10s after SIGTERM and 4m50s
before Karpenter's 09:30:55 termination deadline — and attempt 2 resumed it.
Seven seconds is therefore the local-save margin, not the S3-durability margin.
One `--save-every` interval is the *worst case*, not the expected case.

### How to tell a resume from a restart

```bash
POD=$(kubectl get pods -l workflows.argoproj.io/workflow \
        --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
kubectl logs "$POD" -c main | grep -iE 'RESUMING|Resuming optimization'
```

```
[train 09:29:15] RESUMING from step 150
Resuming optimization from step 150
```

And the S3 side, which is a measurement rather than a log line — note the gap
between 150 and 175, which is the interruption:

```bash
make checkpoints     # the step timeline in S3 = how much work was lost
```

```
11:25:18  base_checkpoints/d12/meta_000075.json
11:26:05  base_checkpoints/d12/meta_000100.json
11:26:05  base_checkpoints/d12/meta_000125.json
11:26:05  base_checkpoints/d12/meta_000150.json   <- pushed by the DRAIN handler
11:31:00  base_checkpoints/d12/meta_000175.json   <- 4m55s later, on the new node
11:31:00  base_checkpoints/d12/meta_000200.json
```

Confirm you actually got reserved capacity, because the fallback to on-demand is
silent by construction:

```bash
kubectl get node -l karpenter.sh/nodepool=gpu-nanochat \
  -o jsonpath='{.items[*].metadata.labels.karpenter\.sh/capacity-type}'
# reserved reserved      <- BOTH nodes, during the handoff
```

### Why the bound holds

Work lost is bounded by one `save-every` interval — 25 steps — **by design, not
by luck**. Three things make that true, and all are easy to get wrong:

- **Two reservation slots.** During the handoff both nodeclaims were alive at once
  and both read `reserved`. EC2 releases an ODCR slot only at `terminated`, not
  `shutting-down`, so with one slot the replacement waits and a clean handoff
  looks like a multi-minute stall.
- **A graceful drain that outlives the trainer.** Karpenter annotated the
  nodeclaim with `karpenter.sh/nodeclaim-termination-timestamp` 5 minutes out —
  the NodePool's `terminationGracePeriod` — and the pod's own
  `terminationGracePeriodSeconds: 110` sits inside it. That window is what let the
  final sync publish step 150 and turn "one interval lost" into "nothing lost".
- **A checkpoint commit protocol.** A step is ten files — `model_NNNNNN.pt`,
  `meta_NNNNNN.json`, and `optim_NNNNNN_rank{0..7}.pt` from eight concurrent
  ranks. Each local artifact is published by atomic rename; metadata appears only
  after all ranks cross a barrier. The uploader then copies the exact model and
  optimizer rank set before uploading metadata last to S3. Resume only selects a
  step with a model, metadata, and every rank `0..NPROC-1`; counting arbitrary
  shard files is not enough. Without this it can resume onto a partial step and
  crash-loop identically on every retry.

### One caveat when reading the drained attempt's log

**S3 can be ahead of what that log shows.** Its last `ckpt_uploaded` is step 75,
but S3 received 150. Kubernetes signals every container simultaneously, so Argo's
`wait` sidecar uploads the log and exits while the main container still has 110s
of grace left — so `sigterm` is the last line present and `drain_done` never
appears:

```bash
grep -c drain_done docs/captures/2026-10-09-run/attempt1-archived.log
# 0
```

Read the resume point off the *next* attempt's `RESUMING from step N`, or off S3,
not off the drained attempt's tail. See
[`PRODUCTION-CHECKLIST.md`](PRODUCTION-CHECKLIST.md).

---

## 7. Cost control — read this before §1

The reservation bills from creation, idle or not.

```bash
make odcr           # what is reserved; 'ends' empty means UNLIMITED
make odcr-cancel    # stops the reservation meter
```

Cancelling does **not** terminate running instances — they revert to plain
On-Demand, so you will not lose a training run by stopping the meter. Idle GPU
nodes self-reclaim via the NodePool's `consolidateAfter: 2m` (verified: both
nodes were gone shortly after the workflow finished), with `expireAfter: 24h` as a
backstop.

**Order the build so the meter covers only the demo.** The reservation is not
needed until a GPU *pod* is scheduled, so run §2 (cluster) and §3 (image) first —
otherwise ~1 hour of infrastructure apply and image push happens at $60/hr.

```bash
make down-cluster   # plan -destroy for the cluster; keeps checkpoints in S3
make down           # plan -destroy for foundation; DESTROYS the bucket
```

Both only produce a plan and print a review instruction. Nothing is destroyed
without you reading the plan and applying it.

---

## 8. Observability

```bash
make timeline       # what the last run spent NOT training, in dollars
make argo-ui        # http://localhost:2746        the DAG, retries, pod logs
make grafana        # http://localhost:3000        admin / nanochat-demo
```

For how these fit together — which signal survives what — see
[`ARCHITECTURE.md` §6](ARCHITECTURE.md#6-observability--four-paths-by-what-each-survives).

### `make timeline` — run it before the workflow finishes

The phase table reports node boot, image pull, restore, train launch, the
training window, drain, and GPU-idle time priced at the node's hourly rate.
The current lean fork deliberately leaves exact `torch.compile`,
time-to-first-step, and local-save-to-S3 timing unavailable because those
measurements require hooks inside nanochat. Historical logs containing the
optional `first_step` and `ckpt_saved` events still render those extra rows.

**It has a shelf life.** It reads `status.nodes[].startedAt` off the live Argo
Workflow object and pulls `PHASE` lines from the pods, and `podGC` deletes those
on success — so a successful run that has been reaped reports
`has no pods left (podGC)`. That is correct behaviour, not a bug. Either run it
while the workflow is still going, or read the archived logs from S3 (below).

The two numbers that must outlive the cluster are published as Prometheus
metrics from the workflow spec instead, and remote-written to AMP:

```bash
# Note the argo_workflows_ prefix -- Argo adds it, and the bare name
# returns nothing and looks broken.
argo_workflows_nanochat_attempt_duration_seconds   # per stage, per final status
argo_workflows_nanochat_attempt_retries            # max over a run = retries consumed
```

### Reading a retried attempt's log after the pod is gone

Every attempt's stdout is archived to S3 under `argo-logs/`, keyed by pod name —
so each retry is a distinct object, and the *drained* attempt's log survives the
pod being deleted. That is the point: the pod is removed at exactly the moment
worth measuring.

```bash
BUCKET=$(cd terraform/live/foundation && terraform output -raw bucket_name)
aws s3 ls "s3://$BUCKET/argo-logs/" --recursive | grep train-stage
aws s3 cp "s3://$BUCKET/argo-logs/<workflow>/<pod>/main.log" - | grep PHASE
```

The Argo UI serves the same objects (`argo-server` opens the artifact driver
itself). A 500 on every archived log means the `argo-server` pod has no AWS
credentials.

**Known gap:** the drained attempt's log is truncated at the drain. Kubernetes
signals every container simultaneously, so Argo's `wait` sidecar uploads and
exits while the main container still has grace time left — `sigterm` is present,
`drain_done` is not. The timings are in Prometheus; only the tail of that one log
is lost.

### The rest

- **Argo UI** is the clearest visual for the story: the `train` node showing a
  failed attempt and a successful retry.
- **Grafana / Prometheus** — `kube-prometheus-stack`, ClusterIP only, reached by
  port-forward. Never exposed. Local Prometheus is a 5h buffer that
  remote-writes to **Amazon Managed Prometheus**, so the dashboards outlive
  `make down-cluster` and a rebuilt cluster re-attaches to the same workspace by
  alias. Grafana's datasource health check shows ERROR against AMP while queries
  succeed — AMP returns 404 on `/api/v1/status/buildinfo`, which is the only
  endpoint that check uses.
- **W&B** — the loss curve. The value is that it is *continuous across the gap*:
  same run, same model, no discontinuity at the interruption. A named
  `WANDB_RUN` with no readable key now **fails the DAG on a CPU node ~2 min in**
  rather than training blind; use `WANDB_RUN=dummy` to opt out deliberately.
- **DCGM exporter** — a DaemonSet gated on `karpenter.sh/nodepool=gpu-nanochat`,
  so it exists only while a GPU node does (`desired 0` with no GPU node is
  correct). **Measured 2026-09-30:** 22 `DCGM_*` series, target `up`, all 8 GPUs
  reporting. It produced nothing for the first day because our `interval = "15s"`
  override collided with the chart's default 25s `scrapeTimeout`, and the operator
  rejects the whole ServiceMonitor for that.
  `DCGM_FI_DEV_POWER_USAGE` is the better headline metric over
  `DCGM_FI_DEV_GPU_UTIL`: a GPU can report 100% utilization while barely engaging
  its hardware, whereas power draw against TDP tracks real work. Idle L40S sit at
  ~35 W, so the interruption gap is unmistakable.

Why DCGM is allowed on the GPU node and nothing else is:
[`ARCHITECTURE.md` §6](ARCHITECTURE.md#6-observability--four-paths-by-what-each-survives).

---

## 9. Links

**This project**
- **How it works: [`HOW-IT-WORKS.md`](HOW-IT-WORKS.md)** — the three pieces that
  make resume work, as code: the checkpoint commit protocol, the Argo retry
  config, and the injection. With the real logs from each.
- **[`ARCHITECTURE.md`](ARCHITECTURE.md)** — the parts, the interruption control
  flow, where state lives. Start there if you have not seen this repo before;
  this file assumes you just want the commands.
- Fork: <https://github.com/moca/nanochat>
- Upstream: <https://github.com/karpathy/nanochat>
- Before production: [`PRODUCTION-CHECKLIST.md`](PRODUCTION-CHECKLIST.md)

**Karpenter**
- NodePools: <https://karpenter.sh/docs/concepts/nodepools/>
- EC2NodeClass (incl. `capacityReservationSelectorTerms`): <https://karpenter.sh/docs/concepts/nodeclasses/>
- Using ODCRs: <https://karpenter.sh/docs/tasks/odcrs/>
- Disruption & interruption handling: <https://karpenter.sh/docs/concepts/disruption/>
- Feature gates (`ReservedCapacity` is on by default): <https://karpenter.sh/docs/reference/settings/>

**AWS**
- Capacity Reservation concepts (end date, release semantics): <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/cr-concepts.html>
- Capacity Reservation pricing (per-second, 60s minimum): <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/capacity-reservations-pricing-billing.html>
- EKS Pod Identity: <https://docs.aws.amazon.com/eks/latest/userguide/pod-identity.html>
- EKS AI/ML best practices: <https://docs.aws.amazon.com/eks/latest/best-practices/aiml.html>
- Spot pricing, per region and instance type: <https://aws.amazon.com/ec2/spot/pricing/>
- Spot interruption notices (the 2-minute warning): <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-instance-termination-notices.html>
- FIS Spot interruptions (targets `aws:ec2:spot-instance` only): <https://docs.aws.amazon.com/fis/latest/userguide/fis-tutorial-spot-interruptions.html>

**Workload**
- Argo Workflows retry: <https://argo-workflows.readthedocs.io/en/latest/retries/>
- Bottlerocket: <https://bottlerocket.dev/>
- `awslabs/ai-on-eks` reference blueprints: <https://github.com/awslabs/ai-on-eks>
