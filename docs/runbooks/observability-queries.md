# Observability query runbook

Queries for the Grafana Cloud stack. Metrics are PromQL (Mimir), logs are LogQL
(Loki). All app signals carry `service_name="aegis-greeter"`; metrics also carry
`cluster` and `region` labels injected by Grafana Alloy.

## Golden signals (app)

```promql
# Request rate, by route
sum by (route) (rate(http_server_request_duration_seconds_count{service_name="aegis-greeter"}[5m]))

# 5xx error ratio
sum(rate(http_server_request_duration_seconds_count{service_name="aegis-greeter",http_response_status_code=~"5.."}[5m]))
  / clamp_min(sum(rate(http_server_request_duration_seconds_count{service_name="aegis-greeter"}[5m])), 1e-9)

# Latency p95 / p99
histogram_quantile(0.95, sum by (le) (rate(http_server_request_duration_seconds_bucket{service_name="aegis-greeter"}[5m])))
histogram_quantile(0.99, sum by (le) (rate(http_server_request_duration_seconds_bucket{service_name="aegis-greeter"}[5m])))

# In-flight requests
sum(http_server_active_requests{service_name="aegis-greeter"})

# Business metric — personalized vs default greetings
sum by (personalized) (rate(greeter_responses_total[5m]))
```

## Cluster / node (USE)

```promql
# Node memory pressure
(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / node_memory_MemTotal_bytes

# Ready greeter pods
sum(kube_deployment_status_replicas_ready{deployment="aegis-greeter"})

# Container memory vs limit (OOM risk)
max(container_memory_working_set_bytes{pod=~"aegis-greeter.*"})
  / max(kube_pod_container_resource_limits{pod=~"aegis-greeter.*",resource="memory"})
```

## Logs (LogQL)

```logql
# 5xx log lines in the last hour, by pod
sum by (pod) (count_over_time({app="aegis-greeter"} | json | level="ERROR" | status >= 500 [1h]))

# Error-rate spike detection (per minute)
sum (count_over_time({app="aegis-greeter"} | json | level="ERROR" [1m]))

# Pivot a log line to its trace — Grafana derives the Tempo link from trace_id
{app="aegis-greeter"} | json | trace_id != ""
```

## Where these run

- Dashboards + alert rules are declared in `terraform/envs/platform/grafana.tf`
  and `grafana/dashboards/` — applied by Terraform, never edited in the UI.
- The reviewer-facing dashboard is shared as a public Grafana link
  (`grafana_dashboard_public` output) — no Grafana Cloud account needed to view.
