# IRSA role for the Crossplane upjet provider-aws-iam — the paved-road service
# that lets a workload's deploy repo declare its own IAM as a WorkloadIdentity
# XR, which the Composition renders into a cluster-scoped iam.aws.upbound.io/Role
# the provider reconciles into real AWS IAM (ADR-07 + ADR-09 amended by fix B).
#
# This role was originally created for the ACK IAM controller. fix B (2026-06-18)
# removed ACK and REUSES this exact role for the upjet provider — the name is
# kept identical on purpose so the fabric SCP carve-out keeps matching (see
# below). Only the trust SUBJECT moves (ack-system:ack-iam-controller →
# crossplane-system:provider-aws-iam) and the reconcile READ scope broadens.
#
# ┌─ ENFORCEMENT FOUR-PACK COUPLING ───────────────────────────────────────┐
# │ This role's NAME is the seam to the org-level SCP. The fabric SCP       │
# │ `deny-iam-privilege-escalation` (aegis-aws-landing-zone,                │
# │ management/scps) denies iam:CreateRole/etc org-wide except an           │
# │ ArnNotLike allow-list. The provider cannot `iam:CreateRole` from the    │
# │ rendered Role MR at all unless its principal ARN is carved out. The     │
# │ carve-out there is the PREFIX glob                                      │
# │ `arn:aws:iam::*:role/aegis-platform-aws-ack-iam-*`, so this role MUST   │
# │ keep the `aegis-platform-aws-ack-iam-` prefix. Because fix B reuses     │
# │ THIS EXACT ROLE (same name), the SCP glob still matches with no         │
# │ landing-zone change. Region is the suffix (matches the existing         │
# │ alb/external-dns naming), which is why the SCP uses a prefix glob, not  │
# │ the suffix glob the karpenter entry uses. See ADR-07 three-pack #3.     │
# └─────────────────────────────────────────────────────────────────────────┘
#
# ⚠️ E2E proven on staging 2026-06-18 (the engine assumed
# role/aegis-workload/aegis-core-engine and pulled its model); PENDING
# per-account bootstrap elsewhere.

data "aws_caller_identity" "current" {}

# The provider's own least-privilege boundary (defense in depth UNDER the org
# SCP): it may only manage IAM roles/policies under the `/aegis-workload/` path.
# A WorkloadIdentity that renders a Role outside that path is outside this policy
# and fails — so the provider physically cannot touch platform/CI/break-glass
# roles, only the workload roles it is meant to provision.
resource "aws_iam_policy" "ack_iam" {
  name        = "aegis-platform-aws-ack-iam-${var.region}"
  description = "Scoped IAM-management permissions for the Crossplane upjet provider-aws-iam (fix B; was ACK). Mutations limited to the /aegis-workload/ path so the provider can only manage workload-declared roles, never platform/CI/break-glass identities."

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
        # Reconciliation reads — the provider lists/gets to compute drift.
        # Read-only, so account-wide scope here is not an escalation surface (the
        # SCP still blocks every mutating action for non-carved-out principals).
        #
        # Broadened from the original ACK read set (fix B): upjet OBSERVES a
        # not-yet-existing role by calling iam:GetRole on it. IAM authorizes that
        # call against the name-only ARN `role/<name>` (no path) — which the
        # path-scoped `role/aegis-workload/*` mutate statements above do NOT
        # cover — so the provider got a 403 on the observe step, before
        # CreateRole was ever attempted. Get*/List* over `*` covers the observe;
        # GenerateServiceLastAccessedDetails covers upjet's reconcile reads. The
        # mutating statements stay path-scoped to /aegis-workload/* — do NOT
        # broaden those.
        Sid    = "ReadForReconcile"
        Effect = "Allow"
        Action = [
          "iam:Get*",
          "iam:List*",
          "iam:GenerateServiceLastAccessedDetails",
        ]
        Resource = "*"
      },
    ]
  })

  tags = local.common_tags
}

module "irsa_ack_iam" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  # PREFIX is load-bearing — see the SCP coupling note above. Do not reorder
  # to put the region first without updating the fabric SCP glob.
  # use_name_prefix=false: use this as the EXACT role name (≤ 64) rather than an
  # IAM name_prefix (capped at 38) — "aegis-platform-aws-ack-iam-<region>" is 39,
  # and the SCP glob needs the exact prefix preserved, so a fixed name is required.
  name            = "aegis-platform-aws-ack-iam-${var.region}"
  use_name_prefix = false

  policies = {
    ack = aws_iam_policy.ack_iam.arn
  }

  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn
      # fix B: ACK is gone; the upjet provider's stable SA assumes this role.
      namespace_service_accounts = ["crossplane-system:provider-aws-iam"]
    }
  }

  tags = local.common_tags
}
