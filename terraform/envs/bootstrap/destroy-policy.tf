# destroy-policy.tf — destroy-scoped IAM policy for gh-tf-destroy-platform
#
# Authored empirically from the 2026-06-12 live teardowns:
#   - prod destroy-region   run 27411285708 (~10:55–11:35 UTC, account 506221082337)
#   - prod destroy-region   re-run 27411632956 (~11:38–11:41 UTC, account 506221082337)
#   - staging destroy-platform run 27411285708 (~11:06–11:08 UTC, account 251774439261)
#   - prod destroy-platform run 27413438179 (~11:45 UTC, account 506221082337)
#
# CloudTrail evidence: 593 events observed in eu-central-1 (prod) + 65 in us-east-1 (prod)
# + 68 in eu-central-1 (staging) + 65 in us-east-1 (staging). Distinct action count per
# service: ec2=32, iam=15, s3=23, eks=12, kms=7, ecr=7, budgets=7, ce=5, sns=5, elasticloadbalancing=2,
# logs=3, route53=4, ssm=2, sts=1. Actions generalised to family-level wildcards so minor
# resource drift (new addon, extra tag API call) does not break teardown.
#
# S3 backend operations (GetObject/PutObject/DeleteObject/ListBucket on the tfstate bucket)
# are management-plane data events, not emitted to standard CloudTrail; added from static
# analysis of the backend.tf + use_lockfile=true (TF ≥ 1.11 S3 native locking, no DynamoDB).
#
# Per runbook A7: attach is DEFERRED to a follow-up cycle (staging-first validation).
# See the commented-out re-point block at the bottom of this file.
#
# RELOCATED to envs/bootstrap by ADR-13: this scoped policy lives alongside the
# gh-tf-destroy-platform role it targets (iam-seed.tf), both in the seed layer
# that survives teardown-to-zero. Keeping the policy in envs/platform would have
# coupled a bootstrap-owned role to a platform-owned policy that destroy-platform
# tears down — re-introducing the very lifecycle split on a single role that
# ADR-13 removes.

# --------------------------------------------------------------------------
# Scoped policy document
# --------------------------------------------------------------------------
data "aws_iam_policy_document" "infra_destroy_scoped" {
  # --- Terraform S3 backend: state read/write + native S3 lock (use_lockfile=true) ---
  # Bucket name pattern: aegis-platform-aws-tfstate-<account_id>
  statement {
    sid    = "TerraformBackendAccess"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:GetBucketVersioning",
    ]
    resources = [
      "arn:aws:s3:::aegis-platform-aws-tfstate-*",
      "arn:aws:s3:::aegis-platform-aws-tfstate-*/*",
    ]
  }

  # --- STS: caller identity (terraform init handshake) ---
  statement {
    sid       = "STSIdentity"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }

  # --- IAM: delete roles, policies, OIDC provider; read to plan/diff ---
  # Note: the role itself (gh-tf-destroy-platform) is state-rm'd before the
  # platform destroy runs, so self-delete is not a concern in practice.
  statement {
    sid    = "IAMDestroyScope"
    effect = "Allow"
    actions = [
      "iam:Delete*",
      "iam:Detach*",
      "iam:Get*",
      "iam:List*",
    ]
    resources = ["*"]
  }

  # --- Budgets: delete budget + action; read to read existing state ---
  statement {
    sid    = "BudgetsDestroyScope"
    effect = "Allow"
    actions = [
      "budgets:Delete*",
      "budgets:Describe*",
      "budgets:List*",
    ]
    resources = ["*"]
  }

  # --- Cost Explorer: delete anomaly monitor + subscription ---
  statement {
    sid    = "CEDestroyScope"
    effect = "Allow"
    actions = [
      "ce:Delete*",
      "ce:Get*",
      "ce:List*",
    ]
    resources = ["*"]
  }

  # --- Route 53: delete hosted zone; Get* / List* for plan refresh ---
  statement {
    sid    = "Route53DestroyScope"
    effect = "Allow"
    actions = [
      "route53:Delete*",
      "route53:Get*",
      "route53:List*",
    ]
    resources = ["*"]
  }

  # --- ECR: delete repository + lifecycle policy; PutReplicationConfiguration
  #     is needed to clear replication config before repository deletion ---
  statement {
    sid    = "ECRDestroyScope"
    effect = "Allow"
    actions = [
      "ecr:Delete*",
      "ecr:Describe*",
      "ecr:Get*",
      "ecr:List*",
      "ecr:PutReplicationConfiguration",
    ]
    resources = ["*"]
  }

  # --- S3 (application buckets): delete ALB access-log bucket + content;
  #     Get*/List* cover the bucket-attribute reads terraform does before deletion.
  #     DeleteObject*/AbortMultipartUpload are S3 data-plane events — absent from
  #     management CloudTrail, added from static analysis (CodeRabbit): force_destroy
  #     on a versioned/non-empty bucket (ALB access-logs) drains objects before
  #     DeleteBucket, requiring these permissions. ---
  statement {
    sid    = "S3DestroyScope"
    effect = "Allow"
    actions = [
      "s3:DeleteBucket",
      "s3:DeleteBucketEncryption",
      "s3:DeleteBucketLifecycle",
      "s3:DeleteBucketPolicy",
      "s3:DeleteBucketPublicAccessBlock",
      # S3 data events (not in management CloudTrail — added from static analysis):
      # force_destroy drains versioned objects before DeleteBucket.
      "s3:DeleteObject*",
      "s3:AbortMultipartUpload",
      "s3:Get*",
      "s3:List*",
      "s3:PutLifecycleConfiguration",
    ]
    resources = ["*"]
  }

  # --- SNS: delete topic + subscription; Get* for plan refresh ---
  statement {
    sid    = "SNSDestroyScope"
    effect = "Allow"
    actions = [
      "sns:Delete*",
      "sns:Get*",
      "sns:List*",
      "sns:Unsubscribe",
    ]
    resources = ["*"]
  }

  # --- SSM Parameter Store: delete Grafana Cloud creds; Get* for plan refresh ---
  statement {
    sid    = "SSMDestroyScope"
    effect = "Allow"
    actions = [
      "ssm:Delete*",
      "ssm:Get*",
    ]
    resources = ["*"]
  }

  # --- EC2: full VPC teardown (subnets, IGW, NAT GW, route tables, SGs,
  #     launch templates, EIP release, tag cleanup) ---
  statement {
    sid    = "EC2DestroyScope"
    effect = "Allow"
    actions = [
      "ec2:Delete*",
      "ec2:Describe*",
      "ec2:Detach*",
      "ec2:Disassociate*",
      "ec2:Release*",
      "ec2:Revoke*",
    ]
    resources = ["*"]
  }

  # --- EKS: delete cluster + nodegroup + addons + access entries;
  #     Describe*/List* for polling until deletion completes ---
  statement {
    sid    = "EKSDestroyScope"
    effect = "Allow"
    actions = [
      "eks:Delete*",
      "eks:Describe*",
      "eks:Disassociate*",
      "eks:List*",
    ]
    resources = ["*"]
  }

  # --- ELB v2: delete ALB (externally-created by EKS ingress controller) ---
  statement {
    sid    = "ELBDestroyScope"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:Delete*",
      "elasticloadbalancing:Describe*",
    ]
    resources = ["*"]
  }

  # --- KMS: schedule key deletion + delete alias; Get*/List*/Describe* for refresh ---
  statement {
    sid    = "KMSDestroyScope"
    effect = "Allow"
    actions = [
      "kms:DeleteAlias",
      "kms:Describe*",
      "kms:Get*",
      "kms:List*",
      "kms:ScheduleKeyDeletion",
    ]
    resources = ["*"]
  }

  # --- CloudWatch Logs: delete log group; Describe*/List* for plan refresh ---
  statement {
    sid    = "LogsDestroyScope"
    effect = "Allow"
    actions = [
      "logs:Delete*",
      "logs:Describe*",
      "logs:List*",
    ]
    resources = ["*"]
  }

  # --- Explicit Deny: prevent create/run actions that have no place in teardown ---
  # Focused on the highest-blast-radius classes; broad enough to block accidental
  # apply-style calls, narrow enough not to interfere with the read/delete paths above.
  statement {
    sid    = "DenyCreateRun"
    effect = "Deny"
    actions = [
      "iam:Create*",
      "iam:AttachRolePolicy",
      "iam:PassRole",
      "ec2:RunInstances",
      "ec2:CreateVpc",
      "ec2:CreateSubnet",
      "ec2:CreateInternetGateway",
      "ec2:CreateNatGateway",
      "ec2:CreateRouteTable",
      "ec2:CreateSecurityGroup",
      "eks:CreateCluster",
      "eks:CreateNodegroup",
      "eks:CreateAddon",
      "ecr:CreateRepository",
      "s3:CreateBucket",
      "rds:CreateDBInstance",
      "lambda:CreateFunction",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "infra_destroy_scoped" {
  name        = "gh-tf-destroy-platform-scoped"
  description = "Destroy-scoped policy for gh-tf-destroy-platform — allows observed Delete/Detach/Describe families; denies Create/Run classes. Authored empirically from 2026-06-12 live teardowns."
  policy      = data.aws_iam_policy_document.infra_destroy_scoped.json
}

# --------------------------------------------------------------------------
# TODO (next cycle): re-point the attachment from AdministratorAccess to this
# scoped policy, staged as staging-first validation.
#
# Validation plan before re-pointing:
#   1. Apply the scoped policy into the staging account (this file + existing
#      aws_iam_role_policy_attachment.infra_destroy_admin unchanged).
#   2. Dispatch a staging destroy-platform run. Confirm clean teardown with no
#      AccessDenied errors; if any surfaces, widen the relevant family wildcard
#      and iterate.
#   3. Once staging is clean, open a follow-up PR that swaps the attachment:
#
# resource "aws_iam_role_policy_attachment" "infra_destroy_admin" {
#   role       = aws_iam_role.infra_destroy.name
#   policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
# }
#
# becomes:
#
# resource "aws_iam_role_policy_attachment" "infra_destroy_scoped" {
#   role       = aws_iam_role.infra_destroy.name
#   policy_arn = aws_iam_policy.infra_destroy_scoped.arn
# }
#
# Self-delete interaction note (UPDATED by ADR-13): the gh-tf-destroy-platform
# role + its attachment now live in THIS bootstrap (local) state, not in the
# platform state that destroy-platform tears down. destroy-platform runs AS this
# role and no longer manages it, so there is nothing to state-rm — the
# self-delete hazard is structurally gone, and the obsolete pre-destroy state-rm
# was removed from infra-ops.yml. The scoped policy still grants iam:Delete*/
# iam:Detach* on * for the resources a real teardown deletes; it just never has
# to delete its own role.
# --------------------------------------------------------------------------
