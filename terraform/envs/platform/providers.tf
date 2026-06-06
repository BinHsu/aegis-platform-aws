provider "aws" {
  region = var.platform_region

  default_tags {
    tags = {
      Project    = var.project_tag
      Env        = "platform"
      ManagedBy  = "terraform"
      Repo       = "github.com/BinHsu/aegis-platform-aws"
      CostCenter = var.cost_center_tag
    }
  }
}

# Cost Explorer / Cost Anomaly Detection is a global service homed in us-east-1
# (A2, ce-anomaly.tf). Everything else uses the platform_region provider above.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project    = var.project_tag
      Env        = "platform"
      ManagedBy  = "terraform"
      Repo       = "github.com/BinHsu/aegis-platform-aws"
      CostCenter = var.cost_center_tag
    }
  }
}

provider "grafana" {
  # `auth` is a Grafana *instance* service-account token (glsa_…), NOT the
  # glc_ Cloud Access Policy token. The provider manages dashboards /
  # folders / alert rules / data-source lookups via the Grafana instance
  # API (aegis.grafana.net/api/…); the glc_ token authenticates only to
  # the data backends + grafana.com, and returns 401 here.
  url  = var.grafana_cloud_url
  auth = var.grafana_auth_token
}

provider "github" {
  owner = var.github_owner
  token = var.github_token
}
