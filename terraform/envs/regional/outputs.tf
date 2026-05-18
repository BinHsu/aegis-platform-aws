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
