module "irsa_alb_controller" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  # use_name_prefix=false: fixed role name (≤ 64) — name_prefix is capped at 38
  # and "aegis-platform-aws-alb-controller-<region>" overflows it.
  name            = "aegis-platform-aws-alb-controller-${var.region}"
  use_name_prefix = false

  attach_load_balancer_controller_policy = true
  # IAM is account-GLOBAL. The module's default policy name when
  # attach_load_balancer_controller_policy=true is the fixed string
  # "AWS_Load_Balancer_Controller", so two regions in one account collide on it
  # ("EntityAlreadyExists") during a parallel dual-region apply. Region-suffix
  # the policy name (same fix shape as aegis-core-model-read-<region>).
  policy_name = "AWS_Load_Balancer_Controller-${var.region}"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = local.common_tags
}
