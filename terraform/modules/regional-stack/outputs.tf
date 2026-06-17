output "cluster_name" {
  description = "EKS cluster name (used by regional/ providers for k8s/helm exec auth, and as a stable label across observability signals)."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint (consumed by regional/ kubernetes + helm providers)."
  value       = module.eks.cluster_endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA cert (consumed by regional/ kubernetes + helm providers; base64decode applied on consumer side)."
  value       = module.eks.cluster_certificate_authority_data
}

output "oidc_provider_arn" {
  description = "IRSA OIDC provider ARN (for downstream IRSA roles if added per workload)."
  value       = module.eks.oidc_provider_arn
}

output "vpc_id" {
  description = "VPC ID (informational)."
  value       = module.vpc.vpc_id
}

# Intentionally NO alb_dns_name / alb_zone_id outputs. The greeter ALB is
# provisioned by the ALB controller from the Ingress manifest synced by
# ArgoCD, which happens AFTER this TF apply completes. Route 53 records
# pointing at the ALB are managed by external-dns (TODO — see backlog Step
# 6 follow-up) or via a separate post-apply step that reads the Ingress
# status. Avoiding the chicken-and-egg of "TF creates record pointing at
# resource TF cannot see yet."

output "acm_certificate_arn" {
  description = "Per-region ACM cert ARN for the gateway ALB (WS3-R). Injected onto opted-in workload Ingresses by the ApplicationSet certArn (argocd.tf), replacing the old single platform cert."
  value       = aws_acm_certificate_validation.gateway.certificate_arn
}
