output "region" {
  description = "Region this apply provisioned (echo of input — useful for CI matrix output collation)."
  value       = var.region
}

output "cluster_name" {
  description = "EKS cluster name for this region."
  value       = module.stack.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = module.stack.cluster_endpoint
  sensitive   = true
}

output "vpc_id" {
  description = "VPC ID for this region's stack."
  value       = module.stack.vpc_id
}

output "cluster_profile" {
  description = "Lifecycle profile this region was applied with (ephemeral|full). A6 (#178): infra-ops destroy-region reads `terraform output -raw cluster_profile` to select the teardown path (ephemeral = plain destroy; full = ALB/SG/orphan backstops)."
  value       = module.stack.cluster_profile
}
