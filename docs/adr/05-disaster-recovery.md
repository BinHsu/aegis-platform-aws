# ADR-05: Disaster recovery

## Status

Accepted.

## Context

A DR story is credible only if its recovery time is *named* and *attributed*.
"~15 minutes" is marketing — it invites "15 minutes of what?". And the recovery
target depends on what there is to recover.

## Decision

**RPO is not applicable — the greeter is stateless by design.** It holds no
persistent data; there is nothing to lose and nothing to restore. The metric a
stateful system fights for is trivially satisfied here, and that is the point
of the stateless architecture.

**The target is a *cold-rebuild* RTO** — the time to reconstruct a region from
zero (Terraform state + git), with no warm standby. Naming it matters: a
*failover* RTO and a *cold-rebuild* RTO are different numbers for different
failures.

The cold-rebuild budget is **~20–30 min**, region down → greeter pods Ready,
and it splits into two attributable parts:

| Phase | Cost | Why |
|---|---|---|
| Terraform re-apply — VPC + EKS control plane + node group + addons + ArgoCD + Alloy + external-dns | minutes, dominant | EKS managed control-plane provisioning is a fixed AWS cost this repo cannot optimise, and it is the variable bottleneck. |
| ArgoCD reconverge — workloads synced from their deploy repos, pods Ready | well under a minute | The GitOps layer is fast; reconciliation is not the bottleneck. |

Two honest caveats. The budget stops at *pods Ready* — the public endpoint (ALB
target health + DNS propagation) settles a few minutes after. And it is a
*planning budget*, not a measurement: `scripts/dr/dr-drill.sh` runs the cycle
and writes a timed report to `docs/evidence/`, which turns the budget into an
observed number for whatever region and day it is run on.

**The drill is a defined cycle.** `make destroy-region` tears down one region's
`regional` stack; `make regional-one` rebuilds it; ArgoCD reconciles the
workloads from git. `platform` (Route 53, ECR images, Grafana dashboards) is
untouched. The full failure-mode matrix and procedure are in
[`dr-plan.md`](../dr-plan.md).

## Consequences

- The RTO is defensible because it is attributed: the Terraform re-apply (EKS
  control-plane provisioning dominates) is the bottleneck, and the GitOps layer
  is negligible. The dominant cost is a fixed AWS provisioning time this repo
  cannot optimise.
- Cheaper failures recover faster and more automatically: a dead pod
  (Kubernetes, seconds), a dead node (managed node group, ~2–5 min), an
  impaired AZ (multi-AZ replicas absorb it). Only region loss needs the
  IaC + GitOps recovery path, so that is the drill scenario.
- The cold-rebuild RTO is the number that matters for the failure class
  redundancy *cannot* cover — operator error, or a bad change GitOps faithfully
  propagates to every region.
- Multi-region failover (external-dns latency records with
  evaluate-target-health) is a different, smaller number (~1–2 min) for the
  narrower failure of one region dying. The **capability is implemented** — a
  per-region stack, per-region model bucket, per-region ACM cert, and the
  latency + evaluate-target-health Route 53 annotations on the gateway Ingress
  (2026-06-18). It is **armed by an enable-flip**: `eu-west-1.enabled=true` in
  `regions.auto.tfvars.json` plus `eu-west-1` in `accounts.prod.enabled_regions`.
  Until that flip, prod runs single-region (`eu-central-1`) and the failover
  number is latent, not live. See `dr-plan.md` for the go-live checklist.
- The drill proves the real claim: Terraform state + git are the source of
  truth; the workload converges from zero with no manual `kubectl`. The report
  it writes is committed to git, not left in a torn-down environment.
