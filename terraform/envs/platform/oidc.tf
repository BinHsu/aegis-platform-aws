# ---- GitHub Actions OIDC provider — SHARED, referenced NOT managed ----------
# token.actions.githubusercontent.com is a per-ACCOUNT singleton and an
# account-foundation federation root. It is owned and lifecycle-managed by the
# aegis landing-zone (the same layer that owns the break-glass role + state
# backend), and shared by every repo's CI roles. This composition references it
# via data source so:
#   - a platform `terraform destroy` can never delete the provider out from
#     under enclave / other repos that federate the same singleton, and
#   - the escalation-critical iam:CreateOpenIDConnectProvider stays out of the
#     platform apply path (it belongs to the foundation layer, not a workload).
# (ADR-03 § "GitHub OIDC provider ownership". The enclave made the same move in
# its ADR-0052.)
#
# DEPENDENCY: platform's target account MUST already have this provider, created
# by the landing-zone bootstrap, before `terraform apply` here. LZ owns it in
# staging / shared / management, and in prod since the ADR-0051 governance work
# (the prod joint-strike bootstrapped prod OIDC + gh-tf-apply-platform there).
#
# NOTE: the per-cluster EKS IRSA OIDC providers (oidc.eks.<region>...) are a
# DIFFERENT thing — workload artifacts, one per cluster, created and owned by
# this stack's regional module. Only the GitHub Actions provider moves to LZ.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# ---- Role A: aegis-greeter CI → ECR push -----------------------------------
data "aws_iam_policy_document" "greeter_ci_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Pinned to the main ref — aegis-greeter's publish.yml only runs on
    # push to main, so the OIDC subject can be the exact ref (no branch
    # wildcard). Tightest blast radius: a PR branch / fork branch on the
    # greeter repo cannot assume this role.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_owner}/aegis-greeter:ref:refs/heads/main"]
    }
  }
}

data "aws_iam_policy_document" "greeter_ci_permissions" {
  # ECR auth token — account-level, cannot be resource-scoped.
  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # ECR push (+ the layer reads docker push performs) — scoped to the
  # single aegis-greeter repo ARN. Exactly the set cross-repo issue #9
  # enumerates plus ecr:DescribeImages: publish.yml (post greeter#14) calls
  # `aws ecr describe-images` as the authoritative digest source after push;
  # without it the registry-authoritative digest step fails with
  # AccessDeniedException (greeter run 27409469237).
  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.greeter.arn]
  }
}

resource "aws_iam_role" "greeter_ci" {
  name               = "aegis-greeter-ci"
  assume_role_policy = data.aws_iam_policy_document.greeter_ci_trust.json
}

resource "aws_iam_role_policy" "greeter_ci" {
  name   = "ecr-push"
  role   = aws_iam_role.greeter_ci.id
  policy = data.aws_iam_policy_document.greeter_ci_permissions.json
}

# ---- Role B: aegis-platform-aws CI plan → read-only AWS -----------------------
# Trust = any ref/branch on aegis-platform-aws (PR branches included).
# Permissions = ReadOnlyAccess only (terraform plan / validate / lint).
data "aws_iam_policy_document" "infra_ci_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_owner}/aegis-platform-aws:*"]
    }
  }
}

resource "aws_iam_role" "infra_ci" {
  name               = "aegis-platform-aws-ci"
  assume_role_policy = data.aws_iam_policy_document.infra_ci_trust.json
}

# Production hardening: bespoke least-privilege policy listing only the
# read actions terraform plan actually needs. Documented in tradeoffs.
resource "aws_iam_role_policy_attachment" "infra_ci_readonly" {
  role       = aws_iam_role.infra_ci.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ---- Role C: gh-tf-apply-platform CI apply → admin scoped to main branch ------
# Trust = pushes to refs/heads/main + the main-branch-only apply environments
# (staging / prod-apply / prod-apply-gated) — PRs cannot assume this role.
# Permissions = AdministratorAccess (production hardening = bespoke
# least-privilege; documented in tradeoffs). Used by infra-apply.yml.
#
# Named in the `gh-tf-*` family on purpose: the landing-zone org SCP
# `deny-iam-privilege-escalation` permits IAM mutation only for a `gh-tf-*`
# (and break-glass / Control-Tower) name glob. A repo-branded name like the
# former `aegis-platform-aws-apply` is NOT in that glob, so its IAM-creating
# applies (EKS IRSA, the ACK controller role) would be SCP-denied. `gh-tf-*`
# makes the existing glob cover it with no landing-zone SCP change.
# NOTE on rename: re-seed the AWS_INFRA_APPLY_ROLE_ARN repo secret with the new
# ARN after apply, and seed the new role once via break-glass (its own
# iam:CreateRole is SCP-gated for a human — chicken-and-egg).
data "aws_iam_policy_document" "infra_apply_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Two subject shapes, because GitHub mints DIFFERENT OIDC subjects
    # depending on whether the job declares `environment:`:
    #   - no environment  → sub = repo:<owner>/<repo>:ref:refs/heads/main
    #   - environment: X  → sub = repo:<owner>/<repo>:environment:X
    # (the environment sub REPLACES the ref sub — it does not add to it).
    # A trust pinned to the ref sub alone therefore denies every
    # environment-routed job: infra-apply.yml's apply-regional runs in
    # `prod-apply` / `prod-apply-gated`, so its AssumeRoleWithWebIdentity
    # would fail. Each accepted subject is tied to a job below.
    #
    # The blast-radius story is unchanged: the ref sub still requires a
    # reviewed commit on main; each environment sub requires a run that
    # GitHub routed through that environment (whose deployment-branch
    # policy / required reviewers are configured in repo Settings —
    # main-branch-only for all four).
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        # Non-environment jobs on main: infra-apply.yml version-gate +
        # apply-platform, infra-ops.yml bootstrap, ttl-reaper.yml scan.
        "repo:${var.github_owner}/aegis-platform-aws:ref:refs/heads/main",
        # infra-apply.yml apply-regional, clean version gate (ungated env).
        "repo:${var.github_owner}/aegis-platform-aws:environment:prod-apply",
        # infra-apply.yml apply-regional, version gate tripped (required
        # reviewer) — and the W3 prod promotion path (prod ALWAYS gated).
        "repo:${var.github_owner}/aegis-platform-aws:environment:prod-apply-gated",
        # W3 staging auto-apply on merge to main (ungated env).
        "repo:${var.github_owner}/aegis-platform-aws:environment:staging",
      ]
    }
  }
}

resource "aws_iam_role" "infra_apply" {
  name               = "gh-tf-apply-platform"
  assume_role_policy = data.aws_iam_policy_document.infra_apply_trust.json
}

resource "aws_iam_role_policy_attachment" "infra_apply_admin" {
  role       = aws_iam_role.infra_apply.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# ---- Role D: gh-tf-destroy-platform — teardown, gated by HUMAN approval (A7) --
# The apply role above trusts ONLY refs/heads/main, so a teardown dispatched from
# a feature branch is OIDC-denied (this caused the 2026-06-06 incident's failed
# teardown attempt #2 and recurs every feature-branch verify). A7 fixes that
# WITHOUT letting any branch delete prod: the boundary is a human, not a branch.
#
# Trust = the GitHub Environment subject `environment:destroy` (NOT a branch).
# GitHub only mints an OIDC token with that subject AFTER the `destroy`
# environment's required reviewer (the operator) approves the run — see
# infra-ops.yml's destroy job. So this role can be assumed from ANY branch, but
# only by a destroy run the operator has approved. (Why environment, not
# `refs/heads/*`: a destroy-scoped IAM policy still *deletes* prod by design, so
# a wide branch trust would let any branch nuke prod; the human gate is the real
# control.)
#
# Permissions = AdministratorAccess for now (the human gate is primary control).
# Follow-up (optional, needs a live destroy to tune): a destroy-scoped policy
# (allow Delete*/Detach*/Describe* + the Modify/Schedule calls a real destroy
# needs, deny Create*/Run*) — authored empirically from AccessDenied on a real
# teardown, not from theory.
data "aws_iam_policy_document" "infra_destroy_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Branch-agnostic; each subject is an environment with its own control:
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        # infra-ops.yml destroy — gated by the `destroy` environment's
        # required reviewer (the human gate is the control).
        "repo:${var.github_owner}/aegis-platform-aws:environment:destroy",
        # ttl-reaper auto-destroy path — UNGATED (no reviewer; the reaper
        # runs unattended by design) but tag-guarded: only clusters without
        # keep/ttl-exempt tags, re-verified in-job. Environment deployment
        # policy = main branch only.
        "repo:${var.github_owner}/aegis-platform-aws:environment:reaper-destroy",
      ]
    }
  }
}

resource "aws_iam_role" "infra_destroy" {
  name               = "gh-tf-destroy-platform"
  assume_role_policy = data.aws_iam_policy_document.infra_destroy_trust.json
}

resource "aws_iam_role_policy_attachment" "infra_destroy_admin" {
  role       = aws_iam_role.infra_destroy.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "infra_destroy_role_arn" {
  description = "ARN of gh-tf-destroy-platform — set as the AWS_DESTROY_ROLE_ARN repo secret."
  value       = aws_iam_role.infra_destroy.arn
}
