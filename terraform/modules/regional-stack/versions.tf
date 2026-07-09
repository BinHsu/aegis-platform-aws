terraform {
  required_version = "~> 1.11"

  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 6.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
    helm       = { source = "hashicorp/helm", version = "~> 2.13" }
    null       = { source = "hashicorp/null", version = "~> 3.0" }
    # `time` provider REMOVED in A3 (#175): its last consumer was
    # time_sleep.crossplane_providers_healthy (crossplane.tf), the 300s wait-hack
    # gating the Crossplane ClusterProviderConfig install. That install moved to
    # ArgoCD, where retry-until-Healthy replaces the blind sleep
    # (gitops/platform-addons/addons/crossplane/applicationset-providerconfig.yaml).
    # The other historical consumer — the fixed 30s EKS access-entry propagation
    # sleep in eks.tf (WS4, run 27843245290) — was already replaced by a readiness
    # poll (terraform_data.eks_access_propagation; #185). No time_sleep remains in
    # this module.
  }
}
