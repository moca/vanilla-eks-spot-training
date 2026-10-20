# Local Prometheus is a scrape-and-forward buffer, not an archive. The durable
# workspace lives in the foundation root and is discovered here by alias.
data "aws_prometheus_workspaces" "amp" {
  alias_prefix = var.cluster_name
}

# one() errors on a multi-match instead of picking arbitrarily. The second lookup
# is only for prometheus_endpoint and the ARN, which the plural source omits.
data "aws_prometheus_workspace" "amp" {
  workspace_id = one(data.aws_prometheus_workspaces.amp.workspace_ids)
}

check "amp_discovery" {
  assert {
    condition     = length(data.aws_prometheus_workspaces.amp.workspace_ids) == 1
    error_message = "Expected exactly 1 AMP workspace with alias ${var.cluster_name}. Apply terraform/live/foundation first."
  }
}

# Cluster identities, so they die with the cluster; only the workspace outlives it.
# Separate from aws_iam_role.trainer: monitoring has no business holding the
# checkpoint write path.
resource "aws_iam_role" "amp" {
  name = "${var.cluster_name}-amp"

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

resource "aws_iam_role_policy" "amp" {
  name = "${var.cluster_name}-amp"
  role = aws_iam_role.amp.id

  # Adapted and modified from awslabs/ai-on-eks at revision a003ada9:
  # infra/base/terraform/amp.tf lines 92-108. Apache-2.0; see
  # THIRD_PARTY_NOTICES.md. This version removes the CloudWatch/Logs/EC2 actions
  # and aps:ListWorkspaces -- discovery happens above under the operator's
  # credentials, which lets Resource be one workspace ARN instead of "*".
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "aps:RemoteWrite",
        "aps:QueryMetrics",
        "aps:GetSeries",
        "aps:GetLabels",
        "aps:GetMetricMetadata",
      ]
      Resource = [data.aws_prometheus_workspace.amp.arn]
    }]
  })
}

# Names are the chart's defaults and are not overridden in observability.tf, so a
# wrong one is a silent 403 at remote-write time, not an apply error. These must
# exist BEFORE the chart installs: Pod Identity injects at pod admission, so a
# later association leaves the running Prometheus signing nothing.
resource "aws_eks_pod_identity_association" "amp" {
  for_each = toset(["kube-prometheus-stack-prometheus", "kube-prometheus-stack-grafana"])

  cluster_name    = module.eks.cluster_name
  namespace       = "monitoring"
  service_account = each.value
  role_arn        = aws_iam_role.amp.arn
}
