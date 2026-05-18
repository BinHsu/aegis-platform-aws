# external-dns — watches the greeter Ingress and reconciles a Route 53
# record under the platform-owned hosted zone. The sibling of the ALB
# controller: one turns an Ingress into an ALB, the other turns it into a
# DNS record.
#
# txtOwnerId is the per-region cluster name, so each region's instance owns
# only its own records via the TXT registry. That is what makes a second
# region safe to add: each external-dns manages its own set-identifier'd
# record under the shared hostname — the basis for cross-region latency +
# failover routing once more than one region runs.
resource "helm_release" "external_dns" {
  name       = "external-dns"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = "1.21.1" # pinned

  set {
    name  = "provider.name"
    value = "aws"
  }

  # Only ever touch the platform-owned zone.
  set {
    name  = "domainFilters[0]"
    value = trimsuffix(var.zone_name, ".")
  }

  # Source records from Ingresses (the greeter ALB Ingress), not Services.
  set {
    name  = "sources[0]"
    value = "ingress"
  }

  set {
    name  = "policy"
    value = "sync"
  }

  # TXT ownership registry — txtOwnerId scoped per region so instances do
  # not clobber each other's records in the shared zone.
  set {
    name  = "registry"
    value = "txt"
  }

  set {
    name  = "txtOwnerId"
    value = local.cluster_name
  }

  set {
    name  = "txtPrefix"
    value = "edns-"
  }

  set {
    name  = "serviceAccount.name"
    value = "external-dns"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.irsa_external_dns.iam_role_arn
  }

  depends_on = [module.eks]
}
