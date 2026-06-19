# ---- Pattern X: regions (read from repo-root regions.auto.tfvars.json) ----
variable "regions" {
  description = "Multi-region topology — single source of truth at repo-root regions.auto.tfvars.json. Platform reads it for ECR replication targeting (only enabled entries are real destinations)."
  # NOTE (WS4 / ADR-23): `cidr` is gone — the regional VPC CIDR is now allocated
  # from the landing-zone IPAM pool (modules/regional-stack/vpc-ipam.tf), not
  # carried in regions.auto.tfvars.json. Platform only consumes `enabled` + the
  # region keys for ECR replication, so the schema drops the unused field.
  type = map(object({
    enabled       = bool
    node_instance = string
    node_min      = number
    node_max      = number
  }))
}

# ---- platform basics -------------------------------------------------------
variable "platform_region" {
  description = "AWS region where this platform env applies provider operations. Route 53 is global; ECR + S3 etc. live in this region as their 'source' region. Sourced from regions.auto.tfvars.json top-level (single source of truth)."
  type        = string
}

variable "dns_zone_name" {
  description = "DNS parent under which each env gets its own Route 53 hosted zone. WS3-R: `aws.binhsu.org` — the binhsu.org apex stays on Cloudflare (personal homepage); we delegate per-env subdomains to AWS. The actual zone name is `<env>.<dns_zone_name>` (route53.tf), e.g. prod.aws.binhsu.org / staging.aws.binhsu.org, each delegated directly from Cloudflare. A forker overrides this with their own (sub)domain."
  type        = string
  default     = "aws.binhsu.org"
}

variable "environment" {
  description = "Account environment selector (staging / prod), supplied via TF_VAR_environment from accounts.json. Drives per-env naming + the Route 53 subdomain split (prod = apex zone, non-prod = <env>.<apex> zone) so two accounts never both claim the same hosted-zone name."
  type        = string
  validation {
    # High-impact selector — a typo (e.g. "prd") would silently change zone
    # naming/delegation + Cognito host allow-lists. Pin the known set.
    condition     = contains(["staging", "prod"], var.environment)
    error_message = "environment must be \"staging\" or \"prod\"."
  }
}

variable "ecr_repository_name" {
  description = "Name of the ECR repo where aegis-greeter pushes container images."
  type        = string
  default     = "aegis-greeter"
}

# ---- ADR-10: shared release registry (dedicated aegis-deployment account) ---
variable "deployment_account_id" {
  description = "12-digit account id of the dedicated aegis-deployment account (Deployments OU) that holds the single shared ECR registry per ADR-10. The account was vended by the landing-zone account factory on 2026-06-10 (landing-zone ADR-018; the account display NAME is aegis-deploymentS, plural — cosmetic, all keys stay singular). Default \"\" keeps the entire shared-registry path (deployment-ecr.tf) count-gated OFF so the rest of the platform plans/applies on the current per-account topology. Set the real id only once the gh-tf-apply-deployment role + GitHub OIDC provider are seeded AND one owning apply context is chosen (W3 note in deployment-ecr.tf). In THIS repo the id is supplied from accounts.json (the org's account ids are deliberately public topology, ADR-11 — accounts.json already carries the cluster account ids); forks that treat their ids as private keep the default \"\" and supply via gitignored tfvars."
  type        = string
  default     = ""

  validation {
    # Either empty (gate off) OR a 12-digit AWS account id. Catches a typo'd id
    # at plan time instead of an opaque assume-role failure mid-apply.
    condition     = var.deployment_account_id == "" || can(regex("^[0-9]{12}$", var.deployment_account_id))
    error_message = "deployment_account_id must be \"\" (shared registry off) or a 12-digit AWS account id."
  }
}

variable "cluster_pull_account_ids" {
  description = "Account ids of the EKS cluster accounts that pull the shared image read-only via the cross-account ECR repository policy (ADR-10). aegis-staging + aegis-prod. These are existing cluster account ids (not secret in the same way a registry root-of-trust is, but kept as a var so the public template carries no real ids). Default [] is inert when deployment_account_id is unset."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.cluster_pull_account_ids : can(regex("^[0-9]{12}$", a))])
    error_message = "every cluster_pull_account_ids entry must be a 12-digit AWS account id."
  }
}

# ---- observability toggle --------------------------------------------------
variable "enable_observability" {
  description = "Whether to provision the Grafana Cloud observability stack (dashboards, alert rules, contact points, the grafana_data_source lookup, and the SSM parameters holding GC creds). Default FALSE so a fork WITHOUT a Grafana Cloud account deploys cleanly out of the box — every grafana_* resource + the gc_* SSM parameters are skipped (count = 0), and grafana_cloud_ssm_paths resolves to empty strings so regional/ skips the in-cluster Alloy collector too. Set true to opt in; then grafana_auth_token + grafana_cloud_api_token become REQUIRED (enforced by the precondition in observability-guard.tf — a clear plan-time error instead of an opaque grafana-provider 401 mid-apply). Keep in sync with the regional env's enable_observability."
  type        = bool
  default     = false
}

# ---- Grafana Cloud creds (sensitive; supplied via gitignored tfvars) -------
variable "grafana_cloud_url" {
  description = "Grafana Cloud stack URL (e.g. https://aegis.grafana.net). Used by the grafana TF provider."
  type        = string
  default     = "https://aegis.grafana.net"
}

variable "grafana_cloud_api_token" {
  description = "Grafana Cloud Access Policy token (glc_…) — used as the Alloy remote_write password for Mimir/Loki/Tempo/Pyroscope. NOT the grafana-provider auth (see grafana_auth_token). Supply via gitignored secrets.auto.tfvars. NEVER commit a value. Defaults to \"\" so a deploy with enable_observability=false needs no GC token."
  type        = string
  sensitive   = true
  default     = ""
}

variable "grafana_auth_token" {
  description = "Grafana instance service-account token (glsa_…) — auth for the `grafana` TF provider managing dashboards/folders/alert-rules on aegis.grafana.net. Distinct from grafana_cloud_api_token. Create via the instance: Administration → Users and access → Service accounts → Admin role → add token. NEVER commit a value. Defaults to \"\" so a deploy with enable_observability=false leaves the grafana provider configured-but-unused (no resources → no auth call)."
  type        = string
  sensitive   = true
  default     = ""
}

# Grafana Cloud uses a distinct instance-ID username per backend (Mimir,
# Loki, Tempo, Pyroscope each differ); only the API token is shared.
variable "grafana_cloud_mimir_username" {
  description = "Mimir remote_write username (GC Prometheus instance ID)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "grafana_cloud_loki_username" {
  description = "Loki push username (GC Loki instance ID)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "grafana_cloud_tempo_username" {
  description = "Tempo OTLP username (GC Tempo instance ID)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "grafana_cloud_pyroscope_username" {
  description = "Pyroscope username (GC Pyroscope instance ID)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "grafana_cloud_mimir_url" {
  description = "Mimir push URL (e.g. https://prometheus-prod-XX-prod-eu-west-2.grafana.net/api/prom/push)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "grafana_cloud_loki_url" {
  description = "Loki push URL (e.g. https://logs-prod-XXX.grafana.net/loki/api/v1/push)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "grafana_cloud_tempo_url" {
  description = "Tempo OTLP URL (e.g. https://tempo-prod-XX-prod-eu-west-2.grafana.net:443)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "grafana_cloud_pyroscope_url" {
  description = "Pyroscope ingest URL (e.g. https://profiles-prod-XXX.grafana.net)."
  type        = string
  sensitive   = true
  default     = ""
}

# ---- Budget alarm ----------------------------------------------------------
variable "budget_alert_email" {
  description = "Email to receive AWS Budget alarms. Supply via gitignored secrets.auto.tfvars. NEVER commit a value (per anonymization policy)."
  type        = string
  sensitive   = true
}

variable "budget_warn_amount_usd" {
  description = "Warning threshold (USD) — 80% of this triggers a notification."
  type        = number
  default     = 10
}

variable "budget_hard_amount_usd" {
  description = "Hard threshold (USD) — 100% of this triggers a notification."
  type        = number
  default     = 25
}

# ---- GitHub OIDC -----------------------------------------------------------
variable "github_owner" {
  description = "GitHub org/user that owns the aegis-greeter + aegis-platform-aws repos. Used for the github TF provider + OIDC trust policies."
  type        = string
  default     = "BinHsu"
}

variable "enable_branch_protection" {
  description = "Whether to create the github_branch_protection resource. GitHub requires Pro (or a public repo) for branch protection on a private repo — default false so a free private repo applies cleanly. Flip true once the repo is public or on Pro."
  type        = bool
  default     = false
}

# ---- CloudWatch data source (Tier B — out-of-band infra health) ------------
variable "enable_cloudwatch_datasource" {
  description = "Whether to create the Grafana CloudWatch data source + its cross-account IAM role. Default false — it needs a trust relationship to Grafana Cloud's AWS account, so the operator first supplies grafana_cloud_aws_account_id + grafana_cloud_external_id (both shown in the Grafana Cloud UI: Connections -> Add new connection -> CloudWatch -> set up via an IAM role), then flips this true. See docs/tradeoffs.md #4."
  type        = bool
  default     = false
}

variable "grafana_cloud_aws_account_id" {
  description = "AWS account ID of Grafana Cloud's CloudWatch integration — the principal the cross-account IAM role trusts. Read from the Grafana Cloud CloudWatch setup screen. Only consumed when enable_cloudwatch_datasource = true."
  type        = string
  default     = ""
}

variable "grafana_cloud_external_id" {
  description = "External ID Grafana Cloud presents when assuming the CloudWatch role — defeats the confused-deputy problem. Read from the Grafana Cloud CloudWatch setup screen. Only consumed when enable_cloudwatch_datasource = true."
  type        = string
  default     = ""
  sensitive   = true
}

variable "github_token" {
  description = "GitHub PAT for the github TF provider in THIS env (github_branch_protection on aegis-platform-aws). Needs repo admin scope. Note: the per-workload deploy keys are gone (ADR-07) — this token no longer needs admin:public_key, and regional/ takes its own org-read PAT directly, not via remote_state."
  type        = string
  sensitive   = true
}

# ---- tags ------------------------------------------------------------------
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
