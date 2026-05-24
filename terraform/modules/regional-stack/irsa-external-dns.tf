module "irsa_external_dns" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 6.6"

  role_name = "aegis-platform-external-dns-${var.region}"

  # Built-in external-dns policy, scoped to the one hosted zone — the
  # zone-wildcard default would let external-dns write any zone in the
  # account. ListHostedZones / ListResourceRecordSets stay account-wide
  # (the API does not support resource scoping for those).
  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = ["arn:aws:route53:::hostedzone/${var.zone_id}"]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:external-dns"]
    }
  }

  tags = local.common_tags
}
