# Grafana Cloud dashboards + alerts via the `grafana/grafana` TF provider.
# Manual UI edits are forbidden — the DR drill must reconstruct the entire
# observability surface from git. `terraform plan` post-apply must show zero
# diff if no manual edits leaked in.

# ---- data source lookup ---------------------------------------------------
# Grafana Cloud auto-provisions named data sources for the bundled backends.
# Convention: "grafanacloud-<stack>-prom" / "...-logs" / "...-traces" /
# "...-profiles". If the stack slug differs, adjust the names below.
data "grafana_data_source" "prometheus" {
  count = var.enable_observability ? 1 : 0
  name  = "grafanacloud-aegis-prom"
}

# ---- folder ---------------------------------------------------------------
resource "grafana_folder" "aegis_stateless" {
  count = var.enable_observability ? 1 : 0
  title = "aegis-platform-aws"
  uid   = "aegis-platform-aws"
}

# ---- dashboards -----------------------------------------------------------
resource "grafana_dashboard" "greeter_overview" {
  count  = var.enable_observability ? 1 : 0
  folder = grafana_folder.aegis_stateless[0].uid
  config_json = templatefile("${path.module}/../../../grafana/dashboards/greeter-overview.json", {
    prometheus_uid = data.grafana_data_source.prometheus[0].uid
  })
  overwrite = true
}

# Public-share link for the reviewer (no GC account required to view).
resource "grafana_dashboard_public" "greeter_overview" {
  count         = var.enable_observability ? 1 : 0
  dashboard_uid = grafana_dashboard.greeter_overview[0].uid
  is_enabled    = true
  share         = "public"
}

# ---- alert routing --------------------------------------------------------
resource "grafana_contact_point" "ops_email" {
  count = var.enable_observability ? 1 : 0
  name  = "ops-email"

  email {
    addresses = [var.budget_alert_email]
  }
}

resource "grafana_notification_policy" "main" {
  count           = var.enable_observability ? 1 : 0
  contact_point   = grafana_contact_point.ops_email[0].name
  group_by        = ["alertname", "grafana_folder"]
  group_wait      = "30s"
  group_interval  = "5m"
  repeat_interval = "4h"
}

# ---- recording rules ------------------------------------------------------
# Single-source the shared PromQL. Each recording rule records a base
# series at the finest granularity any consumer needs (every grouping
# label kept); the dashboard panels and the alert rules below query the
# recorded metric instead of repeating the rate()/histogram expression.
# The expensive part — the metric name, the rate window, the service
# filter — is defined once here. Consumers only filter/aggregate.
#
# Note: on first apply a recorded metric does not exist until the rule has
# evaluated once (interval_seconds), so panels/alerts that query it show
# no-data for ~1-2 minutes after a cold apply.

resource "grafana_rule_group" "rec_greeter_http_requests" {
  count            = var.enable_observability ? 1 : 0
  name             = "rec-greeter-http-requests"
  folder_uid       = grafana_folder.aegis_stateless[0].uid
  interval_seconds = 60

  rule {
    name = "job:greeter_http_requests:rate5m"

    data {
      ref_id         = "A"
      datasource_uid = data.grafana_data_source.prometheus[0].uid
      relative_time_range {
        from = 300
        to   = 0
      }
      model = jsonencode({
        editorMode = "code"
        expr       = "sum by (region, http_route, http_response_status_code) (rate(http_server_request_duration_seconds_count{service_name=\"aegis-greeter\"}[5m]))"
        intervalMs = 1000
        instant    = true
        refId      = "A"
      })
    }

    record {
      from                  = "A"
      metric                = "job:greeter_http_requests:rate5m"
      target_datasource_uid = data.grafana_data_source.prometheus[0].uid
    }
  }
}

resource "grafana_rule_group" "rec_greeter_http_request_duration" {
  count            = var.enable_observability ? 1 : 0
  name             = "rec-greeter-http-request-duration"
  folder_uid       = grafana_folder.aegis_stateless[0].uid
  interval_seconds = 60

  rule {
    name = "job:greeter_http_request_duration:rate5m"

    data {
      ref_id         = "A"
      datasource_uid = data.grafana_data_source.prometheus[0].uid
      relative_time_range {
        from = 300
        to   = 0
      }
      model = jsonencode({
        editorMode = "code"
        # Bucket rate keeps the `le` label — consumers run histogram_quantile
        # on the recorded series for whatever percentile they need.
        expr       = "sum by (region, le) (rate(http_server_request_duration_seconds_bucket{service_name=\"aegis-greeter\"}[5m]))"
        intervalMs = 1000
        instant    = true
        refId      = "A"
      })
    }

    record {
      from                  = "A"
      metric                = "job:greeter_http_request_duration:rate5m"
      target_datasource_uid = data.grafana_data_source.prometheus[0].uid
    }
  }
}

resource "grafana_rule_group" "rec_apiserver_requests" {
  count            = var.enable_observability ? 1 : 0
  name             = "rec-apiserver-requests"
  folder_uid       = grafana_folder.aegis_stateless[0].uid
  interval_seconds = 60

  rule {
    name = "cluster:apiserver_requests:rate5m"

    data {
      ref_id         = "A"
      datasource_uid = data.grafana_data_source.prometheus[0].uid
      relative_time_range {
        from = 300
        to   = 0
      }
      model = jsonencode({
        editorMode = "code"
        expr       = "sum by (region, code) (rate(apiserver_request_total[5m]))"
        intervalMs = 1000
        instant    = true
        refId      = "A"
      })
    }

    record {
      from                  = "A"
      metric                = "cluster:apiserver_requests:rate5m"
      target_datasource_uid = data.grafana_data_source.prometheus[0].uid
    }
  }
}

# ---- alert rules ----------------------------------------------------------
# One rule_group per alert keeps blast radius small (a single rule update
# doesn't touch unrelated groups). Each follows the same shape: a `data`
# block with the metric query (refId "A") — querying a recorded metric
# where one exists — and a `data` block with a threshold expression
# (refId "C") referencing "A".

resource "grafana_rule_group" "five_xx_rate" {
  count            = var.enable_observability ? 1 : 0
  name             = "5xx-rate"
  folder_uid       = grafana_folder.aegis_stateless[0].uid
  interval_seconds = 60

  rule {
    name           = "5xx rate > 5% over 5 min"
    for            = "5m"
    condition      = "C"
    no_data_state  = "NoData"
    exec_err_state = "Error"

    data {
      ref_id         = "A"
      datasource_uid = data.grafana_data_source.prometheus[0].uid
      relative_time_range {
        from = 300
        to   = 0
      }
      model = jsonencode({
        editorMode = "code"
        expr       = "sum by (region) (job:greeter_http_requests:rate5m{http_response_status_code=~\"5..\"}) / clamp_min(sum by (region) (job:greeter_http_requests:rate5m), 1e-9)"
        intervalMs = 1000
        instant    = true
        refId      = "A"
      })
    }

    data {
      ref_id         = "C"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 0
        to   = 0
      }
      model = jsonencode({
        type       = "threshold"
        refId      = "C"
        expression = "A"
        conditions = [{
          type      = "query"
          evaluator = { type = "gt", params = [0.05] }
          operator  = { type = "and" }
          query     = { params = ["A"] }
        }]
      })
    }

    # __dashboardUid__ / __panelId__ link this alert to its dashboard panel:
    # Grafana shows the alert state on the panel and offers a jump-to-panel
    # link from the alert. The query stays a separate copy — the link makes
    # any drift between alert and panel visible at a click.
    annotations = {
      summary          = "aegis-greeter 5xx rate exceeded 5% over 5 min in {{ $labels.region }}"
      __dashboardUid__ = grafana_dashboard.greeter_overview[0].uid
      __panelId__      = "2"
    }
    labels = {
      severity = "critical"
    }
  }
}

resource "grafana_rule_group" "p95_latency" {
  count            = var.enable_observability ? 1 : 0
  name             = "p95-latency"
  folder_uid       = grafana_folder.aegis_stateless[0].uid
  interval_seconds = 60

  rule {
    name           = "p95 latency > 1 s over 5 min"
    for            = "5m"
    condition      = "C"
    no_data_state  = "NoData"
    exec_err_state = "Error"

    data {
      ref_id         = "A"
      datasource_uid = data.grafana_data_source.prometheus[0].uid
      relative_time_range {
        from = 300
        to   = 0
      }
      model = jsonencode({
        editorMode = "code"
        expr       = "histogram_quantile(0.95, job:greeter_http_request_duration:rate5m)"
        intervalMs = 1000
        instant    = true
        refId      = "A"
      })
    }

    data {
      ref_id         = "C"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 0
        to   = 0
      }
      model = jsonencode({
        type       = "threshold"
        refId      = "C"
        expression = "A"
        conditions = [{
          type      = "query"
          evaluator = { type = "gt", params = [1.0] }
          operator  = { type = "and" }
          query     = { params = ["A"] }
        }]
      })
    }

    annotations = {
      summary          = "aegis-greeter p95 request latency exceeded 1 s over 5 min in {{ $labels.region }}"
      __dashboardUid__ = grafana_dashboard.greeter_overview[0].uid
      __panelId__      = "3"
    }
    labels = {
      severity = "warning"
    }
  }
}

resource "grafana_rule_group" "pod_ready" {
  count            = var.enable_observability ? 1 : 0
  name             = "pod-ready"
  folder_uid       = grafana_folder.aegis_stateless[0].uid
  interval_seconds = 60

  rule {
    name           = "aegis-greeter has no ready pods over 1 min"
    for            = "1m"
    condition      = "C"
    no_data_state  = "Alerting"
    exec_err_state = "Error"

    data {
      ref_id         = "A"
      datasource_uid = data.grafana_data_source.prometheus[0].uid
      relative_time_range {
        from = 60
        to   = 0
      }
      model = jsonencode({
        editorMode = "code"
        expr       = "sum by (region) (kube_deployment_status_replicas_ready{deployment=\"aegis-greeter\"})"
        intervalMs = 1000
        instant    = true
        refId      = "A"
      })
    }

    data {
      ref_id         = "C"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 0
        to   = 0
      }
      model = jsonencode({
        type       = "threshold"
        refId      = "C"
        expression = "A"
        conditions = [{
          type      = "query"
          evaluator = { type = "lt", params = [1] }
          operator  = { type = "and" }
          query     = { params = ["A"] }
        }]
      })
    }

    annotations = {
      summary          = "aegis-greeter Deployment has 0 ready pods in {{ $labels.region }}"
      __dashboardUid__ = grafana_dashboard.greeter_overview[0].uid
      __panelId__      = "6"
    }
    labels = {
      severity = "critical"
    }
  }
}

resource "grafana_rule_group" "memory_near_limit" {
  count            = var.enable_observability ? 1 : 0
  name             = "memory-near-limit"
  folder_uid       = grafana_folder.aegis_stateless[0].uid
  interval_seconds = 60

  rule {
    name           = "container memory > 90% of limit over 5 min"
    for            = "5m"
    condition      = "C"
    no_data_state  = "NoData"
    exec_err_state = "Error"

    data {
      ref_id         = "A"
      datasource_uid = data.grafana_data_source.prometheus[0].uid
      relative_time_range {
        from = 300
        to   = 0
      }
      model = jsonencode({
        editorMode = "code"
        expr       = "max by (region) (container_memory_working_set_bytes{pod=~\"aegis-greeter.*\"}) / max by (region) (kube_pod_container_resource_limits{pod=~\"aegis-greeter.*\",resource=\"memory\"})"
        intervalMs = 1000
        instant    = true
        refId      = "A"
      })
    }

    data {
      ref_id         = "C"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 0
        to   = 0
      }
      model = jsonencode({
        type       = "threshold"
        refId      = "C"
        expression = "A"
        conditions = [{
          type      = "query"
          evaluator = { type = "gt", params = [0.9] }
          operator  = { type = "and" }
          query     = { params = ["A"] }
        }]
      })
    }

    annotations = {
      summary          = "aegis-greeter container memory exceeded 90% of limit over 5 min in {{ $labels.region }} — OOMKill imminent"
      __dashboardUid__ = grafana_dashboard.greeter_overview[0].uid
      __panelId__      = "7"
    }
    labels = {
      severity = "warning"
    }
  }
}

resource "grafana_rule_group" "node_memory_pressure" {
  count            = var.enable_observability ? 1 : 0
  name             = "node-memory-pressure"
  folder_uid       = grafana_folder.aegis_stateless[0].uid
  interval_seconds = 60

  rule {
    name           = "node memory utilization > 85% over 5 min"
    for            = "5m"
    condition      = "C"
    no_data_state  = "NoData"
    exec_err_state = "Error"

    data {
      ref_id         = "A"
      datasource_uid = data.grafana_data_source.prometheus[0].uid
      relative_time_range {
        from = 300
        to   = 0
      }
      model = jsonencode({
        editorMode = "code"
        expr       = "max by (region) (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)"
        intervalMs = 1000
        instant    = true
        refId      = "A"
      })
    }

    data {
      ref_id         = "C"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 0
        to   = 0
      }
      model = jsonencode({
        type       = "threshold"
        refId      = "C"
        expression = "A"
        conditions = [{
          type      = "query"
          evaluator = { type = "gt", params = [0.85] }
          operator  = { type = "and" }
          query     = { params = ["A"] }
        }]
      })
    }

    annotations = {
      summary          = "an aegis-platform-aws node in {{ $labels.region }} exceeded 85% memory utilization over 5 min"
      __dashboardUid__ = grafana_dashboard.greeter_overview[0].uid
      __panelId__      = "9"
    }
    labels = {
      severity = "warning"
    }
  }
}

resource "grafana_rule_group" "apiserver_error_rate" {
  count            = var.enable_observability ? 1 : 0
  name             = "apiserver-error-rate"
  folder_uid       = grafana_folder.aegis_stateless[0].uid
  interval_seconds = 60

  rule {
    name           = "EKS apiserver 5xx rate > 5% over 5 min"
    for            = "5m"
    condition      = "C"
    no_data_state  = "NoData"
    exec_err_state = "Error"

    data {
      ref_id         = "A"
      datasource_uid = data.grafana_data_source.prometheus[0].uid
      relative_time_range {
        from = 300
        to   = 0
      }
      model = jsonencode({
        editorMode = "code"
        expr       = "sum by (region) (cluster:apiserver_requests:rate5m{code=~\"5..\"}) / clamp_min(sum by (region) (cluster:apiserver_requests:rate5m), 1e-9)"
        intervalMs = 1000
        instant    = true
        refId      = "A"
      })
    }

    data {
      ref_id         = "C"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 0
        to   = 0
      }
      model = jsonencode({
        type       = "threshold"
        refId      = "C"
        expression = "A"
        conditions = [{
          type      = "query"
          evaluator = { type = "gt", params = [0.05] }
          operator  = { type = "and" }
          query     = { params = ["A"] }
        }]
      })
    }

    annotations = {
      summary          = "EKS apiserver 5xx rate exceeded 5% over 5 min in {{ $labels.region }} — control-plane degradation"
      __dashboardUid__ = grafana_dashboard.greeter_overview[0].uid
      __panelId__      = "11"
    }
    labels = {
      severity = "critical"
    }
  }
}
