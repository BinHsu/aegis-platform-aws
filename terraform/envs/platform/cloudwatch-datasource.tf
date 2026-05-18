# Grafana CloudWatch data source — out-of-band infra health (Tier B).
#
# The in-cluster Alloy scrapes (node-exporter / cAdvisor / kube-state-
# metrics / apiserver) cover node, workload, and control-plane API health.
# They cannot see — and when the cluster is unhealthy, cannot report —
# the AWS-infrastructure layer: EC2 instance status checks, ALB target
# health + 5xx, the AWS/EKS namespace. This data source lets Grafana
# query CloudWatch for those signals at render time (pull). It is
# deliberately not a cloudwatch_exporter Deployment ingesting into Mimir —
# pulling keeps CloudWatch metrics off the free-tier active-series budget.
# See docs/tradeoffs.md #4.
#
# Gated off by default. Activating it needs a cross-account IAM trust to
# Grafana Cloud's AWS account: the operator reads the Grafana Cloud AWS
# account ID + external ID from the Grafana Cloud UI (Connections -> Add
# new connection -> CloudWatch -> set up via an IAM role), sets
# grafana_cloud_aws_account_id + grafana_cloud_external_id, and flips
# enable_cloudwatch_datasource = true.

data "aws_iam_policy_document" "grafana_cloudwatch_trust" {
  count = var.enable_cloudwatch_datasource ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.grafana_cloud_aws_account_id}:root"]
    }

    # The external ID defeats the confused-deputy problem — Grafana Cloud
    # must present the exact ID issued for this stack to assume the role.
    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [var.grafana_cloud_external_id]
    }
  }
}

# Read-only — the data source only queries CloudWatch and lists resources
# so the dimension pickers populate. No write actions.
data "aws_iam_policy_document" "grafana_cloudwatch_read" {
  count = var.enable_cloudwatch_datasource ? 1 : 0

  statement {
    sid    = "CloudWatchRead"
    effect = "Allow"
    actions = [
      "cloudwatch:ListMetrics",
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:DescribeAlarmsForMetric",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ResourceDiscovery"
    effect = "Allow"
    actions = [
      "tag:GetResources",
      "ec2:DescribeRegions",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus",
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetHealth",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "grafana_cloudwatch" {
  count = var.enable_cloudwatch_datasource ? 1 : 0

  name               = "aegis-stateless-grafana-cloudwatch"
  assume_role_policy = data.aws_iam_policy_document.grafana_cloudwatch_trust[0].json
}

resource "aws_iam_role_policy" "grafana_cloudwatch" {
  count = var.enable_cloudwatch_datasource ? 1 : 0

  name   = "cloudwatch-read"
  role   = aws_iam_role.grafana_cloudwatch[0].id
  policy = data.aws_iam_policy_document.grafana_cloudwatch_read[0].json
}

resource "grafana_data_source" "cloudwatch" {
  count = var.enable_cloudwatch_datasource ? 1 : 0

  type = "cloudwatch"
  name = "aegis-stateless-cloudwatch"

  # authType "grafana_assume_role" — Grafana Cloud's managed assume-role
  # provider: GC's backend (account grafana_cloud_aws_account_id) assumes
  # the role below, presenting grafana_cloud_external_id. The IAM role's
  # trust policy permits exactly that pair. defaultRegion is the
  # dashboard's default query region; queries can still target any region.
  json_data_encoded = jsonencode({
    defaultRegion = var.platform_region
    authType      = "grafana_assume_role"
    assumeRoleArn = aws_iam_role.grafana_cloudwatch[0].arn
    externalId    = var.grafana_cloud_external_id
  })
}

# CloudWatch dashboard — created with the data source so there is never a
# dangling datasource reference (both gated on the same flag).
resource "grafana_dashboard" "infra_cloudwatch" {
  count = var.enable_cloudwatch_datasource ? 1 : 0

  folder = grafana_folder.aegis_stateless.uid
  config_json = templatefile("${path.module}/../../../grafana/dashboards/infra-cloudwatch.json", {
    cloudwatch_uid = grafana_data_source.cloudwatch[0].uid
  })
  overwrite = true
}
