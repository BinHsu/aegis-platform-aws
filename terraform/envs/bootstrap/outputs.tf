output "bucket_name" {
  description = "S3 bucket holding remote Terraform state for platform/ and regional/ envs."
  value       = aws_s3_bucket.tfstate.id
}

output "region" {
  description = "AWS region of the state backend bucket."
  value       = var.platform_region
}

# Convenience output: the literal backend.hcl content that downstream envs
# pass via `terraform init -backend-config=...`. The Makefile reads this and
# writes ./backend.hcl in the repo root (gitignored — derived value).
# No `dynamodb_table` — native S3 locking via `use_lockfile = true` (set in
# each downstream backend block, TF ≥ 1.11).
output "backend_hcl" {
  description = "backend.hcl content for downstream envs (Makefile-consumed)."
  value       = <<-EOT
    bucket  = "${aws_s3_bucket.tfstate.id}"
    region  = "${var.platform_region}"
    encrypt = true
  EOT
}

# ---- CI IAM seed (ADR-13) --------------------------------------------------
# The four CI role ARNs now live in this bootstrap (local) state. envs/platform
# re-exports them (via data.aws_iam_role lookups) so the downstream regional
# env keeps reading them from the platform remote state — its cluster-access
# roster contract is unchanged. These outputs let the seed env emit the ARNs
# the operator needs to confirm after a day-zero apply.
output "greeter_ci_role_arn" {
  description = "IAM role ARN assumed by aegis-greeter CI for ECR push (GitHub OIDC)."
  value       = aws_iam_role.greeter_ci.arn
}

output "infra_ci_role_arn" {
  description = "IAM role ARN assumed by aegis-platform-aws CI for read-only AWS (terraform plan on any branch / PR). Scoped to ReadOnlyAccess."
  value       = aws_iam_role.infra_ci.arn
}

output "infra_apply_role_arn" {
  description = "IAM role ARN assumed by aegis-platform-aws CI for terraform apply. Trust scoped to refs/heads/main + apply environments. Set as AWS_INFRA_APPLY_ROLE_ARN repo secret."
  value       = aws_iam_role.infra_apply.arn
}

output "infra_destroy_role_arn" {
  description = "ARN of gh-tf-destroy-platform — assumed by infra-ops destroy-platform / destroy-region. Set as the AWS_DESTROY_ROLE_ARN repo secret (or derived from account_id)."
  value       = aws_iam_role.infra_destroy.arn
}

output "core_ci_role_arn" {
  description = "IAM role ARN assumed by aegis-core CI for ECR push (GitHub OIDC). Set as the ECR_PUSH_ROLE_ARN secret / variable in aegis-core."
  value       = aws_iam_role.core_ci.arn
}

output "core_frontend_role_arn" {
  description = "IAM role ARN assumed by aegis-core CI for S3 frontend sync + CloudFront invalidation (GitHub OIDC). Set as the FRONTEND_PUSH_ROLE_ARN in aegis-core."
  value       = aws_iam_role.core_frontend.arn
}
