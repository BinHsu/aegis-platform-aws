# Per-region scalar inputs. Makefile / CI extracts these from
# regions.auto.tfvars.json via jq and passes via -var flags. var.regions
# map is intentionally NOT declared here — this env handles one region per
# apply.

variable "region" {
  description = "AWS region for this regional apply. Passed by Makefile/CI per loop iteration."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR for this region. From regions.auto.tfvars.json entry."
  type        = string
}

variable "node_instance" {
  description = "EC2 instance type for the managed node group."
  type        = string
}

variable "node_min" {
  description = "Minimum node group size."
  type        = number
}

variable "node_max" {
  description = "Maximum node group size."
  type        = number
}

# ---- cross-env wiring (set via TF_VAR_* by Makefile) ----------------------
variable "platform_region" {
  description = "Region where the platform env lives (Route 53 zone, ECR source, SSM creds). Sourced from regions.auto.tfvars.json top-level (single source of truth); Makefile/CI extracts via jq and injects as TF_VAR_platform_region."
  type        = string
}

variable "tfstate_bucket" {
  description = "S3 bucket holding remote state. Makefile exports via TF_VAR_tfstate_bucket from bootstrap output."
  type        = string
}

variable "tfstate_region" {
  description = "Region of the tfstate bucket. Equals platform_region by construction (bootstrap creates the bucket in the platform region)."
  type        = string
}

# ---- secrets (gitignored secrets.auto.tfvars locally; GH Actions secrets in CI) ----
variable "github_token" {
  description = "GitHub fine-grained PAT with admin:public_key scope on every workload deploy repo (regional-stack registers one ArgoCD deploy key per repo, per region)."
  type        = string
  sensitive   = true
}

variable "operator_principal_arn" {
  description = "ARN of the human operator's IAM principal — gets an explicit EKS ClusterAdmin access entry. Supply via gitignored secrets.auto.tfvars locally; GH Actions secret OPERATOR_PRINCIPAL_ARN in CI. Must be the SAME value in both."
  type        = string
}

# ---- deploy repos (single source of truth: workloads.auto.tfvars.json) ----
# Map of workloads ArgoCD reconciles into this region's cluster, keyed by
# ArgoCD Application name. Passed via -var-file=workloads.auto.tfvars.json by
# the Makefile / CI. Adding a workload = one JSON entry, zero .tf edits — the
# same data-driven pattern regions.auto.tfvars.json uses for regions.
variable "workloads" {
  description = "Workloads ArgoCD reconciles into each cluster, keyed by Application name. Single source of truth: workloads.auto.tfvars.json."
  type = map(object({
    repo_name    = string
    repo_url_ssh = string
    path         = optional(string, "k8s/overlays/prod")
    namespace    = string
    region_env = optional(object({
      deployment = string
      container  = string
      var_name   = string
    }))
    latency_ingress = optional(string)
  }))
}

# ---- tags -----------------------------------------------------------------
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
