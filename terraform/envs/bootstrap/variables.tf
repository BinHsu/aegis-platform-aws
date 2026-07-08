variable "platform_region" {
  description = "AWS region for the remote-state bucket + lock table. Sourced from regions.auto.tfvars.json top-level — single source of truth for 'which region does the platform live in'. Bootstrap puts state here because state co-locates with platform."
  type        = string
}

variable "bucket_prefix" {
  description = "Prefix for the global-unique S3 state bucket. Actual name is '<bucket_prefix>-<account_id>' computed in main.tf."
  type        = string
  default     = "aegis-platform-aws-tfstate"
}

variable "project_tag" {
  description = "Value of the Project tag applied to all resources."
  type        = string
  default     = "aegis-platform-aws"
}

variable "cost_center_tag" {
  description = "Value of the CostCenter tag applied to all resources."
  type        = string
  default     = "platform-take-home"
}

# ---- One-time IAM survivor adoption (prod cold-start) ----------------------
variable "adopt_seeded_iam_roles" {
  description = "ONE-TIME prod cold-start toggle. The prod account (506221082337) had its bootstrap state cleared, but the 5 CI IAM roles seeded by iam-seed.tf still exist as live AWS resources. Set true ONLY for the prod cold-start apply so iam-seed-import.tf ADOPTs the survivors into state instead of failing EntityAlreadyExists. Default false: a fresh account has no survivors, so the import targets must not be generated. Remove the variable + iam-seed-import.tf in a later cleanup PR once prod state is reconciled."
  type        = bool
  default     = false
}

# ---- CI IAM seed (ADR-13) --------------------------------------------------
variable "github_owner" {
  description = "GitHub org/user that owns aegis-greeter + aegis-platform-aws. Used in the OIDC trust subjects for the CI roles seeded here (iam-seed.tf). Must be set explicitly — no default — so a fork targeting a different org does not silently trust the original owner's repos."
  type        = string
  validation {
    condition     = length(trimspace(var.github_owner)) > 0
    error_message = "github_owner must be set explicitly for the target GitHub org/user."
  }
}

# ---- Immutable repository_id binding (issue #144) ---------------------------
# GitHub's `sub` claim carries the repo NAME, which changes on rename/transfer.
# The numeric repository_id is immutable for the life of the repo and is the
# binding these trust policies key on going forward — the sub's repo-name
# segment is wildcarded (StringLike `repo:<owner>/*:...`) so a rename cannot
# break CI auth, matching the pattern already in production in
# aegis-landing-zone-aws (oidc-github-*-role.tf, ADR-019 there). Fetch each
# value with `gh api repos/<owner>/<repo> --jq .id` — never guess it; a wrong
# id fails closed (StringEquals mismatch), so a bad value manifests as every
# CI OIDC assume-role failing, not a silent bypass.
variable "github_platform_repo_id" {
  description = "Numeric GitHub repository id (as a string) for aegis-platform-aws (this repo). Binds aegis-platform-aws-ci, gh-tf-apply-platform, and gh-tf-destroy-platform. Get it via: gh api repos/<owner>/aegis-platform-aws --jq .id"
  type        = string
  validation {
    condition     = can(regex("^[0-9]+$", var.github_platform_repo_id))
    error_message = "github_platform_repo_id must be the real numeric repository id, as a digit-only string (gh api repos/<owner>/aegis-platform-aws --jq .id)."
  }
}

variable "github_greeter_repo_id" {
  description = "Numeric GitHub repository id (as a string) for aegis-greeter. Binds aegis-greeter-ci. Get it via: gh api repos/<owner>/aegis-greeter --jq .id"
  type        = string
  validation {
    condition     = can(regex("^[0-9]+$", var.github_greeter_repo_id))
    error_message = "github_greeter_repo_id must be the real numeric repository id, as a digit-only string (gh api repos/<owner>/aegis-greeter --jq .id)."
  }
}

variable "github_core_repo_id" {
  description = "Numeric GitHub repository id (as a string) for aegis-core. Binds github-actions-aegis-core-frontend. Get it via: gh api repos/<owner>/aegis-core --jq .id"
  type        = string
  validation {
    condition     = can(regex("^[0-9]+$", var.github_core_repo_id))
    error_message = "github_core_repo_id must be the real numeric repository id, as a digit-only string (gh api repos/<owner>/aegis-core --jq .id)."
  }
}
