output "zone_id" {
  description = "Route 53 hosted zone ID (consumed by regional/ for A-alias records)."
  value       = aws_route53_zone.main.zone_id
}

output "zone_name" {
  description = "Route 53 hosted zone name."
  value       = aws_route53_zone.main.name
}

output "zone_name_servers" {
  description = "AWS-assigned authoritative name servers for the zone (for `dig @<ns>` demo)."
  value       = aws_route53_zone.main.name_servers
}

output "ecr_repository_url" {
  description = "Full ECR repo URL — set as aegis-greeter repo variable ECR_REPO_URL. Form: <account>.dkr.ecr.<region>.amazonaws.com/aegis-greeter."
  value       = aws_ecr_repository.greeter.repository_url
}

output "ecr_registry" {
  description = "ECR registry host (URL minus the /<repo> path) — set as aegis-greeter repo variable ECR_REGISTRY. Form: <account>.dkr.ecr.<region>.amazonaws.com."
  value       = split("/", aws_ecr_repository.greeter.repository_url)[0]
}

output "ecr_repository_arn" {
  description = "ECR repo ARN (referenced by aegis-greeter CI IAM role)."
  value       = aws_ecr_repository.greeter.arn
}

output "aws_region" {
  description = "Platform region — set as aegis-greeter repo variable AWS_REGION (publish.yml configure-aws-credentials region)."
  value       = var.platform_region
}

output "greeter_ci_role_arn" {
  description = "IAM role ARN assumed by aegis-greeter CI for ECR push (via GitHub OIDC)."
  value       = aws_iam_role.greeter_ci.arn
}

output "infra_ci_role_arn" {
  description = "IAM role ARN assumed by aegis-stateless CI for read-only AWS (terraform plan on any branch / PR). Scoped to ReadOnlyAccess."
  value       = aws_iam_role.infra_ci.arn
}

output "infra_apply_role_arn" {
  description = "IAM role ARN assumed by aegis-stateless CI for terraform apply. Trust scoped to refs/heads/main only — PRs cannot assume this role. Permissions: AdministratorAccess (least-privilege scoping is tradeoffs work)."
  value       = aws_iam_role.infra_apply.arn
}

output "grafana_cloud_ssm_paths" {
  description = "SSM Parameter Store paths holding Grafana Cloud creds. regional/ env reads these via data.aws_ssm_parameter."
  value = {
    api_token          = aws_ssm_parameter.gc_api_token.name
    mimir_url          = aws_ssm_parameter.gc_mimir_url.name
    mimir_username     = aws_ssm_parameter.gc_mimir_username.name
    loki_url           = aws_ssm_parameter.gc_loki_url.name
    loki_username      = aws_ssm_parameter.gc_loki_username.name
    tempo_url          = aws_ssm_parameter.gc_tempo_url.name
    tempo_username     = aws_ssm_parameter.gc_tempo_username.name
    pyroscope_url      = aws_ssm_parameter.gc_pyroscope_url.name
    pyroscope_username = aws_ssm_parameter.gc_pyroscope_username.name
  }
}

output "alb_access_logs_bucket" {
  description = "S3 bucket where ALBs write per-request access logs."
  value       = aws_s3_bucket.alb_access_logs.id
}

output "public_dashboard_urls" {
  description = "Read-only public share URLs for Grafana dashboards (linked from README for reviewer)."
  value = {
    greeter_overview = "${var.grafana_cloud_url}/public-dashboards/${grafana_dashboard_public.greeter_overview.access_token}"
  }
}
