# ============================================================================
# CI IAM seed — the GitHub OIDC trust + the four CI roles, relocated here from
# envs/platform/oidc.tf (ADR-13).
#
# WHY HERE, NOT IN envs/platform
# ------------------------------------------------------------------------------
# These roles are the federation entry points every CI workflow assumes
# (gh-tf-apply-platform, gh-tf-destroy-platform, the read-only plan role, the
# greeter ECR push role). When they lived in envs/platform they were destroyed
# by `destroy-platform` — and that produced four live consequences on
# 2026-06-12 (run record: docs/runbooks/2026-06-12-joint-strike.md §G):
#   1. Self-delete hazard: destroy-platform runs AS gh-tf-destroy-platform, so
#      terraform deleting that role mid-run invalidates the live STS session.
#      Worked around by a pre-destroy `state rm` (PR #64) — which then ...
#   2. ... orphaned an admin-attached gh-tf-destroy-platform in BOTH accounts,
#      out of state, ready to EntityAlreadyExists the next apply.
#   3. Cold-start chicken-egg: the destroy also deleted gh-tf-apply-platform +
#      the read role, so the NEXT cycle had no OIDC path into the account — the
#      operator had to break-glass seed via AWSControlTowerExecution again.
#   4. infra-plan red light: the plan role it assumes had been deleted.
#
# bootstrap is the right home because it ALREADY is:
#   - LOCAL state (versions.tf) — it survives the remote-state-bucket teardown
#     and never destroys itself (no chicken-egg with its own backend).
#   - the operator-applied break-glass seed layer — applied once per cold start
#     by a principal that can write IAM (AWSControlTowerExecution / break-glass),
#     which is exactly who must create these roles on day zero. The roles cannot
#     create themselves; the seed principal must. The cold-start apply is a
#     single formal command, so re-seeding after a full teardown is a first-class
#     path, not a hand patch.
#   - the layer whose `prevent_destroy` guards the IRREVERSIBLE resource (the
#     state bucket in main.tf — losing it loses every downstream env's state).
#     The CI roles do NOT take that guard: they are cheaply, idempotently
#     recreatable, so a full teardown may delete them and the next seed apply
#     restores them from true zero.
#
# "Teardown to zero" stays UNCHANGED by ADR-13: true zero — zero billable, zero
# workload, AND these CI roles included. What ADR-13 changes is the COLD-START
# CONTRACT, not the teardown definition. A full close-out may delete these roles
# (they live in this seed env, not the platform state — so destroy-platform no
# longer touches them, but a `terraform destroy` of THIS env, or an operator
# break-glass delete, does remove them). The next cold start is then a single
# formal operator command — `terraform apply` on envs/bootstrap — that recreates
# everything from true zero. No hand-typed patches, no orphan imports, no
# state-rm choreography: that is the operator decision of 2026-06-12
# ("這次可以全拆,讓下一次的冷啟動是完整的不再是補丁手敲的" — full teardown is
# allowed; the next cold start must be a complete, formalized first-class path).
#
# These roles deliberately carry NO `prevent_destroy` (only the state bucket in
# main.tf does — losing the bucket loses every downstream env's state, an
# irreversible event the guard still blocks). The roles are cheaply, idempotently
# recreatable by the seed apply, so guarding them would only re-introduce the
# "destroy refuses / state-rm dance" this ADR set out to delete.
#
# IDEMPOTENCY (verify on rework): `terraform apply` on this env converges from
# BOTH starting states —
#   - roles-exist: apply is a no-op (plan = 0 changes) — every attribute is
#     deterministic from account_id / region / fixed names, nothing drifts.
#   - roles-deleted (out-of-band break-glass delete, or a prior `terraform
#     destroy` of this env): apply recreates them. terraform refresh detects the
#     externally-deleted role (GetRole → NoSuchEntity) and plans a clean Create —
#     no import, no manual state surgery.
#
# SCP: every role here is in the `gh-tf-*` glob OR a CI-branded name the org SCP
# `deny-iam-privilege-escalation` permits for the seed principal. Creating them
# from a human SSO principal is SCP-denied (chicken-egg) — so day-zero apply of
# this env runs as AWSControlTowerExecution / break-glass, not an operator's SSO
# role.
# ============================================================================

# ---- GitHub Actions OIDC provider — SHARED, referenced NOT managed ----------
# token.actions.githubusercontent.com is a per-ACCOUNT singleton owned by the
# landing-zone (the foundation tier that owns the break-glass role + org SCP).
# Referenced via data source so this seed env can never delete the provider out
# from under enclave / other repos that federate the same singleton, and so
# iam:CreateOpenIDConnectProvider stays out of every workload path.
# (ADR-03 § "GitHub OIDC provider ownership"; the enclave made the same move in
# its ADR-0052. DEPENDENCY: the LZ bootstrap must have created this provider in
# the target account before this env is applied.)
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# ---- Role A: aegis-greeter CI -> ECR push -----------------------------------
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

    # Pinned to the main ref — aegis-greeter's publish.yml only runs on push to
    # main, so the OIDC subject can be the exact ref (no branch wildcard).
    # Tightest blast radius: a PR / fork branch on greeter cannot assume this.
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

  # ECR push (+ the layer reads docker push performs) — scoped to the single
  # aegis-greeter repo ARN. The repo itself is created by envs/platform
  # (ecr.tf), so we CONSTRUCT its ARN from account + region + the fixed repo
  # name rather than read platform's remote state: bootstrap must have ZERO
  # upstream dependency (it is the seed layer — nothing exists before it). The
  # name `aegis-greeter` is the same literal envs/platform/ecr.tf uses.
  # ecr:DescribeImages is required because publish.yml (post greeter#14) calls
  # `aws ecr describe-images` as the authoritative digest source after push;
  # without it that step fails with AccessDeniedException.
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
    resources = ["arn:aws:ecr:${var.platform_region}:${data.aws_caller_identity.current.account_id}:repository/aegis-greeter"]
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

# ---- Role B: aegis-platform-aws CI plan -> read-only AWS --------------------
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

resource "aws_iam_role_policy_attachment" "infra_ci_readonly" {
  role       = aws_iam_role.infra_ci.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ---- Role C: gh-tf-apply-platform CI apply -> admin scoped to main ----------
# Trust = pushes to refs/heads/main + the main-branch-only apply environments
# (staging / prod-apply / prod-apply-gated). PRs cannot assume this role.
# Permissions = AdministratorAccess (least-privilege scoping is tradeoffs work).
# Named in the `gh-tf-*` family on purpose: the org SCP permits IAM mutation
# only for a `gh-tf-*` (and break-glass / Control-Tower) name glob, so this
# role's own IAM-creating applies (EKS IRSA, the ACK controller role) are not
# SCP-denied.
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

    # GitHub mints DIFFERENT OIDC subjects depending on whether a job declares
    # `environment:` — the environment sub REPLACES the ref sub. Each accepted
    # subject is tied to a job in infra-apply-account.yml / infra-apply.yml /
    # infra-ops.yml. The blast-radius story is unchanged: the ref sub requires a
    # reviewed commit on main; each environment sub requires a run GitHub routed
    # through that environment (main-branch-only deployment policy for all four).
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        # Non-environment jobs on main: infra-apply.yml version-gate +
        # apply-platform, infra-ops.yml bootstrap, ttl-reaper.yml scan.
        "repo:${var.github_owner}/aegis-platform-aws:ref:refs/heads/main",
        # infra-apply.yml apply-regional, clean version gate (ungated env).
        "repo:${var.github_owner}/aegis-platform-aws:environment:prod-apply",
        # apply-regional, version gate tripped (required reviewer) + the W3 prod
        # promotion path (prod ALWAYS gated).
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

# ---- Role D: gh-tf-destroy-platform — teardown, gated by HUMAN approval ------
# Trust = the GitHub Environment subject `environment:destroy` (NOT a branch):
# GitHub mints an OIDC token with that subject only AFTER the `destroy`
# environment's required reviewer (the operator) approves the run. So this role
# can be assumed from ANY branch, but only by a destroy run the operator
# approved (the human gate is the real control; A7, incident 2026-06-06).
# Plus `environment:reaper-destroy` for the ttl-reaper's UNGATED auto-destroy
# (tag-guarded, re-verified in-job).
#
# Permissions = AdministratorAccess for now; the destroy-scoped policy
# (destroy-policy.tf, authored empirically from the 2026-06-12 teardowns) is
# staged for a staging-first validation before it replaces admin.
#
# SELF-DELETE NOTE (ADR-13): this role now lives in BOOTSTRAP local state, NOT
# in the platform state that destroy-platform tears down. destroy-platform runs
# AS this role and no longer manages it — so the role cannot delete itself
# mid-run. The infra-ops pre-destroy `state rm` for this role is therefore
# obsolete and removed; the self-delete hazard is structurally gone.
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

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        # infra-ops.yml destroy — gated by the `destroy` environment reviewer.
        "repo:${var.github_owner}/aegis-platform-aws:environment:destroy",
        # ttl-reaper auto-destroy — UNGATED but tag-guarded, re-verified in-job.
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

# ---- Role E: aegis-core CI -> ECR push --------------------------------------
# Mirrors the greeter_ci role. Trust pinned to the exact workflow file ref
# (job_workflow_ref) so the blast radius is tightest — a PR or fork branch
# on aegis-core CANNOT assume this role; only the release-staging-image.yml
# workflow running on refs/heads/main can. (trust comment from aegis-core
# release-staging-image.yml §"Trust scope".)
data "aws_iam_policy_document" "core_ci_trust" {
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

    # Pinned to the main ref — aegis-core's release-staging-image.yml only
    # runs on push to main, so the OIDC subject is the exact ref.
    # Tightest blast radius: a PR / fork branch on aegis-core cannot assume
    # this role.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_owner}/aegis-core:ref:refs/heads/main"]
    }
  }
}

data "aws_iam_policy_document" "core_ci_permissions" {
  # ECR auth token — account-level, cannot be resource-scoped.
  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # ECR push (+ the layer reads docker push performs) — scoped to the single
  # aegis-core repo ARN. ARN constructed from account + region + the fixed repo
  # name `aegis-core` (same name used by envs/platform/ecr.tf) — bootstrap has
  # zero upstream dependency on platform state.
  # ecr:DescribeImages is required because release-staging-image.yml calls
  # `aws ecr describe-images` to source the authoritative digest after push;
  # without it that step fails with AccessDeniedException (greeter#14 lesson).
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
    resources = ["arn:aws:ecr:${var.platform_region}:${data.aws_caller_identity.current.account_id}:repository/aegis-core"]
  }
}

resource "aws_iam_role" "core_ci" {
  name               = "github-actions-aegis-core-ecr"
  assume_role_policy = data.aws_iam_policy_document.core_ci_trust.json
}

resource "aws_iam_role_policy" "core_ci" {
  name   = "ecr-push"
  role   = aws_iam_role.core_ci.id
  policy = data.aws_iam_policy_document.core_ci_permissions.json
}

# ---- Role F: aegis-core CI -> S3 frontend sync + CloudFront invalidation ----
# Trust identical to Role E — pinned to refs/heads/main on aegis-core, but via
# the release-staging-frontend.yml workflow file. IAM does not enforce
# job_workflow_ref without an explicit condition; the sub pin to
# refs/heads/main is already the tightest usable scope at this layer (the
# additional job_workflow_ref check lives in the LZ trust policy per ldz #79).
data "aws_iam_policy_document" "core_frontend_trust" {
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
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_owner}/aegis-core:ref:refs/heads/main"]
    }
  }
}

data "aws_iam_policy_document" "core_frontend_permissions" {
  # S3 — frontend bundle sync. Scoped to the staging frontend bucket.
  # Bucket name is deterministic: `aegis-staging-frontend-<account_id>`.
  # Both the bucket ARN (for ListBucket) and the objects ARN (/*) are required:
  # ListBucket needs the bucket resource; PutObject/DeleteObject/GetObject need
  # the objects resource.
  statement {
    effect = "Allow"
    actions = [
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = ["arn:aws:s3:::aegis-staging-frontend-${data.aws_caller_identity.current.account_id}/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::aegis-staging-frontend-${data.aws_caller_identity.current.account_id}"]
  }

  # CloudFront cache invalidation. The distribution ID `E5PYHGEEZQ7M8` is a
  # staging singleton provisioned in the LZ; it does not have a clean Terraform
  # data-source path from this seed layer (which must have zero upstream
  # dependency). Scoping to `*` here and noting the id in the comment below is
  # the least-astonishing option: the policy only grants CreateInvalidation (not
  # UpdateDistribution or admin actions), so the blast radius of the wildcard is
  # bounded to "can flush any CloudFront cache in this account", which is
  # acceptable for a CI-push role.
  #
  # Distribution: E5PYHGEEZQ7M8 (aegis-staging-frontend; vars.FRONTEND_CLOUDFRONT_DISTRIBUTION_ID
  # in aegis-core's GH Variables). Tighten to
  # arn:aws:cloudfront::<account>:distribution/<id> once the distribution ARN
  # is available as a stable output from a shared layer this bootstrap can read.
  statement {
    effect    = "Allow"
    actions   = ["cloudfront:CreateInvalidation"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "core_frontend" {
  name               = "github-actions-aegis-core-frontend"
  assume_role_policy = data.aws_iam_policy_document.core_frontend_trust.json
}

resource "aws_iam_role_policy" "core_frontend" {
  name   = "s3-sync-and-cf-invalidate"
  role   = aws_iam_role.core_frontend.id
  policy = data.aws_iam_policy_document.core_frontend_permissions.json
}
