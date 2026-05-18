# Architecture Decision Records

Six thematic records. Each consolidates one area of the architecture into a
single narrative — context, the decision, the consequences accepted — written
result-first: the final decision and why, not a log of the stages it passed
through. Format follows Michael Nygard's template (Status / Context / Decision /
Consequences).

Low-contention choices (Deployment over StatefulSet, EKS managed control plane,
ALB Ingress, Kustomize over Helm, HPA on CPU, …) live in code comments and
[`tradeoffs.md`](../tradeoffs.md), not as separate files — the ADR set stays
signal, not ceremony.

## The records

| ADR | Theme | What you'll find |
|---|---|---|
| [ADR-01](01-architecture-and-topology.md) | Architecture & multi-region topology | Region topology as data; `provider for_each` is unimplemented → external orchestration; the three-environment lifecycle split; two regions deployed. |
| [ADR-02](02-terraform-foundation.md) | Terraform foundation — state & toolchain | S3 native locking (`use_lockfile`) over a DynamoDB table; project-local pinned toolchain, reproducible for a forker. |
| [ADR-03](03-delivery-cicd-gitops.md) | Delivery — CI/CD & GitOps | CI-driven apply with the PR as the gate; two OIDC roles split trust; per-cluster ArgoCD over hub-spoke. |
| [ADR-04](04-observability.md) | Observability | OpenTelemetry + Alloy → Grafana Cloud; free-tier cardinality discipline (keep-list before `remote_write`); pull vs ingest; recording rules. |
| [ADR-05](05-disaster-recovery.md) | Disaster recovery | RPO N/A (stateless by design); a measured 11m 21s cold-rebuild RTO, attributed; the drill cycle + cross-region failover. |
| [ADR-06](06-security-and-runtime.md) | Security & runtime | IRSA, OIDC, EKS access entries, scoped deploy keys; PodSecurity `restricted`; secrets kept out of git. |

## Reading order by audience

**I want the architecture in 10 minutes** — the
[README architecture section](../../README.md#architecture), then ADR-01.

**Senior platform reviewer** — the order that builds the argument:
ADR-01 (topology — the signature design) → ADR-03 (how change reaches the
cluster) → ADR-05 (DR — the consequence that closes the loop) → ADR-04
(observability), then ADR-02 / ADR-06 as your specialism lands.

**Reliability / DR reviewer** — ADR-05 (DR) → ADR-01 (the lifecycle split that
bounds blast radius, and the multi-region failover posture) → ADR-03 (per-cluster
ArgoCD, no GitOps SPOF).

**Security reviewer** — ADR-06 (identity, runtime, secrets) → ADR-03 (the CI
trust split) → ADR-02 (pinned toolchain, state locking).

**Observability reviewer** — ADR-04, then the observability section of
[`tradeoffs.md`](../tradeoffs.md).
