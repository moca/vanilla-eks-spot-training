variable "aws_region" {
  # No default: must match the foundation root, which this one discovers by
  # tag/name within the region. scripts/configure.sh writes it.
  description = "AWS region"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name; must match the karpenter.sh/discovery tag value"
  type        = string
  default     = "nanochat-demo"
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "Operator egress CIDRs permitted to reach the EKS public API endpoint"
  type        = list(string)
  nullable    = false

  validation {
    condition = (
      length(var.cluster_endpoint_public_access_cidrs) > 0 &&
      alltrue([
        for cidr in var.cluster_endpoint_public_access_cidrs :
        can(cidrhost(cidr, 0)) &&
        try(tonumber(split("/", cidr)[1]) > 0, false)
      ])
    )
    error_message = "Supply at least one valid operator CIDR; prefix-length /0 CIDRs are forbidden."
  }
}

variable "kubernetes_version" {
  description = "EKS control plane version"
  type        = string
  default     = "1.36"
}

variable "gpu_instance_types" {
  # Optional narrowing. The NodePool selects on attributes, so no edit here is
  # needed to fall back to another family. Every entry MUST have gpu_count GPUs:
  # nanochat shards optimizer state per rank and a resume needs a constant width.
  description = "Optional narrowing list for the GPU NodePool; empty = attributes only"
  type        = list(string)
  default     = []
}

variable "gpu_count" {
  # scripts/configure.sh asserts the other three copies of this number agree.
  description = "GPUs per node, pinned to nanochat's native --nproc_per_node=8"
  type        = number
  default     = 8
}

variable "grafana_admin_password" {
  description = "Grafana admin password. Demo-scope: ClusterIP, reached via port-forward."
  type        = string
  default     = "nanochat-demo"
}
