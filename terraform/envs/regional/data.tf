# Read platform/ env's remote state to discover the zone, ECR, OIDC role
# ARNs, SSM paths, and ALB-logs bucket.
#
# The bucket + region values are not derivable from data sources here —
# terraform_remote_state config is evaluated at `terraform init` time, before
# any provider is configured. Makefile exports `TF_VAR_tfstate_bucket` and
# `TF_VAR_tfstate_region` (read from bootstrap's outputs) so these are known
# from env, no hardcoded value in source.
data "terraform_remote_state" "platform" {
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "platform/terraform.tfstate"
    region = var.tfstate_region
  }
}

# Grafana Cloud creds — read via the aliased platform-region AWS provider
# (SSM parameters live in the platform region, this regional apply may be
# elsewhere).
data "aws_ssm_parameter" "gc_api_token" {
  provider = aws.platform
  name     = data.terraform_remote_state.platform.outputs.grafana_cloud_ssm_paths.api_token
}

data "aws_ssm_parameter" "gc_mimir_url" {
  provider = aws.platform
  name     = data.terraform_remote_state.platform.outputs.grafana_cloud_ssm_paths.mimir_url
}

data "aws_ssm_parameter" "gc_mimir_username" {
  provider = aws.platform
  name     = data.terraform_remote_state.platform.outputs.grafana_cloud_ssm_paths.mimir_username
}

data "aws_ssm_parameter" "gc_loki_url" {
  provider = aws.platform
  name     = data.terraform_remote_state.platform.outputs.grafana_cloud_ssm_paths.loki_url
}

data "aws_ssm_parameter" "gc_loki_username" {
  provider = aws.platform
  name     = data.terraform_remote_state.platform.outputs.grafana_cloud_ssm_paths.loki_username
}

data "aws_ssm_parameter" "gc_tempo_url" {
  provider = aws.platform
  name     = data.terraform_remote_state.platform.outputs.grafana_cloud_ssm_paths.tempo_url
}

data "aws_ssm_parameter" "gc_tempo_username" {
  provider = aws.platform
  name     = data.terraform_remote_state.platform.outputs.grafana_cloud_ssm_paths.tempo_username
}

data "aws_ssm_parameter" "gc_pyroscope_url" {
  provider = aws.platform
  name     = data.terraform_remote_state.platform.outputs.grafana_cloud_ssm_paths.pyroscope_url
}

data "aws_ssm_parameter" "gc_pyroscope_username" {
  provider = aws.platform
  name     = data.terraform_remote_state.platform.outputs.grafana_cloud_ssm_paths.pyroscope_username
}
