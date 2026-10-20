# The dedicated submodule, not eks-blueprints-addons (stale chart default, missing
# CRDs). It also creates the SQS interruption queue inject-termination.sh writes to.
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.26.0"

  cluster_name = module.eks.cluster_name

  create_pod_identity_association = true
  node_iam_role_use_name_prefix   = false
  node_iam_role_name              = "${var.cluster_name}-karpenter-node"

  # Without this: LimitExceeded: Cannot exceed quota for PolicySize: 6144. Inline
  # gets 10,240. The policy is the ONLY thing that fails, so Karpenter installs
  # without ec2:DescribeInstanceTypes and the symptom is a helm wait timeout.
  enable_inline_policy = true

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.tags
}

resource "helm_release" "karpenter" {
  name       = "karpenter"
  namespace  = "kube-system"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.14.0"
  wait       = true

  values = [yamlencode({
    settings = {
      clusterName       = module.eks.cluster_name
      clusterEndpoint   = module.eks.cluster_endpoint
      interruptionQueue = module.karpenter.queue_name
    }
    serviceAccount = {
      name = module.karpenter.service_account
    }
    controller = {
      resources = {
        requests = { cpu = "1", memory = "1Gi" }
        limits   = { memory = "1Gi" }
      }
    }

    # Boot and drain timing as metrics instead of a controller log that dies with
    # the cluster. Defaults left alone: the chart emits no interval/scrapeTimeout,
    # so the operator's coherent 30s/10s pair applies.
    serviceMonitor = { enabled = true }
  })]

  # module.karpenter, not just its outputs above: the controller IAM policy is not
  # one of them, so the chart could install in parallel and lose the race.
  # kube_prometheus_stack because the chart guards its ServiceMonitor on an
  # install-time APIVersions check and silently renders none without the CRDs.
  depends_on = [module.karpenter, helm_release.kube_prometheus_stack]
}

# --- GPU NodePool ---------------------------------------------------------

resource "kubectl_manifest" "gpu_node_class" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata   = { name = "gpu-nanochat" }
    spec = {
      # Bottlerocket GPU ships the driver AND the device plugin; AL2023 GPU does not.
      # PINNED: @latest gave v1.66.0, which has an open accelerated-computing
      # regression (bottlerocket-os/bottlerocket#4950). Unpin once that closes;
      # until then an exact version, not an alias, is what holds the variant still.
      amiSelectorTerms = [{ alias = "bottlerocket@v1.65.0" }]
      role             = module.karpenter.node_iam_role_name

      subnetSelectorTerms        = [{ tags = { "karpenter.sh/discovery" = var.cluster_name } }]
      securityGroupSelectorTerms = [{ tags = { "karpenter.sh/discovery" = var.cluster_name } }]

      # Exposes local NVMe as ephemeral-storage, where a step's checkpoint files
      # stage before upload. A no-op on an EBS-only type -- hence the NodePool's
      # instance-local-nvme > 0 requirement.
      instanceStorePolicy = "RAID0"

      # No karpenter.sh/* tags here: reserved namespace, rejected by the webhook.
      tags = {
        Project = var.cluster_name
      }

      # Unconditional: with no reservation the selector resolves empty and the
      # NodePool falls back to on-demand. Gating it on a capacity_mode flag was half
      # of the bricked state of 2026-10-08. By tag, not ID, so a recreated ODCR
      # needs no terraform change -- find-capacity.sh stamps project=<cluster_name>.
      # Karpenter only CONSUMES reservations. Read status.capacityReservations, never
      # CapacityReservationsReady: that reads True against zero matches.
      capacityReservationSelectorTerms = [{
        tags = { project = var.cluster_name }
      }]
    }
  })

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "gpu_node_pool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata   = { name = "gpu-nanochat" }
    spec = {
      template = {
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "gpu-nanochat"
          }

          # Attributes, not a type list. The real requirements are gpu_count GPUs
          # with enough memory each and local NVMe; any family meeting them will do,
          # which makes the fallback automatic rather than a tfvars edit.
          requirements = concat([
            {
              key      = "karpenter.k8s.aws/instance-category"
              operator = "In"
              values   = ["g"]
            },
            {
              # Optimizer state is sharded per rank, so a resume onto a
              # different width crash-loops identically on every retry.
              key      = "karpenter.k8s.aws/instance-gpu-count"
              operator = "In"
              values   = [tostring(var.gpu_count)]
            },
            {
              # MiB PER GPU. Measured 2026-10-08: L4/A10G 22888, L40S 45776,
              # g4dn.metal T4 16384 -- so this floor excludes only the T4.
              key      = "karpenter.k8s.aws/instance-gpu-memory"
              operator = "Gt"
              values   = ["20000"]
            },
            {
              # Required by instanceStorePolicy = RAID0 above.
              key      = "karpenter.k8s.aws/instance-local-nvme"
              operator = "Gt"
              values   = ["0"]
            },
            {
              # A chain, not a choice: Karpenter prioritises reserved natively, so
              # this means "the tagged reservation if one exists, on-demand
              # otherwise". No 'spot' here: a real preemption could land before the
              # reader is ready to watch one, so the demo drives the interruption
              # deliberately instead. Adding 'spot' is the documented way to run
              # this on real Spot capacity -- see docs/DEMO.md.
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = local.capacity_types
            },
            ],
            # Appended, not replacing, so forcing a type can only shrink the set.
            length(var.gpu_instance_types) > 0 ? [{
              key      = "node.kubernetes.io/instance-type"
              operator = "In"
              values   = var.gpu_instance_types
            }] : []
          )

          taints = [{
            key    = "nvidia.com/gpu"
            effect = "NoSchedule"
          }]

          # Longer than the 120s Spot window so it never clips the pod's own grace.
          terminationGracePeriod = "5m"

          # Backstop if consolidation is not reached. In template.spec, not beside
          # `disruption` -- Karpenter v1 moved it.
          expireAfter = "24h"
        }
      }

      disruption = {
        # WhenEmpty only considers nodes with no workload pods, so the run is safe
        # without "Never" -- which instead left the $30/hr node idling forever.
        # `make odcr-cancel` is no substitute: cancelling leaves instances running.
        consolidationPolicy = "WhenEmpty"
        consolidateAfter    = "2m"
      }

    }
  })

  depends_on = [kubectl_manifest.gpu_node_class]
}

# --- Pod Identity so the training pod can reach S3 ------------------------
# Dedicated role: the node role would grant S3 to every pod on the node.

resource "aws_iam_role" "trainer" {
  name = "${var.cluster_name}-trainer"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "trainer_s3" {
  name = "${var.cluster_name}-trainer-s3"
  role = aws_iam_role.trainer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [data.aws_s3_bucket.artifacts.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
        Resource = ["${data.aws_s3_bucket.artifacts.arn}/*"]
      },
    ]
  })
}
