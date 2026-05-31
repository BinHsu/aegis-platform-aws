resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # AWS no longer validates the thumbprint at sts:AssumeRoleWithWebIdentity
  # for github.com's OIDC issuer (chain-of-trust verification handled at the
  # control-plane layer), but the field is still required by the IAM API.
  # The value below is the well-known SHA-1 of github.com's signing cert
  # ancestor and is duplicated across most public examples; functional only
  # for backwards-compat.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# ---- Role A: aegis-greeter CI → ECR push -----------------------------------
data "aws_iam_policy_document" "greeter_ci_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
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
  # enumerates; no broader Describe*/List* (those aren't needed to push).
  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
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
      identifiers = [aws_iam_openid_connect_provider.github.arn]
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
# Trust = ONLY pushes to refs/heads/main (PRs cannot assume this role).
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
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # The "ref:refs/heads/main" constraint blocks PR branches from
    # assuming this role — PRs only get the plan role above. Combined
    # with branch protection (require status checks + reviews + linear
    # history, see platform/branch-protection.tf), this means an apply
    # only happens via a reviewed commit landing on main.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_owner}/aegis-platform-aws:ref:refs/heads/main"]
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
