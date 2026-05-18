# SSE-at-rest with the AWS-managed SNS key. A customer-managed CMK is
# documented in docs/tradeoffs.md as production hardening — not take-home
# scope (extra key + key-policy management for a low-sensitivity budget
# alert topic).
#tfsec:ignore:aws-sns-topic-encryption-use-cmk
resource "aws_sns_topic" "budget_alerts" {
  name              = "aegis-stateless-budget-alerts"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "budget_alerts_email" {
  topic_arn = aws_sns_topic.budget_alerts.arn
  protocol  = "email"
  endpoint  = var.budget_alert_email
}

resource "aws_budgets_budget" "monthly" {
  name              = "aegis-stateless-monthly"
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
