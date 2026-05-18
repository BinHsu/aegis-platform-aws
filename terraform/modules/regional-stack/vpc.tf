module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "aegis-stateless-${var.region}"
  cidr = var.vpc_cidr

  azs             = local.azs
  public_subnets  = local.public_subnet_cidrs
  private_subnets = local.private_subnet_cidrs

  enable_dns_hostnames = true
  enable_dns_support   = true

  # Single NAT gateway — FinOps tradeoff. Per-AZ NAT (3x cost) is the
  # production posture for AZ-failure isolation; documented in
  # docs/tradeoffs.md.
  enable_nat_gateway = true
  single_nat_gateway = true

  # EKS + ALB controller subnet tags — required so the ALB controller can
  # discover which subnets to attach load balancers to.
  public_subnet_tags = {
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  tags = local.common_tags
}
