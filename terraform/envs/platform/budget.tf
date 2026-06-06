# SSE-at-rest with the AWS-managed SNS key. A customer-managed CMK is
# documented in docs/tradeoffs.md as production hardening — not take-home
# scope (extra key + key-policy management for a low-sensitivity budget
# alert topic).
#tfsec:ignore:aws-sns-topic-encryption-use-cmk
resource "aws_sns_topic" "budget_alerts" {
  name              = "aegis-platform-aws-budget-alerts"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "budget_alerts_email" {
  topic_arn = aws_sns_topic.budget_alerts.arn
  protocol  = "email"
  endpoint  = var.budget_alert_email
}

resource "aws_budgets_budget" "monthly" {
  name              = "aegis-platform-aws-monthly"
  budget_type       = "COST"
  limit_amount      = tostring(var.budget_hard_amount_usd)
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2026-01-01_00:00"

  # Warn at 80% of the warn-amount (forecast).
  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = (var.budget_warn_amount_usd / var.budget_hard_amount_usd) * 100 * 0.8
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts.arn]
  }

  # Hard alarm at 100% of the hard-amount (actual).
  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts.arn]
  }
}

# ---- A9: Budget Action — MANUAL cost circuit-breaker (incident 2026-06-06) --
# Graduates the budget alarm from "notify" toward "act", but in MANUAL approval
# mode (operator decision 2026-06-06): on a 100%-actual breach AWS Budgets
# notifies + the action waits in "Requires approval" — it does NOT act until a
# human approves it on the Alert details page. Automatic mode was rejected: an
# auto-applied restriction in a billing account has too large a blast radius.
#
# When approved, it attaches a deny policy to the gh-tf-apply-platform deploy
# role, blocking creation of new expensive resources (EKS / EC2 / RDS / cache)
# until the action is reversed. Scope is deliberately the deploy role only — it
# stops new spend without touching already-running services. Reversible from the
# same Alert details page.

# The deny policy the action attaches on approval.
resource "aws_iam_policy" "cost_freeze" {
  name        = "aegis-platform-aws-cost-freeze"
  description = "Budget circuit-breaker: deny creation of new expensive resources. Attached to the deploy role by a MANUAL budget action on a breach; detach to lift."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "DenyExpensiveResourceCreation"
      Effect = "Deny"
      Action = [
        "eks:CreateCluster",
        "eks:CreateNodegroup",
        "ec2:RunInstances",
        "rds:CreateDBInstance",
        "rds:CreateDBCluster",
        "elasticache:CreateCacheCluster",
        "elasticache:CreateReplicationGroup",
      ]
      Resource = "*"
    }]
  })
}

# Execution role AWS Budgets assumes to apply the action.
data "aws_iam_policy_document" "budget_action_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "budget_action" {
  name               = "aegis-platform-aws-budget-action"
  description        = "Assumed by AWS Budgets to apply the cost-freeze policy to the deploy role on an approved budget action."
  assume_role_policy = data.aws_iam_policy_document.budget_action_assume.json
}

# Least-privilege: only attach/detach the one freeze policy on the one deploy role.
resource "aws_iam_role_policy" "budget_action" {
  name = "attach-cost-freeze"
  role = aws_iam_role.budget_action.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ManageFreezeOnDeployRole"
        Effect   = "Allow"
        Action   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:GetRole", "iam:ListAttachedRolePolicies"]
        Resource = aws_iam_role.infra_apply.arn
      },
      {
        Sid      = "ReadFreezePolicy"
        Effect   = "Allow"
        Action   = ["iam:GetPolicy", "iam:GetPolicyVersion"]
        Resource = aws_iam_policy.cost_freeze.arn
      },
    ]
  })
}

resource "aws_budgets_budget_action" "cost_freeze" {
  budget_name        = aws_budgets_budget.monthly.name
  action_type        = "APPLY_IAM_POLICY"
  approval_model     = "MANUAL" # operator approves on the Alert details page; never auto-acts
  notification_type  = "ACTUAL"
  execution_role_arn = aws_iam_role.budget_action.arn

  action_threshold {
    action_threshold_type  = "PERCENTAGE"
    action_threshold_value = 100
  }

  definition {
    iam_action_definition {
      policy_arn = aws_iam_policy.cost_freeze.arn
      roles      = [aws_iam_role.infra_apply.name]
    }
  }

  subscriber {
    address           = var.budget_alert_email
    subscription_type = "EMAIL"
  }
}
