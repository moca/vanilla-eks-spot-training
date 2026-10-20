# Here, not in the eks root: `make down-cluster` would take every series with it.
# A rebuilt cluster's Grafana finds this by alias and re-attaches.
resource "aws_prometheus_workspace" "this" {
  alias = var.cluster_name
  tags  = local.tags
}
