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
  vpc_cidr      = var.vpc_cidr
  node_instance = var.node_instance
  node_min      = var.node_min
  node_max      = var.node_max

  scm_token           = var.github_token
  workload_registries = var.workload_registries

  ci_role_arn            = data.terraform_remote_state.platform.outputs.infra_ci_role_arn
  apply_role_arn         = data.terraform_remote_state.platform.outputs.infra_apply_role_arn
  operator_principal_arn = var.operator_principal_arn

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

# Route 53 records: handled by external-dns, installed inside each
# cluster's regional-stack module (external-dns.tf). external-dns watches
# Ingresses with the `external-dns.alpha.kubernetes.io/hostname` annotation
# and reconciles the Route 53 record set under the platform-owned zone.
# Pattern X data flow stays clean: which regions get records = which
# clusters exist = which regions are enabled in regions.auto.tfvars.json.
