# Single static provider per regional apply.
#
# Multi-region orchestration lives OUTSIDE Terraform — Makefile / CI loops
# over the enabled entries in `regions.auto.tfvars.json` and invokes this
# env once per region with `-var=region=<region>` and per-region scalars.
# Each invocation gets its own state key (`regional/<region>/terraform.tfstate`)
# so per-region blast radius is fully isolated.
#
# Background: provider for_each is reserved-but-not-implemented in
# Terraform 1.16-alpha (verified 2026-05-15). External orchestration is
# the cleaner alternative — see backlog.md Decision log + ADR-01.

provider "aws" {
  region = var.region

  # Adaptive retry absorbs S3 (and other) read-after-write eventual-consistency races on
  # freshly-created resources — e.g. the fresh model bucket tag read that flaked eu-west-1 (issue #4).
  retry_mode  = "adaptive"
  max_retries = 30

  default_tags {
    tags = {
      Project    = var.project_tag
      Env        = "regional"
      Region     = var.region
      ManagedBy  = "terraform"
      Repo       = "github.com/BinHsu/aegis-platform-aws"
      CostCenter = var.cost_center_tag
    }
  }
}

# Cross-region read of platform's SSM parameters (Grafana Cloud creds live
# in the platform region, this cluster may be in a different region).
provider "aws" {
  alias  = "platform"
  region = var.platform_region

  retry_mode  = "adaptive"
  max_retries = 30

  default_tags {
    tags = {
      Project    = var.project_tag
      Env        = "regional"
      Region     = var.region
      ManagedBy  = "terraform"
      Repo       = "github.com/BinHsu/aegis-platform-aws"
      CostCenter = var.cost_center_tag
    }
  }
}

# kubernetes + helm providers — configured via `exec` (calls `aws eks
# get-token` at apply time) so they tolerate the cluster not existing yet
# on first apply.
provider "kubernetes" {
  host                   = module.stack.cluster_endpoint
  cluster_ca_certificate = base64decode(module.stack.cluster_ca_certificate)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.stack.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.stack.cluster_endpoint
    cluster_ca_certificate = base64decode(module.stack.cluster_ca_certificate)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.stack.cluster_name, "--region", var.region]
    }
  }
}

# The github provider is gone — the module no longer mints per-workload deploy
# keys (ADR-07 / D2). var.github_token is now passed through to the module as a
# value (the SCM-generator's org-read token in a k8s Secret), not used to
# configure a provider here.
