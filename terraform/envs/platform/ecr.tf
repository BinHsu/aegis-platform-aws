# AES256 (AWS-managed) is the take-home encryption choice; customer-managed
# KMS for ECR is documented in docs/tradeoffs.md as production hardening.
#tfsec:ignore:aws-ecr-repository-customer-key
resource "aws_ecr_repository" "greeter" {
  name = var.ecr_repository_name

  # Teardown-to-zero must delete non-empty repos (2026-06-12 prod RepositoryNotEmptyException).
  force_delete = true

  # IMMUTABLE — the sibling repo's CI pushes a unique commit-SHA tag per
  # build and bumps k8s/overlays/prod/kustomization.yaml to match. Tags
  # are never overwritten, so immutability is free correctness: a given
  # tag always resolves to the same image digest.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "greeter" {
  repository = aws_ecr_repository.greeter.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the last 10 tagged images"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = 10
        }
        action = { type = "expire" }
      },
    ]
  })
}

# ---- replication ----------------------------------------------------------
locals {
  # Active regions = enabled in regions.auto.tfvars.json. Disabled entries
  # are present-but-inactive (Pattern X — "multi-region designed, single-
  # region deployed" expressed as a boolean flag, not as commented-out
  # JSON since JSON has no comments).
  active_regions = { for r, v in var.regions : r => v if v.enabled }

  # ECR replicates outward from var.platform_region to every OTHER active
  # region. Per ADR-01: ECR rejects an apply where a destination
  # equals the source region — the filter is mandatory.
  ecr_replication_destinations = [
    for r in keys(local.active_regions) : r if r != var.platform_region
  ]
}

resource "aws_ecr_replication_configuration" "main" {
  count = length(local.ecr_replication_destinations) > 0 ? 1 : 0

  replication_configuration {
    rule {
      dynamic "destination" {
        for_each = local.ecr_replication_destinations
        content {
          region      = destination.value
          registry_id = data.aws_caller_identity.current.account_id
        }
      }
    }
  }
}
