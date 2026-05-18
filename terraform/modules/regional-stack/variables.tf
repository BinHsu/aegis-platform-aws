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

variable "workloads" {
  description = "Workloads ArgoCD reconciles into this cluster, keyed by Application name. Each entry names a deploy repo (one read-only deploy key registered per region) plus optional region-injection knobs. See workloads.auto.tfvars.json."
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

variable "ci_role_arn" {
  description = "ARN of the aegis-stateless-ci IAM role (CI plan). Gets an EKS ClusterAdmin access entry so `terraform plan` from CI can read Helm/k8s state."
  type        = string
}

variable "apply_role_arn" {
  description = "ARN of the aegis-stateless-apply IAM role (CI apply). Gets an EKS ClusterAdmin access entry so `terraform apply` from CI can manage Helm/k8s resources."
  type        = string
}

variable "operator_principal_arn" {
  description = "ARN of the human operator's IAM principal. Gets an explicit EKS ClusterAdmin access entry so operator cluster access is declarative + survives a cluster recreate by any principal (the implicit creator grant does not — see eks.tf)."
  type        = string
}

# ---- Grafana Cloud creds (sensitive) -------------------------------------
variable "gc_api_token" {
  description = "Grafana Cloud API token (admin on the aegis stack). Embedded in a K8s Secret used by Alloy."
  type        = string
  sensitive   = true
}

variable "gc_mimir_url" {
  description = "Mimir remote_write endpoint."
  type        = string
  sensitive   = true
}

variable "gc_mimir_username" {
  description = "Mimir remote_write username (GC Prometheus instance ID)."
  type        = string
  sensitive   = true
}

variable "gc_loki_url" {
  description = "Loki push endpoint."
  type        = string
  sensitive   = true
}

variable "gc_loki_username" {
  description = "Loki push username (GC Loki instance ID)."
  type        = string
  sensitive   = true
}

variable "gc_tempo_url" {
  description = "Tempo OTLP endpoint."
  type        = string
  sensitive   = true
}

variable "gc_tempo_username" {
  description = "Tempo OTLP username (GC Tempo instance ID)."
  type        = string
  sensitive   = true
}

variable "gc_pyroscope_url" {
  description = "Pyroscope ingest endpoint."
  type        = string
  sensitive   = true
}

variable "gc_pyroscope_username" {
  description = "Pyroscope username (GC Pyroscope instance ID)."
  type        = string
  sensitive   = true
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
