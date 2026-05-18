# DR drill evidence

Artefacts from an actual DR drill run. A drill is a claim until it is
evidenced; this directory holds the proof, committed into git so a reviewer
sees it without a live environment.

## What lands here

| Artefact | Produced by | Backs the claim |
|---|---|---|
| `DR_REPORT.md` | `scripts/dr/dr-drill.sh` | The region rebuilt from IaC + git — phase timeline + the measured cold-rebuild RTO. |
| `dr-failover-probe-<timestamp>.log` | `scripts/dr/dr-drill.sh` | A 20-second health probe of the surviving region across the whole drill — the cross-region redundancy evidence. |
| `dns-failover.md` | a controlled failover test | Route 53 `evaluate_target_health` drops an unhealthy region's record — the DNS-layer failover cutover. |
| `grafana-dr-curve.png` | operator, captured during the drill window | The observability signal: pod-readiness and node metrics drop at teardown, flat through the rebuild, recover at reconverge. |
| `grafana-dr-multi-region.png` | operator, captured during the drill window | The per-region dashboard view — the drilled region drops to zero while the survivor holds flat. |

The raw phase-by-phase Terraform CLI log (`dr-drill-<timestamp>.log`) is **not**
committed — it carries account-specific ARNs, so it is gitignored and kept
operator-local. `DR_REPORT.md` is its curated, anonymisation-safe summary.

## Why screenshots, not links

The Grafana evidence is a committed PNG, not a live dashboard link. The drill
tears the cluster down; after the demo the whole stack is destroyed to stop
AWS billing, and Grafana Cloud's free tier retains metric data only ~14 days.
A live link would be dead by the time a reviewer opens the submission — so the
proof is captured in-window and committed here.

## Reproducing

```bash
scripts/dr/dr-drill.sh eu-central-1
```

See [`../dr-plan.md`](../dr-plan.md) for the plan, the failure-mode matrix, and
the RTO/RPO targets each artefact is measured against.
