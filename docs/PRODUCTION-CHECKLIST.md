# Production checklist

This demo is deliberately simplified, in named ways. Each item below is one of
those simplifications: what the demo does, what production needs, and why they
differ. None is a bug — the demo runs correctly without any of them. None should
ship to a real account unchanged.

## Before production

- [ ] **Restrict the cluster's public endpoint.**
      The EKS module enables private endpoint access and requires
      `cluster_endpoint_public_access_cidrs`. Validation rejects every `/0`,
      including noncanonical IPv4 and IPv6 spellings; use the operator or CI
      runner's narrow egress CIDR, or disable public access entirely when the
      deployment runner is inside the VPC.

- [ ] **Label namespaces for Pod Security Admission.**
      *Demo:* no `pod-security.kubernetes.io/*` label anywhere, so every namespace
      is effectively `privileged`.
      *Production:* label `default` (the training pod namespace in
      `k8s/workflow-base-train.yaml`)
      and `argo` with `enforce=baseline`. The pod already complies as written — a
      `Memory`-medium `emptyDir` for `/dev/shm`, no host mounts, no privilege — so
      those two are nearly free. Leave `kube-system` and `monitoring` alone: the
      DCGM exporter needs host device access, which `baseline` forbids.
      *Why:* nothing in a single-tenant demo cluster is adversarial, so the labels
      would only ever have failed a pod. In a shared cluster they are the cheapest
      guard that exists.
      For `restricted`, four more changes: `USER 1000` in `docker/Dockerfile`, plus
      `runAsNonRoot`, `allowPrivilegeEscalation: false`,
      `seccompProfile: RuntimeDefault` and `capabilities.drop: [ALL]` through the
      workflow's existing `podSpecPatch` in `k8s/workflow-base-train.yaml`.
      Confirm nanochat can still write `NANOCHAT_BASE_DIR` as non-root first.

- [ ] **Stop shipping a default Grafana password.**
      *Demo:* `grafana_admin_password` in `terraform/live/eks/variables.tf`
      defaults to a literal in version control, and `make grafana`'s help text
      prints it.
      *Production:* drop the default so Terraform demands the variable, or generate
      one with `random_password` and expose it as a `sensitive` output.
      *Why:* Grafana is a `ClusterIP` reached only by `kubectl port-forward`, so the
      password guards nothing the cluster's own RBAC does not already guard. That
      stops being true the moment it is exposed through an ingress or a load
      balancer. A `sensitive = true` marking on the variable would not help while
      the default itself is committed.

- [ ] **Add an ECR lifecycle policy.**
      *Demo:* `aws_ecr_repository.nanochat` in
      `terraform/live/foundation/main.tf` has no lifecycle rule. Every fork
      SHA pushes another ~4.4 GB image and nothing ever expires.
      *Production:* an `aws_ecr_lifecycle_policy` keeping the last N images, or
      expiring untagged ones after a few days.
      *Why:* a demo pushes a handful of images and is torn down. A CI pipeline
      pushes per-commit, and multi-GB ML images make this the storage line that
      grows fastest.

- [ ] **Do not depend on the pod log for the drain tail.**
      *Demo:* when a node is drained, the interrupted attempt's archived log stops
      at `sigterm` — `drain_done` never appears in it. Kubernetes signals every
      container in the pod at once, so Argo's `wait` sidecar uploads what it has
      and exits while the main container still has ~110s of grace left. No
      supported Argo setting makes the sidecar outlive the main container.
      *Production:* ship logs off the pod as they are produced — a node-level
      collector (Fluent Bit to CloudWatch Logs, or an OTel collector) rather than
      the workflow archiver.
      *Why:* the demo can read the drain timing out of Prometheus
      (`argo_workflows_nanochat_*`) and out of the next attempt's `pod_start`
      instead, so the gap costs nothing. In production the drain is exactly the
      window you most need the log for, and it is the one window the archiver
      structurally cannot cover.

- [ ] **Parameterise the system node group's instance type.**
      <!-- portable-ok: this item exists to track that literal; naming it is the point -->
      *Demo:* the `system` managed node group in `terraform/live/eks/main.tf` names `m7i.xlarge` directly.
      *Production:* a `var.system_instance_types` list, or an attribute-based
      selection like the GPU NodePool's.
      *Why:* the type is neither account- nor region-specific, so the demo's one
      literal is harmless — but it is not offered in every region, which makes it
      the only thing in the Terraform that can fail an apply in a region nobody has
      tried. `make check-portable` allowlists it for exactly this reason.

## If you run this on Spot

The repo runs on reserved and on-demand capacity. Switching to Spot is documented
in [DEMO.md](DEMO.md) — the recovery path itself needs no change, because Karpenter
reacts to the same interruption message either way.

- [ ] **Create the EC2 Spot service-linked role.** Not a gap — a prerequisite of the
      Spot path, and the one thing no file in this repo provides.
      *Demo:* `scripts/configure.sh` does not create it, and says so at its head
      (documented at the start of `scripts/configure.sh`). It is correct not to:
      nothing in the shipped
      configuration launches Spot instances, and the `terraform-aws-modules`
      Karpenter submodule does not create the role either.
      *Production:* once per account, before the first Spot launch, run
      `aws iam create-service-linked-role --aws-service-name spot.amazonaws.com`.
      Ignore an `InvalidInput` error — it means the role already exists.
      *Why:* without it, Spot launches fail inside Karpenter's EC2 call rather than
      at plan time, so the symptom is a NodePool that never produces a node and a
      pod that stays `Pending` with no obvious cause.

## Deliberately out of scope — do not "fix" these

- **Versioning on the checkpoint bucket is off on purpose**
  (see `aws_s3_bucket.artifacts` in `terraform/live/foundation/main.tf`).
  Checkpoints are step-stamped and
  immutable, so every write is already a new key. Versioning multi-GB `.pt` objects
  would multiply storage cost and recover nothing.
- **The GPU NodePool pins one GPU count.** nanochat shards optimizer state per
  rank, so a resume needs the world size it was checkpointed at. Diversifying
  instance types across different GPU counts would break resume, not improve
  availability. Diversifying *within* a GPU count is fine, and is what
  `gpu_instance_types = []` already allows.
- **Capacity is pinned rather than market-selected,** so the demo's recovery
  timings are reproducible for a reader following along. Interruption is injected
  onto Karpenter's SQS queue, which drives the identical taint/drain/replace path.
  Do not reach for an AWS FIS `send-spot-instance-interruptions` action instead —
  it only targets `aws:ec2:spot-instance`.

## Not exercised end to end

Multi-node (multi-pod) training, and resume across a *changed* world size. Treat
the second as broken for the reason above.
