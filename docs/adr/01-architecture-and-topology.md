# ADR-01: Architecture & multi-region topology

## Status

Accepted.

## Context

Two requirements shape the topology. **R1** — one source of truth for which
regions are deployed: no shadow variable, no second declaration. **R2** —
adding the Nth region must be a data change, not a code-structure change: no
copied directories, no new HCL blocks. And the deployment must stay inside a
cost-bounded take-home budget — a full active-active multi-region build (N EKS
control planes, cross-region replication, latency-routed DNS) does not.

Separately, a single Terraform state for everything couples resources with very
different change cadences: a state-backend bucket (created once) versus an EKS
cluster (destroyed and rebuilt in every DR drill).

## Decision

**Region topology is data.** `regions.auto.tfvars.json` at the repo root holds
`platform_region` plus a `regions{}` map — each entry carrying `enabled`, CIDR,
and node sizing. JSON, not HCL, because both Terraform and `jq` parse it
natively; an `enabled` flag per region records which regions are live (JSON has
no comments). Both `eu-central-1` and `eu-west-1` are enabled and deployed;
flipping one `enabled` flag is the entire change to add or drop a region.

**Multi-region is realised by external orchestration**, not in-Terraform
iteration. Terraform's `provider for_each` would generate one provider alias
per region from the map — but it is a reserved-but-unimplemented feature with
no shipped release. Instead the `regional` environment handles exactly one
region per apply (single static provider); the Makefile and the GitHub Actions
matrix loop over the enabled regions and invoke `regional` once each, with a
per-region state key (`regional/<region>/terraform.tfstate`).

**Three root environments, split by lifecycle:**

| Env | State | Lifecycle | Holds |
|---|---|---|---|
| `bootstrap` | local | once, never again | the S3 state bucket — its own state cannot live in the bucket it creates |
| `platform` | remote | slow — survives a DR drill | Route 53, ECR, OIDC roles, Budget, SSM, Grafana dashboards, branch protection |
| `regional` | remote, per-region key | fast — the DR drill target | VPC + EKS + ArgoCD + Alloy, applied once per region |

## Consequences

- R1 + R2 both hold: adding a region is a one-line edit to the JSON; the loop
  picks it up. No `.tf` edit, no directory copy.
- External orchestration is **better than the `provider for_each` design**, not
  a workaround: per-region state gives per-region blast-radius isolation,
  parallel applies, canary rollout, and granular DR (destroy one region, leave
  others). The "single state for N regions" trade-off never arises.
- A DR drill destroys `regional` only; `platform` is untouched — the drill
  rebuilds the workload, not the world. Each environment has its own state and
  lock, so blast radii stay independent.
- Two regions are deployed, so a single region's loss is absorbed by the
  survivor — the 2026-05-17 DR drill verified this (ADR-05). What redundancy
  cannot absorb — a correlated failure, or operator error — is the cold-rebuild
  RTO's job. Adding or dropping a region stays a one-line data change.
- The orchestration logic lives in the Makefile + workflows, not in Terraform.
  Terragrunt would absorb it; deferred until cross-account or deeper DAG
  dependencies justify the tool.
