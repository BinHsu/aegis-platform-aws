terraform {
  required_version = "~> 1.11"

  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 6.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
    helm       = { source = "hashicorp/helm", version = "~> 2.13" }
    null       = { source = "hashicorp/null", version = "~> 3.0" }
    # `time` provider RE-ADDED (WS4): time_sleep.eks_access_propagation in eks.tf
    # bounds the EKS access-entry -> API-server authorizer propagation lag. The
    # gh-tf-apply-platform ClusterAdmin access entry is created in the SAME apply
    # as the first cluster-scoped create (kubernetes_namespace), and the authorizer
    # had not yet picked up the grant 1.3s later -> "namespaces is forbidden"
    # (run 27843245290). create-completion of the access entry != grant effective.
    # (Prior removal in ADR-21 §A dropped a DIFFERENT use: wait_provider_crds for
    # the retired upjet CRDs.)
    time = { source = "hashicorp/time", version = "~> 0.12" }
  }
}
