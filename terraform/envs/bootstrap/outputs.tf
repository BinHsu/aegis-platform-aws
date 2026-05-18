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
