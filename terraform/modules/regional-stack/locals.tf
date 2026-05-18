data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  cluster_name = "aegis-stateless-${var.region}"

  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  # /20 subnets carved out of var.vpc_cidr — 3 public + 3 private.
  public_subnet_cidrs  = [for i in range(3) : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnet_cidrs = [for i in range(3) : cidrsubnet(var.vpc_cidr, 4, i + 8)]

  common_tags = {
    Project    = var.project_tag
    Env        = "regional"
    Region     = var.region
    ManagedBy  = "terraform"
    Repo       = "github.com/BinHsu/aegis-stateless"
    CostCenter = var.cost_center_tag
  }
}
