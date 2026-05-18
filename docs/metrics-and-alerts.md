# Metrics & alerts catalog

The observability surface — every dashboard panel, every alert, every recording
rule — in one place. The source of truth is code: panels in
[`grafana/dashboards/greeter-overview.json`](../grafana/dashboards/greeter-overview.json),
alerts and recording rules in
[`terraform/envs/platform/grafana.tf`](../terraform/envs/platform/grafana.tf).
Design rationale is [ADR-04](adr/04-observability.md); runnable queries are in
[`runbooks/observability-queries.md`](runbooks/observability-queries.md).

## Dashboard — `aegis-greeter — overview` (11 panels)

A `region` template variable scopes the view; every panel query splits
`by (region)`, so each region shows as its own series.

| # | Panel | Shows | Source |
|---|---|---|---|
| 1 | Request rate | requests/s by route | recording rule `job:greeter_http_requests:rate5m` |
| 2 | 5xx error rate | 5xx ÷ total requests | recording rule `job:greeter_http_requests:rate5m` |
| 3 | Latency p95 / p99 | request-duration quantiles | recording rule `job:greeter_http_request_duration:rate5m` |
| 4 | In-flight requests | concurrent requests | `http_server_active_requests` (app OTel) |
| 5 | Personalized vs default greetings | greeting mix | `greeter_responses_total` (app OTel) |
| 6 | Pod readiness | ready vs desired replicas | `kube_deployment_status_replicas_ready` / `kube_deployment_spec_replicas` (kube-state-metrics) |
| 7 | Container memory vs limit | OOM headroom | `container_memory_working_set_bytes` (cAdvisor) ÷ `kube_pod_container_resource_limits` (kube-state-metrics) |
| 8 | Node CPU utilization | per-node CPU | `node_cpu_seconds_total` (node-exporter) |
| 9 | Node memory utilization | per-node memory | `node_memory_MemAvailable_bytes` / `node_memory_MemTotal_bytes` (node-exporter) |
| 10 | apiserver request rate | EKS control-plane requests/s by code | recording rule `cluster:apiserver_requests:rate5m` |
| 11 | apiserver error rate | apiserver 5xx ÷ total | recording rule `cluster:apiserver_requests:rate5m` |

Panels 1, 4, 5, 8, 10 are context / diagnostic panels — deliberately alert-free
(a rate or a mix has no natural page-worthy threshold).

## Alert rules (6)

Each alert links to its panel via `__dashboardUid__` / `__panelId__`, so Grafana
shows the alert state on the panel and offers a jump-to-panel link. Every alert
query groups `by (region)` — it fires per region, and the summary names the
region (`{{ $labels.region }}`), so an operator reads the failing region off
the page, not off a node IP.

| Alert rule group | Fires when | For | Severity | Panel |
|---|---|---|---|---|
| `five_xx_rate` | app 5xx ratio > 5% | 5 min | critical | 2 |
| `p95_latency` | request p95 latency > 1 s | 5 min | warning | 3 |
| `pod_ready` | greeter ready replicas < 1 | 1 min | critical | 6 |
| `memory_near_limit` | container memory > 90% of its limit | 5 min | warning | 7 |
| `node_memory_pressure` | node memory utilization > 85% | 5 min | warning | 9 |
| `apiserver_error_rate` | EKS apiserver 5xx ratio > 5% | 5 min | critical | 11 |

All six route to the `ops-email` contact point via the notification policy.

## Recording rules (3)

Single-source the PromQL shared between a panel and an alert — recorded at the
finest granularity any consumer needs, so the panel and the alert query one
definition instead of repeating the expression.

| Recorded metric | Recorded from | Consumed by |
|---|---|---|
| `job:greeter_http_requests:rate5m` | `sum by (region, http_route, http_response_status_code) (rate(http_server_request_duration_seconds_count{service_name="aegis-greeter"}[5m]))` | panels 1, 2; alert `five_xx_rate` |
| `job:greeter_http_request_duration:rate5m` | `sum by (region, le) (rate(http_server_request_duration_seconds_bucket{service_name="aegis-greeter"}[5m]))` | panel 3; alert `p95_latency` |
| `cluster:apiserver_requests:rate5m` | `sum by (region, code) (rate(apiserver_request_total[5m]))` | panels 10, 11; alert `apiserver_error_rate` |

## SLI / SLO

| SLI | SLO line | Surfaced by |
|---|---|---|
| request success rate | 5xx rate < 5% | alert `five_xx_rate`, panel 2 |
| request latency | p95 < 1 s | alert `p95_latency`, panel 3 |

The alert thresholds *are* the SLO line — breaching one pages. RTO / RPO targets
are in [`dr-plan.md`](dr-plan.md).

## Coverage discipline

Every metric sent to Grafana Cloud has a consumer — a panel or an alert — and an
Alloy keep-list enforces it (only metric names a panel or alert queries reach
`remote_write`; see [ADR-04](adr/04-observability.md)). Every page-worthy panel
has an alert. Context panels are alert-free on purpose.
