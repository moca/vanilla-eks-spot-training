terraform {
  required_version = "~> 1.14"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.19"
    }
  }

  # Partial, but NOT empty: bucket/key/region come from the generated backend.hcl,
  # these two are policy and stay committed. An empty block left state unlocked
  # between 4f29c16 and the first configure.sh run, with no DynamoDB fallback.
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}

# No profile: ambient credentials. See the foundation root.
provider "aws" {
  region = var.aws_region
}

# exec plugin: the token cannot go stale mid-apply and never reaches state.
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
    }
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}

data "aws_caller_identity" "current" {}

# Not the "arn:aws:" literal: elsewhere that prefix names a policy that does not
# exist, and the failure is an IAM attach error that never mentions partitions.
data "aws_partition" "current" {}

locals {
  tags = {
    Project   = var.cluster_name
    ManagedBy = "terraform"
    Layer     = "eks"
  }

  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  # Ordered as a preference chain -- see the NodePool requirement in karpenter.tf.
  capacity_types = ["reserved", "on-demand"]

  # Derived exactly as the foundation root derives it, so the two cannot disagree.
  bucket_name = "${var.cluster_name}-artifacts-${local.account_id}-${var.aws_region}"
}

# --- Discovery by tag, not terraform_remote_state -------------------------
# Decoupled from foundation's output layout.

data "aws_subnets" "private" {
  filter {
    name   = "tag:karpenter.sh/discovery"
    values = [var.cluster_name]
  }
}

data "aws_subnet" "private" {
  for_each = toset(data.aws_subnets.private.ids)
  id       = each.value
}

data "aws_vpc" "this" {
  # one() errors if the subnets span more than one VPC -- tag-collision guard.
  id = one(distinct([for s in data.aws_subnet.private : s.vpc_id]))
}

data "aws_s3_bucket" "artifacts" {
  bucket = local.bucket_name
}

check "subnet_discovery" {
  assert {
    condition     = length(data.aws_subnets.private.ids) >= 2
    error_message = "Expected >=2 subnets tagged karpenter.sh/discovery=${var.cluster_name}. Apply terraform/live/foundation first."
  }
}

# --- Cluster --------------------------------------------------------------

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.26.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = data.aws_vpc.this.id
  subnet_ids = data.aws_subnets.private.ids

  endpoint_private_access      = true
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  # Access entries (API mode) rather than the aws-auth ConfigMap.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  # before_compute: networking and pod identity ACTIVE before any node joins.
  addons = {
    vpc-cni                = { before_compute = true }
    eks-pod-identity-agent = { before_compute = true }
    coredns                = {}
    kube-proxy             = {}
  }

  # Karpenter cannot schedule the node that runs Karpenter. Also hosts Argo,
  # Prometheus and Grafana, hence .xlarge over .large. What keeps those off the
  # GPU nodes is the NodePool's nvidia.com/gpu taint, which only DCGM tolerates.
  eks_managed_node_groups = {
    system = {
      instance_types = ["m7i.xlarge"]
      min_size       = 2
      max_size       = 4
      desired_size   = 2

      # 100 GiB, not the AMI's 20. Measured 2026-10-09: the default left
      # 20893676Ki capacity, and dataset(0) was evicted at 1.26 GiB available
      # against kubelet's ~2 GiB threshold. The prep stages unpack a 4.5 GB image
      # (~12 GiB on disk) plus an emptyDir of fineweb shards, beside
      # kube-prometheus-stack. The retry succeeded on the other node, so the DAG
      # still went green -- which is why this hid for ten days.
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 100
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
    }
  }

  # securityGroupSelectorTerms matches this. The NODE SG is the one Karpenter's
  # nodes must attach to in order to reach the control plane.
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  tags = local.tags
}
