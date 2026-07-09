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

variable "node_instance_types" {
  # #183: a single instance type means a Spot capacity-pool reclamation can
  # take the WHOLE Spot node group down at once (one pool, one interruption
  # wave). Listing >=2 families spreads the EKS module's EC2 Fleet allocation
  # across independent Spot pools, so one pool's reclamation leaves the others
  # standing. Callers pick sizes with matching vCPU/memory so pod scheduling
  # is not surprised by which type actually launched.
  description = "EC2 instance types for the Spot managed node group, in preference order. List >=2 for Spot capacity-pool diversification (single-type Spot is a reclaim-the-whole-group anti-pattern)."
  type        = list(string)
  default     = ["t4g.medium"]

  validation {
    condition     = length(var.node_instance_types) >= 1
    error_message = "node_instance_types must list at least one instance type."
  }
}

variable "node_min" {
  description = "Minimum node count for the managed (Spot) node group."
  type        = number
}

variable "node_max" {
  # NOTE (ADR-27 / #182): with Karpenter installed (karpenter.tf), the MNG is the
  # STATIC BASE that hosts the Karpenter controller + system add-ons; elastic
  # scaling flows through the Karpenter NodePool, not this ASG ceiling. node_max
  # is therefore no longer the live scale knob — the Karpenter NodePool's
  # limits.cpu (var.karpenter_cpu_limit) is. node_max is retained here because
  # ADR-27 stages the MNG capacity cleanup (setting max_size = node_min, removing
  # node_max) as a follow-up gated on Karpenter being verified on staging; it is
  # still consumed by eks.tf until then (this PR does not re-shape the base).
  description = "Maximum node count for the managed (Spot) node group. NOTE: with Karpenter (ADR-27) this bounds the static base only; elastic scaling uses the Karpenter NodePool. Cleanup to max_size=node_min is a staged follow-up."
  type        = number
}

variable "node_ondemand_baseline" {
  # #183: all-Spot has no floor — a single reclamation wave can take the
  # entire node group to zero at once. A small On-Demand node group alongside
  # the Spot one gives prod a capacity floor that Spot interruption cannot
  # touch. 0 = no baseline (the module then creates only the Spot group);
  # this is the correct default for cost-sensitive envs (e.g. staging) that
  # accept all-Spot risk.
  description = "Size (min=max=desired) of a dedicated On-Demand node group that runs alongside the Spot group. 0 disables it — no On-Demand baseline is created."
  type        = number
  default     = 0

  validation {
    condition     = var.node_ondemand_baseline >= 0
    error_message = "node_ondemand_baseline must be >= 0."
  }
}

# ---- ADR-27 / #182: Karpenter node autoscaling ----------------------------
variable "enable_karpenter" {
  description = "Install Karpenter (controller + default NodePool/EC2NodeClass + IAM via Pod Identity + SQS interruption queue). ADR-27 chose Karpenter to close the #182 pending-pods-never-scale gap. Default on (ADR-27: 'install ... behind a variable (default on)'); set false to fall back to the fixed-capacity MNG-only posture (e.g. an ephemeral kind/CI cluster that never scales)."
  type        = bool
  default     = true
}

variable "karpenter_cpu_limit" {
  # The Karpenter NodePool spec.limits.cpu — the LIVE elastic-tier scale ceiling
  # (total vCPUs Karpenter may provision across all its nodes). This is the real
  # "max capacity" knob under ADR-27, replacing the MNG's dead node_max ceiling.
  # A cost ceiling is this cluster's real constraint (ADR-27), so a bounded
  # default is deliberate; raise it per environment when workloads grow.
  description = "Karpenter NodePool scale ceiling, in total vCPUs (spec.limits.cpu). Bounds elastic spend; the live replacement for the MNG's node_max under ADR-27."
  type        = number
  default     = 100

  validation {
    condition     = var.karpenter_cpu_limit > 0
    error_message = "karpenter_cpu_limit must be > 0 (total vCPUs the Karpenter NodePool may provision)."
  }
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

# ---- GitOps facts bridge --------------------------------------------------
variable "gitops_revision" {
  description = "Git revision the app-of-apps root Application tracks (threaded over root-app.yaml's spec by gitops-bootstrap.tf, per the A2 stub's TODO). Default main = production. Point at a feature branch only for a pre-merge validation cluster."
  type        = string
  default     = "main"
}

variable "cluster_profile" {
  description = "Cluster lifecycle profile, surfaced as the aegis.binhsu.org/profile annotation on the in-cluster ArgoCD `cluster` Secret (facts bridge, ADR-25 / gitops-bootstrap.tf). ephemeral = CI/kind + throwaway EKS; full = long-lived. A6 will select add-on scope on this via an ApplicationSet selector; in A1 it is written as an inert fact. Default ephemeral (safe); the regional env can override."
  type        = string
  default     = "ephemeral"

  validation {
    condition     = contains(["ephemeral", "full"], var.cluster_profile)
    error_message = "cluster_profile must be one of: ephemeral, full."
  }
}

# ---- observability toggle -------------------------------------------------
variable "enable_observability" {
  description = "Whether to deploy the Grafana Alloy observability stack. Alloy + node-exporter + kube-state-metrics are now GitOps-owned (gitops/platform-addons/addons/alloy/); this toggle gates the Terraform-owned CREDS BRIDGE in gitops-bootstrap.tf — the monitoring namespace and the grafana-cloud-credentials Secret. Default FALSE (the regional env passes this explicitly; the default just makes a bare module observability-free). Set true to write the GC creds Secret — the gc_* vars are then required."
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
# var.require_digest_action was REMOVED in A2 (#174). Its only consumer was
# helm_release.aegis_policies (kyverno.tf), which moved to GitOps. The Audit /
# Enforce posture now lives in git — gitops/platform-addons/addons/aegis-policies/
# application.yaml (helm.values.requireDigestAction, default Audit). The B1 E2E
# harness still overrides it to Enforce at render time (epic decision #8).
# A1 (#173) may re-introduce a per-cluster override THROUGH the cluster-facts
# bridge if variance is ever needed; today the git default is uniform.
