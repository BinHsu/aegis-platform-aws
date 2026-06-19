variable "region" {
  description = "AWS region this stack instance runs in. Used in resource names, IRSA-trusted role names, ArgoCD deploy-key title, alloy resource prefix."
  type        = string
}

variable "github_owner" {
  description = "GitHub user or org that owns the deploy repos. Used to build each workload's repoURL in the ApplicationSet template and the AppProject sourceRepos allowlist. Default BinHsu. The github SCM-provider generator uses the ORG API (/orgs/<owner>/repos), which 404s for a personal account; workloads are therefore enumerated from the registries-backed List generator — this var wires the repoURL correctly for either account type."
  type        = string
  default     = "BinHsu"
}

# NOTE (WS4 / ADR-23): var.vpc_cidr is gone. The VPC CIDR is no longer an input
# — it is allocated from the landing-zone IPAM pool resolved by locale
# (vpc-ipam.tf). IPAM is the single allocator, so there is no per-region CIDR to
# pass in. The subnets in locals.tf derive from the allocation.
variable "environment" {
  description = "Which deploy-repo overlay this cluster syncs: ArgoCD's ApplicationSet uses k8s/overlays/<environment> as both the discovery gate (pathsExist) and the sync path. Default prod (the original single-environment behavior); the W3 callers pass TF_VAR_environment from accounts.json."
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["staging", "prod"], var.environment)
    error_message = "environment must be one of: staging, prod."
  }
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
    # engine_irsa is now consumed ONLY for its service_account, which gates the
    # per-engine ConfigMap injections in argocd.tf (model-store, gateway-oidc).
    # The engine's IAM role is no longer composed via Crossplane WorkloadIdentity:
    # ADR-21 §A moved it to a Terraform-owned EKS Pod Identity association
    # (pod-identity-engine.tf), which uses a fixed role name (aegis-core-engine-
    # <region>) and attaches the model-read policy directly. role_name and
    # policy_arns are therefore VESTIGIAL — kept so the gitignored
    # registries.auto.tfvars.json still parses; a follow-up may drop them.
    engine_irsa = optional(object({
      service_account = string
      role_name       = string                 # vestigial (see above) — Pod Identity names the role
      policy_arns     = optional(list(string)) # vestigial — model-read attached in pod-identity-engine.tf
    }))
    # Account-bound (account ID in the ARN) → injected, kept out of the public
    # deploy repo. The cert is per-(workload,region); a single value here is
    # correct for one region — multi-region wants a per-region lookup (E2E
    # PENDING refinement). The deploy repo drops its hardcoded cert-arn.
    ingress_cert = optional(object({
      ingress_name = string
      # Optional override (WS3-R): omit to use the per-region module cert
      # (acm.tf), which is region-correct by construction. Pin only to bring a
      # workload's own cert.
      cert_arn = optional(string)
    }))
  }))
  default = {}
}

# ── WS3-R: platform outputs threaded in for zero-touch ConfigMap injection ──
# The ApplicationSet fills the aws-binding gateway-oidc ConfigMap from these
# (argocd.tf templatePatch), so a forker never hand-patches them. Per-account
# values (region-agnostic for JWT validation). Empty default = no injection (the
# placeholder stays).
#
# The model bucket is NOT here — ADR-05 made it PER-REGION (model-store.tf, this
# module), so the module owns the name + read policy and injects them directly;
# there is no cross-env input to thread.
variable "cognito_issuer" {
  description = "Cognito OIDC issuer URL (platform cognito.tf output). Injected into the gateway-oidc ConfigMap."
  type        = string
  default     = ""
}

variable "cognito_audience" {
  description = "Cognito SPA app-client id = the gateway JWT audience (platform output)."
  type        = string
  default     = ""
}

variable "cognito_jwks_url" {
  description = "Cognito JWKS URL (platform output) for the gateway OIDCProvider."
  type        = string
  default     = ""
}

variable "scm_token" {
  description = "GitHub org-read token the ArgoCD SCM-provider generator uses to enumerate aegis-workload-tagged repos. Replaces the per-workload deploy keys (deploy repos are public → anonymous clone). Needs read:org + repo metadata, NOT admin:public_key."
  type        = string
  sensitive   = true
}

# Single source of truth for cluster access: every key becomes an EKS
# access entry with ClusterAdmin (eks.tf iterates this map). Expected keys
# (the regional env wires them; keys are stable — they name the access-entry
# resources, so renaming a key recreates its entry):
#   operator      — the human operator's IAM principal. Explicit so operator
#                   access is declarative + survives a cluster recreate by
#                   any principal (the implicit creator grant does not).
#   infra_ci      — aegis-platform-aws-ci (CI plan): `terraform plan` reads
#                   Helm/k8s state.
#   infra_apply   — gh-tf-apply-platform (CI apply): `terraform apply`
#                   manages Helm/k8s resources.
#   infra_destroy — gh-tf-destroy-platform (CI destroy): `terraform destroy`
#                   must delete helm_release resources; without this entry it
#                   gets K8s Unauthorized and strands a billing cluster
#                   (2026-06-06 incident shape).
variable "cluster_admin_principals" {
  description = "IAM principal ARNs that get an EKS ClusterAdmin access entry, keyed by a stable entry name (operator / infra_ci / infra_apply / infra_destroy). Declared as one map so role-to-access-entry pairing lives in one place — a CI role that can reach the cluster API but is missing here fails every helm/k8s operation with Unauthorized."
  type        = map(string)
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
  # Explicit, human-bumped pin (NOT auto-latest — see eks-version-guard.tf).
  # The guard warns when this ages out of standard support ($0.50/hr extended-
  # support penalty). On a long-lived cluster a bump is a control-plane upgrade:
  # verify addon compatibility (kyverno/argocd/ACK/crossplane/alb-controller) +
  # scan deprecated APIs (kubent/pluto) first. Was "1.30" (standard support
  # ended 2025-07-23 — the incident default).
  description = "EKS Kubernetes version (explicit pin; guarded by eks-version-guard.tf)."
  type        = string
  default     = "1.35"
}

# ---- ADR-10: require-digest admission policy ------------------------------
variable "require_digest_action" {
  description = "Kyverno validationFailureAction for the ADR-10 require-image-digest ClusterPolicy. \"Audit\" (default) logs tag-only images in workload namespaces but admits them, so landing the policy cannot wedge a workload that has not yet migrated to digest pinning. Flip to \"Enforce\" only AFTER the deploy repos pin @sha256 (ADR-10 phase 3) and an Audit run shows zero violations."
  type        = string
  default     = "Audit"

  validation {
    condition     = contains(["Audit", "Enforce"], var.require_digest_action)
    error_message = "require_digest_action must be \"Audit\" or \"Enforce\"."
  }
}
