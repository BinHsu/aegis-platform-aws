provider "aws" {
  region = var.platform_region

  default_tags {
    tags = {
      Project    = var.project_tag
      Env        = "bootstrap"
      ManagedBy  = "terraform"
      Repo       = "github.com/BinHsu/aegis-stateless"
      CostCenter = var.cost_center_tag
    }
  }
}
