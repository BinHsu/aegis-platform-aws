# Grafana Cloud credentials stored in SSM Parameter Store under a single
# prefix `/aegis-platform-aws/grafana-cloud/`. The regional/ env's Alloy IRSA role is
# scoped to ssm:GetParameter on exactly this prefix (least privilege).
#
# Token + remote_write username are SecureString (KMS-encrypted at rest).
# Endpoint URLs are plain String (not secret).

resource "aws_ssm_parameter" "gc_api_token" {
  count       = var.enable_observability ? 1 : 0
  name        = "/aegis-platform-aws/grafana-cloud/api-token"
  description = "Grafana Cloud API token with admin scope on the aegis stack."
  type        = "SecureString"
  value       = var.grafana_cloud_api_token
}

resource "aws_ssm_parameter" "gc_mimir_username" {
  count       = var.enable_observability ? 1 : 0
  name        = "/aegis-platform-aws/grafana-cloud/mimir-username"
  description = "Mimir remote_write username (GC Prometheus instance ID)."
  type        = "SecureString"
  value       = var.grafana_cloud_mimir_username
}

resource "aws_ssm_parameter" "gc_loki_username" {
  count       = var.enable_observability ? 1 : 0
  name        = "/aegis-platform-aws/grafana-cloud/loki-username"
  description = "Loki push username (GC Loki instance ID)."
  type        = "SecureString"
  value       = var.grafana_cloud_loki_username
}

resource "aws_ssm_parameter" "gc_tempo_username" {
  count       = var.enable_observability ? 1 : 0
  name        = "/aegis-platform-aws/grafana-cloud/tempo-username"
  description = "Tempo OTLP username (GC Tempo instance ID)."
  type        = "SecureString"
  value       = var.grafana_cloud_tempo_username
}

resource "aws_ssm_parameter" "gc_pyroscope_username" {
  count       = var.enable_observability ? 1 : 0
  name        = "/aegis-platform-aws/grafana-cloud/pyroscope-username"
  description = "Pyroscope username (GC Pyroscope instance ID)."
  type        = "SecureString"
  value       = var.grafana_cloud_pyroscope_username
}

resource "aws_ssm_parameter" "gc_mimir_url" {
  count       = var.enable_observability ? 1 : 0
  name        = "/aegis-platform-aws/grafana-cloud/mimir-url"
  description = "Mimir remote_write endpoint."
  type        = "String"
  value       = var.grafana_cloud_mimir_url
}

resource "aws_ssm_parameter" "gc_loki_url" {
  count       = var.enable_observability ? 1 : 0
  name        = "/aegis-platform-aws/grafana-cloud/loki-url"
  description = "Loki push endpoint."
  type        = "String"
  value       = var.grafana_cloud_loki_url
}

resource "aws_ssm_parameter" "gc_tempo_url" {
  count       = var.enable_observability ? 1 : 0
  name        = "/aegis-platform-aws/grafana-cloud/tempo-url"
  description = "Tempo OTLP endpoint."
  type        = "String"
  value       = var.grafana_cloud_tempo_url
}

resource "aws_ssm_parameter" "gc_pyroscope_url" {
  count       = var.enable_observability ? 1 : 0
  name        = "/aegis-platform-aws/grafana-cloud/pyroscope-url"
  description = "Pyroscope ingest endpoint."
  type        = "String"
  value       = var.grafana_cloud_pyroscope_url
}
