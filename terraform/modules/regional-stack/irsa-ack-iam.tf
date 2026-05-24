# IRSA role for the ACK IAM controller — the paved-road service that lets a
# workload's deploy repo declare its own IAM as `Role`/`Policy` CRDs
# (iam.services.k8s.aws) instead of the platform/fabric tier owning it
# (ADR-07 "Workload IAM — AWS Controllers for Kubernetes").
#
# ┌─ ENFORCEMENT FOUR-PACK COUPLING ───────────────────────────────────────┐
# │ This role's NAME is the seam to the org-level SCP. The fabric SCP       │
# │ `deny-iam-privilege-escalation` (aegis-aws-landing-zone,                │
# │ management/scps) denies iam:CreateRole/etc org-wide except an           │
# │ ArnNotLike allow-list. The ACK controller cannot `iam:CreateRole` from  │
# │ the CRDs at all unless its principal ARN is carved out. The carve-out   │
# │ added there is the PREFIX glob `arn:aws:iam::*:role/aegis-platform-ack- │
# │ iam-*`, so this role MUST keep the `aegis-platform-ack-iam-` prefix.    │
# │ Region is the suffix (matches the existing alb/external-dns naming),    │
# │ which is why the SCP uses a prefix glob, not the suffix glob the        │
# │ karpenter entry uses. See ADR-07 enforcement three-pack #3.             │
# └─────────────────────────────────────────────────────────────────────────┘
#
# ⚠️ implemented, E2E PENDING platform bootstrap — neither this role nor the
# SCP carve-out has been exercised against a live cluster. The bootstrap
# validation gate (issue #6) confirms ACK actually provisions a workload role
# from a CRD with the correct trust subject.

data "aws_caller_identity" "current" {}

# ACK's own least-privilege boundary (defense in depth UNDER the org SCP): the
# controller may only manage IAM roles/policies under the `/aegis-workload/`
# path. A workload's `Role` CRD that omits that path is outside this policy and
# fails — so ACK physically cannot touch platform/CI/break-glass roles, only
# the workload roles it is meant to provision.
resource "aws_iam_policy" "ack_iam" {
  name        = "aegis-platform-ack-iam-${var.region}"
  description = "Scoped IAM-management permissions for the ACK IAM controller. Limited to the /aegis-workload/ path so ACK can only manage workload-declared roles, never platform/CI/break-glass identities. E2E PENDING bootstrap."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageWorkloadRoles"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:UpdateRole",
          "iam:UpdateAssumeRolePolicy",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:ListRoleTags",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:ListAttachedRolePolicies",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:GetRolePolicy",
          "iam:ListRolePolicies",
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aegis-workload/*"
      },
      {
        Sid    = "ManageWorkloadPolicies"
        Effect = "Allow"
        Action = [
          "iam:CreatePolicy",
          "iam:DeletePolicy",
          "iam:GetPolicy",
          "iam:ListPolicyVersions",
          "iam:GetPolicyVersion",
          "iam:CreatePolicyVersion",
          "iam:DeletePolicyVersion",
          "iam:TagPolicy",
          "iam:UntagPolicy",
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/aegis-workload/*"
      },
      {
        # Reconciliation reads — ACK lists/gets to compute drift. Read-only,
        # so account-wide scope here is not an escalation surface (the SCP
        # still blocks every mutating action for non-carved-out principals).
        Sid    = "ReadForReconcile"
        Effect = "Allow"
        Action = [
          "iam:ListRoles",
          "iam:ListPolicies",
          "iam:GetOpenIDConnectProvider",
          "iam:ListOpenIDConnectProviders",
        ]
        Resource = "*"
      },
    ]
  })

  tags = local.common_tags
}

module "irsa_ack_iam" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 6.6"

  # PREFIX is load-bearing — see the SCP coupling note above. Do not reorder
  # to put the region first without updating the fabric SCP glob.
  role_name = "aegis-platform-ack-iam-${var.region}"

  role_policy_arns = {
    ack = aws_iam_policy.ack_iam.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["ack-system:ack-iam-controller"]
    }
  }

  tags = local.common_tags
}
