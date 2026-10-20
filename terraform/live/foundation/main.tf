terraform {
  required_version = "~> 1.14"

  required_providers {
    # VPC module 6.7.3 and EKS module 21.x both require provider >= 6.28.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }
  }

  # Partial: a backend block cannot take variables, so bucket/key/region come from
  # the generated backend.hcl via `terraform init -backend-config`. These two are
  # policy, not pins, and stay committed. Native S3 locking, no DynamoDB table.
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}

# No profile: ambient credentials. The account guard lives where it can fail
# loudly instead -- the sts assertion in find-capacity.sh and `require-config`.
provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

# Named AZs are region-coupled, and a hardcoded pair can miss the AZ the reserved
# hosts landed in -- an ODCR that is active, billing and unreachable.
data "aws_availability_zones" "available" {
  filter {
    name = "zone-type"
    # Excludes Local Zones and Wavelength: they cannot host EKS subnets.
    values = ["availability-zone"]
  }
}

locals {
  tags = {
    Project   = var.cluster_name
    ManagedBy = "terraform"
    Layer     = "foundation"
  }

  account_id = data.aws_caller_identity.current.account_id

  # min(), so the count is a ceiling: asking for more AZs than exist is not fatal.
  azs = slice(
    data.aws_availability_zones.available.names,
    0,
    min(var.availability_zones_count, length(data.aws_availability_zones.available.names)),
  )

  vpc_cidr = "10.0.0.0/16"

  # Derived, never written: an account ID in a tfvars file is the most
  # account-specific line a repo can carry. Region-suffixed; bucket names are global.
  bucket_name = "${var.cluster_name}-artifacts-${local.account_id}-${var.aws_region}"
}

# Separate state from the disposable cluster: one combined state would let a
# mistargeted destroy of the cluster erase hours of training.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = "${var.cluster_name}-vpc"
  cidr = local.vpc_cidr

  # Computed from local.azs so the lists stay the same length -- the module pairs
  # azs[i] with subnets[i], and a short list silently drops an AZ.
  azs             = local.azs
  private_subnets = [for i, _ in local.azs : cidrsubnet(local.vpc_cidr, 4, i)]
  public_subnets  = [for i, _ in local.azs : cidrsubnet(local.vpc_cidr, 8, 240 + i)]

  enable_nat_gateway   = true
  single_nat_gateway   = true # demo: one NAT is sufficient and cheaper
  enable_dns_hostnames = true

  # The one discovery idiom: Karpenter and the eks root both find these by tag,
  # so no terraform_remote_state coupling.
  private_subnet_tags = {
    "karpenter.sh/discovery"          = var.cluster_name
    "kubernetes.io/role/internal-elb" = "1"
  }

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  tags = local.tags
}

resource "aws_s3_bucket" "artifacts" {
  bucket = local.bucket_name
  tags   = local.tags

  # Without this `make down` stopped PARTWAY on 2026-10-08, after the VPC, NAT,
  # AMP workspace and secret were gone. The accident guard is the Makefile's
  # plan-then-apply-by-hand, which is stronger than a non-empty-bucket error.
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning is deliberately OFF: checkpoints are step-stamped and immutable, so
# versioning multi-GB .pt files would multiply cost for no recovery benefit.

resource "aws_ecr_repository" "nanochat" {
  name                 = var.cluster_name
  image_tag_mutability = "MUTABLE"

  # See force_destroy above; this is the resource that failed the 2026-10-08
  # teardown. Every image is rebuildable from the Dockerfile plus the fork SHA.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.tags
}

# Free, and without it every checkpoint byte crosses the single NAT gateway at
# $0.045/GB -- inflating the recovery time this demo exists to measure.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = merge(local.tags, { Name = "${var.cluster_name}-s3" })
}
