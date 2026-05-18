# Cost model and FinOps

What this system costs to run, how the number is derived, and the strategy that
keeps it small. The short version: the cost lives entirely in the `regional`
stack, it is ephemeral, and it scales linearly per region.

Figures are approximate — `eu-central-1` / `eu-west-1` list prices as of
2026-05. Spot is market-priced and fluctuates; ALB LCU and data-transfer vary
with traffic. For a binding quote use the AWS Pricing Calculator.

## What one region costs

A `regional` stack is one VPC + one EKS cluster (`t3.medium` Spot node group,
floor of 2 nodes) + one ALB + one shared NAT gateway.

| Component | Rate | Note |
|---|---|---|
| EKS control plane | $0.10/hr | Fixed AWS price — not Spot-able, not negotiable. The irreducible floor; ~half the total. |
| 2× `t3.medium` nodes (Spot) | ~$0.03/hr | `capacity_type = SPOT` — ~65% off the ~$0.09/hr on-demand rate. |
| Application Load Balancer | ~$0.026/hr | Base hourly + LCU; hello-world traffic is ~1 LCU. |
| NAT gateway (1, shared) | ~$0.048/hr | `single_nat_gateway = true`. Per-AZ would be ~3×. |
| KMS + EBS + ECR storage | ~$0.006/hr | EKS-secrets KMS key, node EBS volumes, replicated image storage. |
| **Per region** | **≈ $0.21/hr** | |

## Reading the number across intervals

Cloud bills per hour — `$/hr` is the atomic unit. Everything else is derived:
monthly = hourly × **730** (the average hours in a month). Quoting a single
interval is misleading for ephemeral infrastructure, so all three are stated:

| Window | Per region | What it tells you |
|---|---|---|
| Per hour | **≈ $0.21** | The honest unit — runtime is the variable. |
| Per month, if left 24/7 | ≈ $150 | The ceiling — and the reason you do **not** leave it up. |
| Per DR drill (~6 hr) | ≈ $1.30 | The realistic cost of an actual use. |

The gap between **$1.30 a drill** and **$150 a month** is the whole FinOps
argument: it makes the teardown discipline a number, not a slogan.

## The platform env is effectively free

`platform` holds the Route 53 hosted zone ($0.50/mo), the ECR repository
(storage is cents — a distroless image is tens of MB), plus SSM Parameter
Store, GitHub OIDC providers, IAM roles, and AWS Budgets — all free or
free-tier. Total **≈ $0–1/month**. It is cheap enough to leave running.

## The strategy: ephemeral regional infra

The `regional` stack is the cost, so it is treated as ephemeral — stood up for
a demo or a DR drill, torn down when idle (`make destroy-region`).

The `bootstrap` / `platform` / `regional` lifecycle split is what makes this
safe. Tearing down `regional` never touches `platform`: ECR images, the
Route 53 zone, and the Grafana dashboards survive a teardown, so the rebuild is
just `make regional` — no re-push, no re-import. The split is described in
[ADR-02](adr/02-terraform-foundation.md); its FinOps payoff is that the
expensive layer is disposable while the stateful-but-cheap layer persists.

The AWS Budget (`$10` warn / `$25` hard, provisioned in `platform`) backstops a
forgotten teardown. The numbers are calibrated to this workflow, not to a
steady-state service: one region left running reaches the warn line in ~2 days
and the hard line in ~5, so a forgotten teardown pages well before it becomes
expensive.

## Cost scales linearly per region

Adding a region (the multi-region-as-data approach — [ADR-01](adr/01-architecture-and-topology.md)) adds
exactly one more `regional` stack: **+≈ $0.21/hr per region**. Two regions
≈ $0.42/hr. There is no shared regional infrastructure and no per-region
fixed overhead beyond the stack itself, so the cost curve is a straight line in
the region count.

## Levers pulled

| Lever | Saves | What it trades |
|---|---|---|
| Spot node group | ~$0.06/hr per region | Nodes can be reclaimed — acceptable for a stateless workload. |
| Single NAT gateway | ~2× NAT cost | A NAT-AZ failure takes egress for the other AZs. |
| Distroless image | ECR storage + faster pulls | — (also a security win: minimal CVE surface). |
| Grafana Cloud free tier | $0 observability | Free-tier active-series / ingest / retention caps. |
| GitHub Actions public runners | $0 CI | — |
| Bounded retention | Storage | GC 14-day, ALB-logs 7-day, EKS control-plane logs 30-day. |

This page states *how much* each lever saves. What each one trades away in
resilience — and the trigger that would justify reversing it — is in
[`tradeoffs.md`](tradeoffs.md).

## Where this goes next

The mature end of FinOps is **unit economics** — cost per request, per customer,
per transaction — so spend is read against business value, not in the abstract.
A hello-world greeter has no meaningful unit to divide by; the discipline here
is the right-sizing and the teardown habit. Unit-economics dashboards earn their
keep once the service carries real, billable traffic.
