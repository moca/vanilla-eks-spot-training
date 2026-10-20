# Division of labour: W&B = loss curve across the gap; DCGM = GPU utilization gap;
# Karpenter logs + events = the interruption path; S3 timestamps = work lost.
#
# Nothing here carries the nvidia.com/gpu toleration, so these pods structurally
# cannot land on a GPU node. DCGM is the deliberate exception below.

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "91.8.1"
  wait             = true
  timeout          = 900

  values = [yamlencode({
    # Demo scale: keep the footprint small enough for the system node group.
    prometheus = {
      prometheusSpec = {
        # A forwarding buffer, not an archive -- AMP holds the durable copy, and
        # these series die with `make down-cluster` anyway.
        retention = "6h"
        # Pick up ServiceMonitors from every namespace, not just this release's.
        serviceMonitorSelectorNilUsesHelmValues = false
        resources = {
          requests = { cpu = "200m", memory = "1Gi" }
          limits   = { memory = "2Gi" }
        }
        # Adapted and modified from awslabs/ai-on-eks revision a003ada9,
        # infra/base/terraform/helm-values/kube-prometheus.yaml lines 18-25.
        # Apache-2.0; see THIRD_PARTY_NOTICES.md. sigv4 without credentials
        # resolves through the SDK chain to the Pod Identity association in amp.tf.
        remoteWrite = [{
          url   = "${data.aws_prometheus_workspace.amp.prometheus_endpoint}api/v1/remote_write"
          sigv4 = { region = var.aws_region }
          queueConfig = {
            maxSamplesPerSend = 1000
            maxShards         = 200
            capacity          = 2500
          }
        }]
      }
    }
    grafana = {
      adminPassword = var.grafana_admin_password
      # No ALB, hence no Load Balancer Controller and no two-phase addon split.
      service = { type = "ClusterIP" }
      # Grafana ignores a datasource's sigV4Auth flag unless signing is turned on
      # process-wide, so without this the AMP datasource just returns 403.
      env = { GF_AUTH_SIGV4_AUTH_ENABLED = "true" }
      # Survives a teardown, unlike the chart's local datasource. trimsuffix because
      # prometheus_endpoint ends in / and Grafana appends its own /api/v1/query.
      additionalDataSources = [{
        name   = "AMP"
        type   = "prometheus"
        access = "proxy"
        url    = trimsuffix(data.aws_prometheus_workspace.amp.prometheus_endpoint, "/")
        jsonData = {
          httpMethod    = "POST"
          sigV4Auth     = true
          sigV4AuthType = "default"
          sigV4Region   = var.aws_region
        }
      }]
    }
    alertmanager = { enabled = false } # nothing to page in a demo
  })]

  depends_on = [aws_eks_pod_identity_association.amp]
}

# DCGM exporter: per-GPU utilization, memory, power, temperature, SM clock.
# DCGM_FI_DEV_GPU_UTIL is the metric that shows the interruption as a gap.
resource "helm_release" "dcgm_exporter" {
  name             = "dcgm-exporter"
  namespace        = "monitoring"
  create_namespace = true
  repository       = "https://nvidia.github.io/dcgm-exporter/helm-charts"
  chart            = "dcgm-exporter"
  version          = "4.8.4"
  wait             = false # no GPU nodes exist until a training pod requests one

  values = [yamlencode({
    # MUST tolerate the NodePool taint or it never runs where it measures.
    nodeSelector = {
      "karpenter.sh/nodepool" = "gpu-nanochat"
    }
    tolerations = [{
      key      = "nvidia.com/gpu"
      operator = "Exists"
      effect   = "NoSchedule"
    }]
    serviceMonitor = {
      enabled  = true
      interval = "15s" # tighter than the 30s default: a 2-minute drain is short
      # MUST be set alongside interval: the chart's 25s default exceeds 15s and
      # prometheus-operator then rejects the WHOLE ServiceMonitor. It stays
      # Applied, no scrape job is generated, and the symptom is an empty Grafana.
      # This is why DCGM had zero series for the first day.
      scrapeTimeout = "10s"
    }
  })]

  depends_on = [helm_release.kube_prometheus_stack, kubectl_manifest.gpu_node_pool]
}

# --- W&B API key -----------------------------------------------------------
# The secret lives in the foundation root; apply that first if this read fails
# with "couldn't find resource". No `check` can soften it -- the ARN below needs
# the value, and a check only runs after the data source resolves.
data "aws_secretsmanager_secret" "wandb" {
  name = "${var.cluster_name}/wandb-api-key"
}

# The permission hangs off a cluster identity, so it dies with the cluster.
resource "aws_iam_role_policy" "trainer_wandb_secret" {
  name = "${var.cluster_name}-trainer-wandb"
  role = aws_iam_role.trainer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [data.aws_secretsmanager_secret.wandb.arn]
    }]
  })
}
