# A2: AWS Cost Anomaly Detection (incident 2026-06-06).
#
# Complements the budget alarm on a different axis. The budget catches TOTAL
# spend crossing a fixed threshold; anomaly detection (ML, daily) catches an
# unexpected SHAPE of spend — e.g. a sudden EKS extended-support line — and
# alerts on the individual anomaly's dollar impact, often before the monthly
# total trips. It is the L3 catch-all for cost the reaper does not know about.
#
# CE is a global service homed in us-east-1, hence the aliased provider.
# NOTE (verify on 6/12): Cost Anomaly Detection in a member account requires the
# management account to have enabled member-account Cost Explorer access; if it
# is not enabled, this apply fails here (the budget in budget.tf is unaffected —
# AWS Budgets works per-account regardless).

resource "aws_ce_anomaly_monitor" "services" {
  provider          = aws.us_east_1
  name              = "aegis-platform-aws-services"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

resource "aws_ce_anomaly_subscription" "alerts" {
  provider         = aws.us_east_1
  name             = "aegis-platform-aws-anomaly-alerts"
  frequency        = "IMMEDIATE" # per-anomaly email as soon as detected
  monitor_arn_list = [aws_ce_anomaly_monitor.services.arn]

  subscriber {
    type    = "EMAIL"
    address = var.budget_alert_email
  }

  # IMMEDIATE frequency must gate on the per-anomaly absolute dollar impact.
  # Alert when any single anomaly's total impact is >= $5 (catches an EKS
  # extended-support surge long before the monthly budget would trip).
  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = ["5"]
    }
  }
}
