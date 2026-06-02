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
  description = "IAM role ARN assumed by aegis-platform-aws CI for read-only AWS (terraform plan on any branch / PR). Scoped to ReadOnlyAccess."
  value       = aws_iam_role.infra_ci.arn
}

output "infra_apply_role_arn" {
  description = "IAM role ARN assumed by aegis-platform-aws CI for terraform apply. Trust scoped to refs/heads/main only — PRs cannot assume this role. Permissions: AdministratorAccess (least-privilege scoping is tradeoffs work)."
  value       = aws_iam_role.infra_apply.arn
}

output "grafana_cloud_ssm_paths" {
  description = "SSM Parameter Store paths holding Grafana Cloud creds. regional/ env reads these via data.aws_ssm_parameter. When enable_observability=false the gc_* parameters are not created (count=0), so the fields resolve to empty strings — regional/ checks its own enable_observability and skips the SSM lookups, so it never dereferences an empty path."
  value = var.enable_observability ? {
    api_token          = aws_ssm_parameter.gc_api_token[0].name
    mimir_url          = aws_ssm_parameter.gc_mimir_url[0].name
    mimir_username     = aws_ssm_parameter.gc_mimir_username[0].name
    loki_url           = aws_ssm_parameter.gc_loki_url[0].name
    loki_username      = aws_ssm_parameter.gc_loki_username[0].name
    tempo_url          = aws_ssm_parameter.gc_tempo_url[0].name
    tempo_username     = aws_ssm_parameter.gc_tempo_username[0].name
    pyroscope_url      = aws_ssm_parameter.gc_pyroscope_url[0].name
    pyroscope_username = aws_ssm_parameter.gc_pyroscope_username[0].name
    } : {
    api_token          = ""
    mimir_url          = ""
    mimir_username     = ""
    loki_url           = ""
    loki_username      = ""
    tempo_url          = ""
    tempo_username     = ""
    pyroscope_url      = ""
    pyroscope_username = ""
  }
}

output "alb_access_logs_bucket" {
  description = "S3 bucket where ALBs write per-request access logs."
  value       = aws_s3_bucket.alb_access_logs.id
}

output "public_dashboard_urls" {
  description = "Read-only public share URLs for Grafana dashboards (linked from README for reviewer). Null when enable_observability=false (no public dashboard exists)."
  value = {
    greeter_overview = var.enable_observability ? "${var.grafana_cloud_url}/public-dashboards/${grafana_dashboard_public.greeter_overview[0].access_token}" : null
  }
}
