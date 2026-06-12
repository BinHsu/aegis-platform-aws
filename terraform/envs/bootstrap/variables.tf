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

# ---- CI IAM seed (ADR-13) --------------------------------------------------
variable "github_owner" {
  description = "GitHub org/user that owns aegis-greeter + aegis-platform-aws. Used in the OIDC trust subjects for the CI roles seeded here (iam-seed.tf). Must be set explicitly — no default — so a fork targeting a different org does not silently trust the original owner's repos."
  type        = string
  validation {
    condition     = length(trimspace(var.github_owner)) > 0
    error_message = "github_owner must be set explicitly for the target GitHub org/user."
  }
}
