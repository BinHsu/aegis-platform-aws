# Per-region scalar inputs. Makefile / CI extracts these from
# regions.auto.tfvars.json via jq and passes via -var flags. var.regions
# map is intentionally NOT declared here — this env handles one region per
# apply.

variable "region" {
  description = "AWS region for this regional apply. Passed by Makefile/CI per loop iteration."
  type        = string
}

# NOTE (WS4 / ADR-23): vpc_cidr removed. The regional VPC CIDR now comes from
# the landing-zone IPAM pool (regional-stack/vpc-ipam.tf, resolved by locale),
# not from regions.auto.tfvars.json. CI no longer sets TF_VAR_vpc_cidr.
variable "environment" {
  description = "Environment name for this cluster (staging | prod). Selects the deploy-repo overlay ArgoCD syncs (k8s/overlays/<environment>). Default prod preserves the pre-multi-account behavior; the W3 account callers inject TF_VAR_environment from accounts.json."
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["staging", "prod"], var.environment)
    error_message = "environment must be one of: staging, prod."
  }
}

variable "node_instance_types" {
  # #183 — see modules/regional-stack/variables.tf for the full rationale.
  description = "EC2 instance types for the Spot managed node group, in preference order. List >=2 for Spot capacity-pool diversification."
  type        = list(string)
}

variable "node_min" {
  description = "Minimum node group size (Spot group)."
  type        = number
}

variable "node_max" {
  description = "Maximum node group size (Spot group)."
  type        = number
}

variable "node_ondemand_baseline" {
  # #183 — see modules/regional-stack/variables.tf for the full rationale.
  description = "Size of a dedicated On-Demand node-group floor alongside the Spot group. 0 disables it (no On-Demand baseline)."
  type        = number
  default     = 0
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
variable "operator_principal_arn" {
  description = "ARN of the human operator's IAM principal — gets an explicit EKS ClusterAdmin access entry. Supply via gitignored secrets.auto.tfvars locally; GH Actions secret OPERATOR_PRINCIPAL_ARN in CI. Must be the SAME value in both."
  type        = string
}

# ---- workload registries (gitignored: registries.auto.tfvars.json) --------
# The workload CATALOG is gone — ArgoCD discovers workloads by the
# `aegis-workload` GitHub topic (ADR-07). This map holds only what discovery
# CANNOT supply: the ECR registry to inject (D4 account-ID hide; account IDs
# are sensitive → gitignored) and opt-in engine IRSA params. Passed via
# -var-file=registries.auto.tfvars.json by the Makefile / CI. Onboarding a
# workload that uses private ECR = tag the repo (zero-PR discovery) + one
# gitignored entry here.
variable "workload_registries" {
  description = "Per-workload registry + optional IRSA params, keyed by deploy-repo name. Source: gitignored registries.auto.tfvars.json."
  type = map(object({
    ecr_account_id = string
    ecr_region     = string
    engine_irsa = optional(object({
      service_account = string
      role_name       = string
      # WS3 (ADR-18/19): managed-policy ARNs (e.g. model-read) attached to the
      # engine's ACK role via the WorkloadIdentity Claim's policyArns. Injected
      # (account-bound), not committed to the public deploy repo.
      policy_arns = optional(list(string))
    }))
    ingress_cert = optional(object({
      ingress_name = string
      # WS3-R: optional override; omit to use the per-region module cert.
      cert_arn = optional(string)
    }))
  }))
  default = {}
}

# ---- GitOps facts bridge --------------------------------------------------
variable "cluster_profile" {
  description = "Cluster lifecycle profile written onto the in-cluster ArgoCD `cluster` Secret as the aegis.binhsu.org/profile annotation (facts bridge, ADR-25). ephemeral = throwaway CI/burn cluster; full = long-lived. Inert in A1; A6 selects add-on scope on it. Default ephemeral (safe for burns); set full for a long-lived cluster."
  type        = string
  default     = "ephemeral"

  validation {
    condition     = contains(["ephemeral", "full"], var.cluster_profile)
    error_message = "cluster_profile must be one of: ephemeral, full."
  }
}

# ---- observability toggle -------------------------------------------------
variable "enable_observability" {
  description = "Whether to wire the in-cluster Grafana Alloy observability stack. Default FALSE (matches the platform env default). Set false to skip the SSM lookups of the Grafana Cloud creds (which do not exist when the platform env was applied with enable_observability=false) and to skip the creds bridge (monitoring namespace + grafana-cloud-credentials Secret) in the regional-stack module. Alloy itself is GitOps-owned (gitops/platform-addons/addons/alloy/ — ADR-25); without the creds bridge its DaemonSet cannot reach Grafana Cloud. MUST match the platform env's enable_observability — a precondition (observability-guard.tf) fails loud if this is true while the platform stored no creds."
  type        = bool
  default     = false
}

# ---- tags -----------------------------------------------------------------
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
