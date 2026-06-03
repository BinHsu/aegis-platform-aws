module "irsa_external_dns" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  # use_name_prefix=false: fixed role name (≤ 64) — name_prefix is capped at 38
  # and "aegis-platform-aws-external-dns-<region>" overflows it.
  name            = "aegis-platform-aws-external-dns-${var.region}"
  use_name_prefix = false

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
