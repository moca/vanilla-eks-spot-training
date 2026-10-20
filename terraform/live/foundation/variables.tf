variable "aws_region" {
  # No default: the region is wherever find-capacity.sh actually got GPU hosts.
  # It must offer a gpu_count-GPU type and clear On-Demand-G quota for TWO nodes.
  description = "AWS region; written by scripts/configure.sh"
  type        = string
}

variable "cluster_name" {
  description = "Cluster name; also the karpenter.sh/discovery tag value and ECR repo name"
  type        = string
  default     = "nanochat-demo"
}

variable "availability_zones_count" {
  # Default covers every AZ in any current region (min() clamps it). The ODCR is
  # reserved before the VPC exists, so an uncovered AZ is a reservation Karpenter
  # can never launch into. Lower it only to match a VPC that already exists.
  description = "How many of the region's AZs get subnets"
  type        = number
  default     = 16
}
