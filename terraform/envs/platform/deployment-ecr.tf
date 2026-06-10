# ADR-10 — shared release registry in a dedicated Deployment (CI/CD) account.
#
# ADR-10 moves the workload image off the per-account ECR pattern (ecr.tf, the
# greeter repo in THIS platform account) and onto a SINGLE shared registry that
# lives in a NEW dedicated `aegis-deployment` account under its own Deployments
# OU. Every cluster — staging + prod, every region — pulls the same immutable
# artifact from that one registry by digest. This is the "build once, promote by
# digest" model: the bits staging verified are the bits prod runs.
#
# WHY a provider alias, not THIS account's default provider: the registry is a
# different trust boundary from the platform account. The supply-chain root of
# trust must not co-locate with the Infrastructure account's IPAM/RAM + fabric
# state (ADR-10 "Single shared registry in a dedicated Deployment account").
# So every resource here targets `provider = aws.deployment`, which assumes a
# Terraform/ECR role IN the deployment account.
#
# ─────────────────────────────────────────────────────────────────────────────
# ⚠️ COUNT-GATED OFF BY DEFAULT — two gates remain before flipping it on.
#   The `aegis-deployment` account WAS vended 2026-06-10 (Deployments OU; the
#   account display NAME is `aegis-deployments`, plural — cosmetic only, every
#   key stays `deployment` singular per landing-zone ADR-018). Remaining gates:
#     1. The `gh-tf-apply-deployment` role + the GitHub Actions OIDC provider
#        must be seeded in that account (chicken-and-egg: the role's own
#        iam:CreateRole is SCP-gated for a human, so it is seeded via
#        break-glass — same bootstrap pattern as gh-tf-apply-platform, oidc.tf;
#        the OIDC provider itself lands via the landing zone's
#        deployment/bootstrap layer).
#     2. W3 ownership: envs/platform is now applied ONCE PER CLUSTER ACCOUNT
#        (infra-apply-account.yml — per-account gh-tf-apply-platform role and
#        per-account state). Enabling this file in BOTH applies would manage
#        the same deployment-account ECR from two states. Enable it from
#        exactly ONE apply context (or extract to a dedicated env) — decided
#        at merge time by the operator, not defaulted here.
#   Until then, `count = var.deployment_account_id == "" ? 0 : 1` gates every
#   resource OFF so the rest of the platform plans / applies cleanly on the
#   current per-account topology. Flip it on by supplying the account id via
#   gitignored tfvars / CI var. (Mirrors the enable_* count-gate pattern used
#   for observability + cloudwatch-datasource in this env.)
# ─────────────────────────────────────────────────────────────────────────────

locals {
  # One switch: empty account id => the whole shared-registry path is off.
  deployment_enabled = var.deployment_account_id == "" ? 0 : 1

  # Role the platform CI (gh-tf-apply-platform) assumes to manage ECR in the
  # deployment account. Named in the gh-tf-* family on purpose: it falls under
  # the org-root deny-iam-privilege-escalation SCP's existing gh-tf-* carve-out,
  # so NO SCP change is needed (ADR-10 "Access to the Deployment account").
  #
  # NULL when the gate is off. The AWS provider EAGERLY configures every
  # declared provider block at plan time — even when all of its resources are
  # count=0 — and it attempts the AssumeRole then (empirically: infra-plan run
  # 27284078248 failed on the empty-id interpolation `arn:aws:iam:::role/...`).
  # A null role_arn makes the provider IGNORE the assume_role block entirely
  # (restored behavior in hashicorp/aws >= 5.68.0, issue #39296; this env locks
  # 5.100.0), so the disabled path configures as the CI's base credentials and
  # is never exercised.
  deployment_tf_role_arn = var.deployment_account_id == "" ? null : "arn:aws:iam::${var.deployment_account_id}:role/gh-tf-apply-deployment"
}

# Cross-account provider — assumes the Terraform/ECR role in aegis-deployment.
# Configured unconditionally (a provider block cannot be count-gated). With
# deployment_account_id="" the role_arn local above is NULL, which makes the
# provider skip the assume_role entirely (see the local's comment) — plan/apply
# of the rest of the env is unaffected. Every resource below is additionally
# count-gated on local.deployment_enabled, so the disabled provider is never
# exercised.
provider "aws" {
  alias  = "deployment"
  region = var.platform_region

  assume_role {
    role_arn     = local.deployment_tf_role_arn
    session_name = "aegis-platform-adr10-ecr"
  }

  default_tags {
    tags = {
      Project    = var.project_tag
      Env        = "deployment"
      ManagedBy  = "terraform"
      Repo       = "github.com/BinHsu/aegis-platform-aws"
      CostCenter = var.cost_center_tag
    }
  }
}

# ─── shared per-workload ECR repository ──────────────────────────────────────
# Start with aegis-greeter (the only built workload today). Add one repo per
# workload as the catalog grows — same block, different name.
#tfsec:ignore:aws-ecr-repository-customer-key
resource "aws_ecr_repository" "shared_greeter" {
  count    = local.deployment_enabled
  provider = aws.deployment

  name = var.ecr_repository_name

  # IMMUTABLE — ADR-10 "Build once". A verified digest's tag can never be
  # re-pointed under it. Combined with digest pinning in the deploy repo, every
  # running artifact is auditable back to exactly one build.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  # AES256 (AWS-managed) is the take-home encryption choice; customer-managed
  # KMS for the shared registry is production hardening (docs/tradeoffs.md),
  # matching the per-account ecr.tf decision.
  encryption_configuration {
    encryption_type = "AES256"
  }
}

# ─── cross-account pull policy ───────────────────────────────────────────────
# Grants the read-only pull verb set to every CLUSTER account in
# var.cluster_pull_account_ids (aegis-staging + aegis-prod). This is the seam
# that makes ONE registry serve every environment: the clusters' nodes (their
# instance/IRSA principals, already in their own account) pull the immutable
# digest cross-account. No push grant here — push is a separate scoped OIDC role
# (below), least-privilege per ADR-10.
data "aws_iam_policy_document" "shared_greeter_pull" {
  count = local.deployment_enabled

  statement {
    sid    = "AllowClusterAccountsPull"
    effect = "Allow"

    principals {
      type = "AWS"
      # The account root principal — any principal in the cluster account that
      # ALSO has an identity-side ECR permission can pull. (ECR pull is a
      # two-sided grant: this resource policy is necessary, the puller's own
      # IAM/node role is the second half.) Scoping to the account root, not a
      # specific role, keeps the registry decoupled from each cluster's
      # internal IRSA/node-role naming.
      identifiers = [for acct in var.cluster_pull_account_ids : "arn:aws:iam::${acct}:root"]
    }

    # Exactly the read verbs a `docker pull` / kubelet image-pull performs.
    # NOT GetAuthorizationToken — that is an account-level ecr: action the
    # puller calls against its OWN registry-auth endpoint; it is not granted via
    # a cross-account repository policy.
    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
    ]
  }
}

resource "aws_ecr_repository_policy" "shared_greeter_pull" {
  count    = local.deployment_enabled
  provider = aws.deployment

  repository = aws_ecr_repository.shared_greeter[0].name
  policy     = data.aws_iam_policy_document.shared_greeter_pull[0].json
}

# ─── lifecycle policy ────────────────────────────────────────────────────────
# Mirrors the per-account ecr.tf: expire untagged quickly, keep the last 10
# tagged. With IMMUTABLE tags + digest pinning, "tagged" images are the
# human-readable git-sha labels; the digest is the real pin.
resource "aws_ecr_lifecycle_policy" "shared_greeter" {
  count    = local.deployment_enabled
  provider = aws.deployment

  repository = aws_ecr_repository.shared_greeter[0].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the last 10 tagged images"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = 10
        }
        action = { type = "expire" }
      },
    ]
  })
}

# ─── workload push role (scoped OIDC) ────────────────────────────────────────
# ADR-10 "Access to the Deployment account": the build repo's GitHub Actions
# assumes a SCOPED OIDC role in aegis-deployment to push (ecr:PutImage) its OWN
# repo. Distinct from gh-tf-apply-deployment (which manages the ECR resources
# via Terraform). This is the build-once push target — ONE registry, so the
# build repo no longer needs per-environment push grants.
#
# The GitHub Actions OIDC provider in the deployment account is an LZ-owned
# per-account singleton (same as oidc.tf in this env references the platform
# account's). Referenced via data source so a platform destroy can never delete
# it out from under other federating repos.
data "aws_iam_openid_connect_provider" "github_deployment" {
  count    = local.deployment_enabled
  provider = aws.deployment

  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "shared_greeter_push_trust" {
  count = local.deployment_enabled

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github_deployment[0].arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Pinned to the build repo's main ref — publish.yml runs only on push to
    # main, so a PR / fork branch on the greeter repo cannot assume the push
    # role (tightest blast radius, same as the per-account greeter_ci trust).
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_owner}/aegis-greeter:ref:refs/heads/main"]
    }
  }
}

data "aws_iam_policy_document" "shared_greeter_push_permissions" {
  count = local.deployment_enabled

  # ECR auth token — account-level, cannot be resource-scoped.
  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Push (+ the layer reads docker push performs), scoped to the single shared
  # repo ARN. Exactly the verb set the per-account greeter_ci role uses, now
  # targeting the ONE shared registry.
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
    resources = [aws_ecr_repository.shared_greeter[0].arn]
  }
}

resource "aws_iam_role" "shared_greeter_push" {
  count    = local.deployment_enabled
  provider = aws.deployment

  name               = "aegis-greeter-ci-push"
  assume_role_policy = data.aws_iam_policy_document.shared_greeter_push_trust[0].json
}

resource "aws_iam_role_policy" "shared_greeter_push" {
  count    = local.deployment_enabled
  provider = aws.deployment

  name   = "ecr-push"
  role   = aws_iam_role.shared_greeter_push[0].id
  policy = data.aws_iam_policy_document.shared_greeter_push_permissions[0].json
}
