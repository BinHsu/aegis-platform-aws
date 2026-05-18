variable "platform_region" {
  description = "AWS region for the remote-state bucket + lock table. Sourced from regions.auto.tfvars.json top-level — single source of truth for 'which region does the platform live in'. Bootstrap puts state here because state co-locates with platform."
  type        = string
}

variable "bucket_prefix" {
  description = "Prefix for the global-unique S3 state bucket. Actual name is '<bucket_prefix>-<account_id>' computed in main.tf."
  type        = string
  default     = "aegis-stateless-tfstate"
}

variable "project_tag" {
  description = "Value of the Project tag applied to all resources."
  type        = string
  default     = "aegis-stateless"
}

variable "cost_center_tag" {
  description = "Value of the CostCenter tag applied to all resources."
  type        = string
  default     = "platform-take-home"
}
