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
  node_instance = var.node_instance
  node_min      = var.node_min
  node_max      = var.node_max

  scm_token = var.github_token

  # WS3-R: override ecr_region to THIS apply's region so the ApplicationSet
  # injects the local-region ECR endpoint (nodes pull from the in-region
  # replica, not cross-region). The static registries.auto.tfvars.json stays
  # platform-neutral; the per-region value comes from var.region here. cert_arn
  # is left unset → the module's per-region cert is used (argocd.tf certArn).
  workload_registries = {
    for repo, cfg in var.workload_registries : repo => merge(cfg, {
      ecr_region = var.region
    })
  }

  # WS3-R: platform outputs for zero-touch ConfigMap injection (Cognito
  # issuer/audience/jwks). try() keeps a regional PLAN against stale platform
  # state from hard-failing before those outputs exist (same pattern as
  # infra_destroy above). This does NOT silently ship empty config: the
  # ApplicationSet ConfigMap patch is gated on the value being non-empty
  # (argocd.tf), so an empty value SKIPS injection and the deploy ConfigMap keeps
  # its loud REPLACE_WITH_* placeholder rather than a blank. At real apply the
  # values are present — apply-platform runs before apply-regional (CI needs:).
  #
  # ADR-05 dual-region: the model bucket is NO LONGER threaded from platform.
  # The regional-stack module provisions a PER-REGION bucket (model-store.tf) and
  # injects its own name + read policy, so each region's engine reads its
  # in-region bucket. Cognito stays shared (one pool per account, platform_region).
  cognito_issuer   = try(data.terraform_remote_state.platform.outputs.cognito_issuer, "")
  cognito_audience = try(data.terraform_remote_state.platform.outputs.cognito_app_client_id, "")
  cognito_jwks_url = try(data.terraform_remote_state.platform.outputs.cognito_jwks_url, "")

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
  # All four platform-output reads use try(): the pre-apply version-cost gate
  # plans this regional stack to read the EKS version BEFORE apply-platform runs,
  # so on a cold start (empty platform state, zero outputs) a bare reference
  # hard-fails the gate plan ("object has no attribute"). The real apply flow
  # (apply-platform -> apply-regional in one run) always sees a populated state,
  # so the fallbacks (null = entry filtered by the module; "" = empty zone) only
  # ever apply to the throwaway gate plan, never to a cluster that gets created.
  # Same pattern and rationale as cognito_* above and infra_destroy here.
  cluster_admin_principals = {
    operator      = var.operator_principal_arn
    infra_ci      = try(data.terraform_remote_state.platform.outputs.infra_ci_role_arn, null)
    infra_apply   = try(data.terraform_remote_state.platform.outputs.infra_apply_role_arn, null)
    infra_destroy = try(data.terraform_remote_state.platform.outputs.infra_destroy_role_arn, null)
  }

  # Both zone fallbacks are SYNTACTICALLY-VALID placeholders, not "" — the
  # regional-stack ACM resources validate their shape at PLAN time, so empty
  # values fail the pre-apply version gate on a cold start:
  #   - aws_route53_record.acm_validation rejects an empty zone_id
  #     ("zone_id must not be empty"), so zone_id needs a non-empty Z-id shape.
  #   - aws_acm_certificate builds SAN = ["*.${zone_name}"] and rejects a SAN
  #     ending in "." (empty zone_name -> "*."), so zone_name needs a real domain.
  # example.com is RFC 2606 reserved (never a real zone). At real apply the
  # platform outputs are present, so these placeholders only ever feed the
  # throwaway gate plan, never a created cert/record.
  zone_id   = try(data.terraform_remote_state.platform.outputs.zone_id, "Z0PLACEHOLDERGATEPLAN")
  zone_name = try(data.terraform_remote_state.platform.outputs.zone_name, "placeholder.example.com")

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
