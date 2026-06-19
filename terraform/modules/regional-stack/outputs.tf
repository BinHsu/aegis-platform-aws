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

# ── Cold-start gate surface (envs/regional/tests/cold_start.tftest.hcl) ─────────
# These outputs expose the exact resource shapes the cold-start test asserts on.
# A module's internal resources are not reachable from a `terraform test` run
# (only its outputs are), so the gate needs these to verify the ADR-21 cold-start
# contracts: region-suffixed IAM names (the EntityAlreadyExists class, #108 / §C)
# and the ACM cert domain/SAN shapes (the #107 zone-fallback class). They are
# stable, non-sensitive identifiers — useful for any downstream consumer too.

output "engine_iam_role_name" {
  description = "Name of the engine's EKS Pod Identity IAM role (ADR-21 §A). Region-suffixed (aegis-core-engine-<region>) to avoid the dual-region global-name collision — asserted by the cold-start gate."
  value       = aws_iam_role.engine.name
}

output "model_read_policy_name" {
  description = "Name of the per-region engine model-read managed policy (model-store.tf). Region-suffixed — the #108 collision class the cold-start gate guards."
  value       = aws_iam_policy.model_read.name
}

output "model_write_policy_name" {
  description = "Name of the per-region model-populator write policy (pod-identity-model-populator.tf, Phase 4c). Region-suffixed — same #108 collision class the cold-start gate guards. Held by the populator identity only; the engine role stays read-only."
  value       = aws_iam_policy.model_write.name
}

output "model_populator_iam_role_name" {
  description = "Name of the model-populator's EKS Pod Identity IAM role (pod-identity-model-populator.tf, Phase 4c). Region-suffixed (aegis-core-model-populator-<region>) — the dual-region EntityAlreadyExists class."
  value       = aws_iam_role.model_populator.name
}

output "gateway_cert_domain_name" {
  description = "domain_name of the gateway ACM cert (acm.tf). On a cold start this comes from the zone_name placeholder; the gate asserts it is non-empty (#107)."
  value       = aws_acm_certificate.gateway.domain_name
}

output "gateway_cert_sans" {
  description = "subject_alternative_names of the gateway ACM cert. The gate asserts no SAN ends in '.' (an empty zone_name would build '*.', which the real provider rejects — #107)."
  value       = aws_acm_certificate.gateway.subject_alternative_names
}

output "zone_id_in_use" {
  description = "The zone_id the module resolved (var.zone_id). On a cold start this is the Z-id placeholder from main.tf, not '' — the gate asserts the Route53 record never gets an empty zone_id (#107)."
  value       = var.zone_id
}
