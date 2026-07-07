terraform {
  required_version = "~> 1.11"

  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 6.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
    helm       = { source = "hashicorp/helm", version = "~> 2.13" }
    null       = { source = "hashicorp/null", version = "~> 3.0" }
    # `time` provider: time_sleep.crossplane_providers_healthy (crossplane.tf)
    # still consumes it. Its OTHER consumer — the fixed 30s EKS access-entry
    # propagation sleep in eks.tf (WS4, run 27843245290) — was replaced by a
    # readiness poll (terraform_data.eks_access_propagation — built-in resource,
    # no provider; #185). (Prior removal in ADR-21 §A dropped a DIFFERENT use:
    # wait_provider_crds for the retired upjet CRDs.)
    time = { source = "hashicorp/time", version = "~> 0.12" }
  }
}
