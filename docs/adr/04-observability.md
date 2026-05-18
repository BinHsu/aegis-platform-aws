# ADR-04: Observability

## Status

Accepted.

## Context

Two postures for v1 observability. **CloudWatch-native** — Fluent Bit +
Container Insights + CloudWatch dashboards/alarms; AWS-native, fewest moving
parts; the open stack a later "aspiration". **Open-observability** —
OpenTelemetry instrumentation + Grafana Alloy → Grafana Cloud (Mimir / Loki /
Tempo / Pyroscope) from day one. CloudWatch + X-Ray is not feature-parity with
the Grafana stack — it predates OpenTelemetry standardisation, with no
continuous profiling and weak cross-signal correlation.

## Decision

**Start at the open stack.** The app emits OpenTelemetry (metrics + traces) and
Pyroscope (profiles) to a node-local Grafana Alloy DaemonSet — reachable at
`$(NODE_IP):4317` because Alloy runs on the host network. Alloy also scrapes
node-exporter / kube-state-metrics / cAdvisor and the EKS apiserver, tails pod
logs, and forwards everything to Grafana Cloud. Dashboards, alert rules, and
recording rules are declared via the `grafana/grafana` Terraform provider — no
manual UI edits, so the DR drill reconstructs the observability surface from git.
CloudWatch is retained only as a side-effect surface — EKS control-plane logs
and ALB access logs, for audit/forensics, never dashboarded.

**The free tier is a hard constraint, and it shapes two rules:**

1. *Cardinality discipline* — the free tier caps active metric series (~10k).
   The raw node-exporter / cAdvisor / kube-state-metrics / apiserver endpoints
   exceed that combined, so an Alloy `keep`-relabel admits only the metric
   names the dashboards and alert rules actually query. The filter runs before
   `remote_write`, ahead of the metering point — recording rules cannot do
   this, they are post-ingest.
2. *Pull, not ingest, for AWS-layer metrics* — out-of-band infra health
   (EC2 status checks, ALB health) is surfaced through a Grafana CloudWatch
   datasource queried at render time, so those metrics never consume the
   series budget.

**Recording rules single-source the shared PromQL.** Each metric shared between
a dashboard panel and an alert is recorded once, at the finest granularity any
consumer needs; both query the recorded series. The expensive, drift-prone
expression is defined in one place.

## Consequences

- **Conversion-cost arbitrage** — building CloudWatch-native first then
  migrating would write the observability layer twice. Starting at the target
  posture avoids a throwaway implementation and a migration runbook.
- **Continuous profiling for free** (Pyroscope) and a **unified pane** —
  PromQL + LogQL + TraceQL + profiles in one Grafana, with trace↔metric
  exemplars.
- Coherence by construction: every metric sent has a consumer (a panel or an
  alert); every page-worthy panel has an alert; context panels are deliberately
  alert-free.
- **Trade-off** — an external SaaS dependency and reliance on free-tier limits.
  The AMP + AMG migration path keeps Alloy and the OTel SDK unchanged — only
  `remote_write` URLs flip. The CloudWatch datasource is a gated scaffold; in
  production the AWS-layer metrics would move to a curated `cloudwatch_exporter`
  push. Both documented in [`tradeoffs.md`](../tradeoffs.md).
- The DR drill gains a visible signal: a dashboard shows metrics drop,
  flatline, and recover as the region is destroyed and rebuilt.
