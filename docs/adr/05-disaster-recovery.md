# ADR-05: Disaster recovery

## Status

Accepted.

## Context

A DR story is credible only if its recovery time is *measured* and *attributed*.
"~15 minutes" is marketing — it invites "15 minutes of what?". And the recovery
target depends on what there is to recover.

## Decision

**RPO is not applicable — the greeter is stateless by design.** It holds no
persistent data; there is nothing to lose and nothing to restore. The metric a
stateful system fights for is trivially satisfied here, and that is the point
of the stateless architecture.

**The measured number is a *cold-rebuild* RTO** — the time to reconstruct the
region from zero (Terraform state + git), with no warm standby. Naming it
matters: a *failover* RTO and a *cold-rebuild* RTO are different numbers for
different failures.

The 2026-05-17 drill measured **11m 21s** (region down → greeter pods Ready):

| Phase | Measured |
|---|---|
| Terraform re-apply — VPC + EKS control plane + node group + addons + ArgoCD + Alloy + external-dns | 11m 3s |
| ArgoCD reconverge — greeter synced from git, pods Ready | 18 s |
| **Cold-rebuild RTO** | **11m 21s** |

Two honest caveats. The measurement stops at *pods Ready* — the public endpoint
(ALB target health + DNS propagation) settles a few minutes after, not
separately timed. And one drill is one sample: EKS control-plane provisioning
dominates the re-apply and is variable, so **~20-30 min stays the conservative
planning budget** — the drill simply observed the faster end. Evidence:
[`../evidence/DR_REPORT.md`](../evidence/DR_REPORT.md).

**The drill is a defined cycle.** `make destroy-region` tears down one region's
`regional` stack; `make regional-one` rebuilds it; ArgoCD reconciles the
workload from git. `platform` (Route 53, ECR images, Grafana dashboards) is
untouched. `scripts/dr/dr-drill.sh` sequences and times the phases and writes a
report to `docs/evidence/`. The full failure-mode matrix and procedure are in
[`dr-plan.md`](../dr-plan.md).

## Consequences

- The RTO number is defensible because it is measured and attributed: the
  Terraform re-apply (EKS control-plane provisioning dominates) is the
  bottleneck at 11m 3s, and the GitOps layer is negligible — ArgoCD reconverged
  in 18 s. The dominant cost is a fixed AWS provisioning time this repo cannot
  optimise.
- Cheaper failures recover faster and more automatically: a dead pod
  (Kubernetes, seconds), a dead node (managed node group, ~2-5 min), an
  impaired AZ (multi-AZ replicas absorb it). Only region loss needs the
  IaC + GitOps recovery path, so that is the drill scenario.
- The cold-rebuild RTO is the number that matters for the failure class
  redundancy *cannot* cover — operator error, or a bad change GitOps faithfully
  propagates to every region. Multi-region failover (deployed — two regions,
  external-dns latency records with evaluate-target-health) is a different,
  smaller number (~1-2 min) for the narrower failure of one region dying; the
  drill's surviving-region probe confirmed the survivor served 61/61 throughout.
- The drill proves the real claim: Terraform state + git are the source of
  truth; the workload converges from zero with no manual `kubectl`.
- Evidence is committed to git, not left in a live environment — the cluster is
  torn down after the demo and Grafana Cloud retains data only ~14 days, so a
  live link would be dead by the time a reviewer opens the submission.
