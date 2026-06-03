variable "region" {
  description = "AWS region this stack instance runs in. Used in resource names, IRSA-trusted role names, ArgoCD deploy-key title, alloy resource prefix."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block. Provisioned across 3 AZs with public+private subnets."
  type        = string
}

variable "node_instance" {
  description = "EC2 instance type for the EKS managed node group."
  type        = string
  default     = "t3.medium"
}

variable "node_min" {
  description = "Minimum node count for the managed node group."
  type        = number
}

variable "node_max" {
  description = "Maximum node count for the managed node group."
  type        = number
}

# zone_id / zone_name ARE module inputs — external-dns (external-dns.tf)
# consumes them: zone_id scopes its IRSA record-write policy, zone_name is
# its domain filter.
#
# NOTE: ecr_url / alb_logs_bucket / repo_url_https remain intentionally
# absent — nothing in this module consumes them. The greeter image
# reference is set in k8s/overlays/prod (kustomize) + per-region by the
# ArgoCD Application; ALB access logs are an operator-local overlay; ArgoCD
# authenticates via the SSH repo URL. Re-add only when a consumer exists.

variable "zone_id" {
  description = "Route 53 hosted zone ID (from the platform env). Scopes external-dns's IRSA record-write policy to this one zone."
  type        = string
}

variable "zone_name" {
  description = "Route 53 hosted zone name (from the platform env). external-dns uses it as its domain filter."
  type        = string
}

# The workload CATALOG is gone (ADR-07): ArgoCD's ApplicationSet discovers
# workloads by the `aegis-workload` GitHub topic, not from a map here. What
# remains is per-workload data the SCM generator CANNOT discover — the ECR
# registry to inject (D4 account-ID hide) and, for workloads that declare
# workload-scoped IAM, the engine ServiceAccount + ACK role name. Keyed by
# deploy-repo name so the ApplicationSet's Merge generator can join on it.
# Source: gitignored registries.auto.tfvars.json (account IDs stay out of git).
variable "workload_registries" {
  description = "Per-workload registry + optional IRSA params the SCM generator cannot discover, keyed by deploy-repo name. ECR account IDs are sensitive (kept gitignored). engine_irsa is opt-in (greeter declares none)."
  type = map(object({
    ecr_account_id = string
    ecr_region     = string
    engine_irsa = optional(object({
      service_account = string
      role_name       = string
    }))
    # Account-bound (account ID in the ARN) → injected, kept out of the public
    # deploy repo. The cert is per-(workload,region); a single value here is
    # correct for one region — multi-region wants a per-region lookup (E2E
    # PENDING refinement). The deploy repo drops its hardcoded cert-arn.
    ingress_cert = optional(object({
      ingress_name = string
      cert_arn     = string
    }))
  }))
  default = {}
}

variable "scm_token" {
  description = "GitHub org-read token the ArgoCD SCM-provider generator uses to enumerate aegis-workload-tagged repos. Replaces the per-workload deploy keys (deploy repos are public → anonymous clone). Needs read:org + repo metadata, NOT admin:public_key."
  type        = string
  sensitive   = true
}

variable "ci_role_arn" {
  description = "ARN of the aegis-platform-aws-ci IAM role (CI plan). Gets an EKS ClusterAdmin access entry so `terraform plan` from CI can read Helm/k8s state."
  type        = string
}

variable "apply_role_arn" {
  description = "ARN of the gh-tf-apply-platform IAM role (CI apply). Gets an EKS ClusterAdmin access entry so `terraform apply` from CI can manage Helm/k8s resources."
  type        = string
}

variable "operator_principal_arn" {
  description = "ARN of the human operator's IAM principal. Gets an explicit EKS ClusterAdmin access entry so operator cluster access is declarative + survives a cluster recreate by any principal (the implicit creator grant does not — see eks.tf)."
  type        = string
}

# ---- observability toggle -------------------------------------------------
variable "enable_observability" {
  description = "Whether to deploy the in-cluster Grafana Alloy collector (DaemonSet), the monitoring namespace, the node-exporter + kube-state-metrics subcharts, and the grafana-cloud-credentials Secret. Default FALSE (the regional env passes this explicitly; the default just makes a bare module use observability-free). Set true to deploy the entire alloy.tf surface — the gc_* vars are then required."
  type        = bool
  default     = false
}

# ---- Grafana Cloud creds (sensitive) -------------------------------------
# Default "" so the module applies cleanly with enable_observability=false
# (the gc_* values are only consumed by the gated alloy.tf Secret).
variable "gc_api_token" {
  description = "Grafana Cloud API token (admin on the aegis stack). Embedded in a K8s Secret used by Alloy."
  type        = string
  sensitive   = true
  default     = ""
}

variable "gc_mimir_url" {
  description = "Mimir remote_write endpoint."
  type        = string
  sensitive   = true
  default     = ""
}

variable "gc_mimir_username" {
  description = "Mimir remote_write username (GC Prometheus instance ID)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "gc_loki_url" {
  description = "Loki push endpoint."
  type        = string
  sensitive   = true
  default     = ""
}

variable "gc_loki_username" {
  description = "Loki push username (GC Loki instance ID)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "gc_tempo_url" {
  description = "Tempo OTLP endpoint."
  type        = string
  sensitive   = true
  default     = ""
}

variable "gc_tempo_username" {
  description = "Tempo OTLP username (GC Tempo instance ID)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "gc_pyroscope_url" {
  description = "Pyroscope ingest endpoint."
  type        = string
  sensitive   = true
  default     = ""
}

variable "gc_pyroscope_username" {
  description = "Pyroscope username (GC Pyroscope instance ID)."
  type        = string
  sensitive   = true
  default     = ""
}

# ---- tags -----------------------------------------------------------------
variable "project_tag" {
  description = "Project tag value."
  type        = string
}

variable "cost_center_tag" {
  description = "CostCenter tag value."
  type        = string
}

variable "cluster_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.30"
}
