# Single module instance — one per regional apply. Makefile/CI iterates
# over enabled regions in regions.auto.tfvars.json, invoking this env
# once per region with that region's scalars.

module "stack" {
  source = "../../modules/regional-stack"

  providers = {
    aws        = aws
    kubernetes = kubernetes
    helm       = helm
  }

  region        = var.region
  environment   = var.environment
  vpc_cidr      = var.vpc_cidr
  node_instance = var.node_instance
  node_min      = var.node_min
  node_max      = var.node_max

  scm_token           = var.github_token
  workload_registries = var.workload_registries

  # One map = the full cluster-access roster (each entry becomes an EKS
  # ClusterAdmin access entry in the module). The destroy role MUST be here:
  # a terraform destroy that can delete AWS resources but not helm_release
  # (K8s Unauthorized) strands a billing cluster (2026-06-06 incident shape).
  #
  # infra_destroy uses try(): the output lands in the platform STATE only on
  # the next platform apply, so a regional plan against a pre-existing state
  # would otherwise hard-fail ("object does not have an attribute"). null =
  # entry omitted (module filters it); check.destroy_role_in_platform_state
  # below makes the omission loud. The real apply flow (apply-platform →
  # apply-regional in one run) always sees a fresh state, so the entry is
  # present whenever a cluster is actually created.
  cluster_admin_principals = {
    operator      = var.operator_principal_arn
    infra_ci      = data.terraform_remote_state.platform.outputs.infra_ci_role_arn
    infra_apply   = data.terraform_remote_state.platform.outputs.infra_apply_role_arn
    infra_destroy = try(data.terraform_remote_state.platform.outputs.infra_destroy_role_arn, null)
  }

  zone_id   = data.terraform_remote_state.platform.outputs.zone_id
  zone_name = data.terraform_remote_state.platform.outputs.zone_name

  # Observability toggle — when false the gc_* SSM data lookups are count=0,
  # so we pass "" and the module skips Alloy + its credential Secret.
  enable_observability  = var.enable_observability
  gc_api_token          = var.enable_observability ? data.aws_ssm_parameter.gc_api_token[0].value : ""
  gc_mimir_url          = var.enable_observability ? data.aws_ssm_parameter.gc_mimir_url[0].value : ""
  gc_mimir_username     = var.enable_observability ? data.aws_ssm_parameter.gc_mimir_username[0].value : ""
  gc_loki_url           = var.enable_observability ? data.aws_ssm_parameter.gc_loki_url[0].value : ""
  gc_loki_username      = var.enable_observability ? data.aws_ssm_parameter.gc_loki_username[0].value : ""
  gc_tempo_url          = var.enable_observability ? data.aws_ssm_parameter.gc_tempo_url[0].value : ""
  gc_tempo_username     = var.enable_observability ? data.aws_ssm_parameter.gc_tempo_username[0].value : ""
  gc_pyroscope_url      = var.enable_observability ? data.aws_ssm_parameter.gc_pyroscope_url[0].value : ""
  gc_pyroscope_username = var.enable_observability ? data.aws_ssm_parameter.gc_pyroscope_username[0].value : ""

  project_tag     = var.project_tag
  cost_center_tag = var.cost_center_tag
}

# Plan-time tripwire for the try() above: warns (does not fail) when the
# platform state predates the infra_destroy_role_arn output. A cluster
# applied in that window would have NO destroy-role access entry — exactly
# the strands-a-billing-cluster gap the roster exists to close. Re-apply
# the platform env first; the unified flow does this ordering already.
check "destroy_role_in_platform_state" {
  assert {
    condition     = can(data.terraform_remote_state.platform.outputs.infra_destroy_role_arn)
    error_message = "Platform state has no infra_destroy_role_arn output (stale state from before the destroy-role change). The infra_destroy access entry will be OMITTED from this plan. Apply the platform env first, then re-plan/apply regional."
  }
}

# Route 53 records: handled by external-dns, installed inside each
# cluster's regional-stack module (external-dns.tf). external-dns watches
# Ingresses with the `external-dns.alpha.kubernetes.io/hostname` annotation
# and reconciles the Route 53 record set under the platform-owned zone.
# Pattern X data flow stays clean: which regions get records = which
# clusters exist = which regions are enabled in regions.auto.tfvars.json.
