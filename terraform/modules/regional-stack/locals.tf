data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # NOTE: keep this short. The EKS module derives the cluster IAM role from it as
  # name_prefix = "${cluster_name}-cluster-", and IAM name_prefix is capped at 38.
  # "aegis-platform-aws-eu-central-1-cluster-" is 40 → over the cap. Dropping the
  # "-aws" segment ("aegis-platform-eu-central-1" = 27, +"-cluster-" = 36) fits
  # every current AWS region (≤ 14 chars → ≤ 38). The repo + account already
  # carry the "aws" marker; the cluster name does not need it.
  cluster_name = "aegis-platform-${var.region}"

  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  # /20 subnets carved out of the IPAM-allocated /16 (vpc-ipam.tf) — 3 public +
  # 3 private. The allocation's .cidr is known-after-apply, so these values are
  # unknown at plan, but the list LENGTH is fixed by range(3) — the subnet
  # resources expand at plan, only their cidr_block is computed. No for_each/
  # count keys on the unknown cidr, so the cold-start plan stays clean.
  ipam_vpc_cidr        = aws_vpc_ipam_pool_cidr_allocation.regional.cidr
  public_subnet_cidrs  = [for i in range(3) : cidrsubnet(local.ipam_vpc_cidr, 4, i)]
  private_subnet_cidrs = [for i in range(3) : cidrsubnet(local.ipam_vpc_cidr, 4, i + 8)]

  common_tags = {
    Project    = var.project_tag
    Env        = "regional"
    Region     = var.region
    ManagedBy  = "terraform"
    Repo       = "github.com/BinHsu/aegis-platform-aws"
    CostCenter = var.cost_center_tag
  }
}
