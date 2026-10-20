# Scope is the base_train path only (dataset -> tokenizer -> train): it is the one
# stage with upstream --resume-from-step support and the one worth interrupting.

# Hoisted out of the values block only so the hash below can cover them.
# artifactRepository is hot-reloaded but the metrics server binds ONCE at startup,
# so a surviving controller pod serves self-signed TLS on 9090 while its ConfigMap
# says `secure: false` -- a permanent 400 behind a green apply.
locals {
  argo_metrics_config = { enabled = true }

  # Without archiveLogs the drained attempt's stdout is unrecoverable. The uploader
  # is the pod's `wait` sidecar, so it runs under the argo-workflow SA and must
  # finish inside the pod's grace period.
  argo_artifact_repository = {
    archiveLogs = true
    s3 = {
      bucket = data.aws_s3_bucket.artifacts.id

      # Explicit: trainer_s3 grants no s3:GetBucketLocation, and Argo's fallback
      # when that call is denied is us-east-1.
      region = var.aws_region

      # SDK provider chain -> the Pod Identity associations below. No keys.
      useSDKCreds = true

      # Outside runs/, which sync_down walks -- otherwise every replacement node
      # downloads the logs. pod.name is unique per attempt.
      keyFormat = "argo-logs/{{workflow.name}}/{{pod.name}}"
    }
  }
}

resource "helm_release" "argo_workflows" {
  name             = "argo-workflows"
  namespace        = "argo"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-workflows"
  version          = "2.0.8"
  wait             = true
  timeout          = 900

  values = [yamlencode({
    # Single-namespace scope keeps RBAC trivial for a demo.
    workflow = {
      serviceAccount = { create = true, name = "argo-workflow" }
      rbac           = { create = true }
    }
    controller = {
      workflowNamespaces = ["default"]

      # Per-template duration and retry counts. Interval and scrapeTimeout left
      # unset: the chart's own pair is coherent, and overriding one silenced DCGM
      # for a day.
      metricsConfig  = local.argo_metrics_config
      serviceMonitor = { enabled = true }

      # The chart puts no config checksum on the Deployment, so a ConfigMap-only
      # change leaves the pod untouched. This moves the pod spec with the config.
      podAnnotations = {
        "nanochat.io/config-hash" = substr(sha256(jsonencode([
          local.argo_metrics_config, local.argo_artifact_repository,
        ])), 0, 16)
      }
    }
    server = {
      # No ALB, so no Load Balancer Controller and no two-phase webhook split.
      serviceType = "ClusterIP"
      authModes   = ["server"] # demo: skip SSO, the UI is only reachable locally
    }

    artifactRepository = local.argo_artifact_repository
  })]

  # kube_prometheus_stack: the chart's install-time APIVersions check renders no
  # ServiceMonitor if it wins the race against the operator's CRDs.
  # The associations are listed HERE, not the reverse: Pod Identity is injected at
  # pod ADMISSION, so the old direction left argo-server credential-less on every
  # apply and the UI returned 500 on archived logs.
  depends_on = [
    helm_release.kube_prometheus_stack,
    aws_eks_pod_identity_association.argo_workflow,
    aws_eks_pod_identity_association.argo_server,
  ]
}

# Argo runs pods under its own SA, not nanochat-trainer.
resource "aws_eks_pod_identity_association" "argo_workflow" {
  cluster_name    = module.eks.cluster_name
  namespace       = "default"
  service_account = "argo-workflow"
  role_arn        = aws_iam_role.trainer.arn
}

# argo-server opens the artifact driver itself rather than proxying through the
# controller, so without this the objects exist and the UI errors. Same role.
resource "aws_eks_pod_identity_association" "argo_server" {
  cluster_name    = module.eks.cluster_name
  namespace       = "argo"
  service_account = "argo-workflows-server"
  role_arn        = aws_iam_role.trainer.arn
}
