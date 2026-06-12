# Architecture Decision Records

A set of thematic records. Each consolidates one area of the architecture into a
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
| [ADR-05](05-disaster-recovery.md) | Disaster recovery | RPO N/A (stateless by design); a ~20–30 min cold-rebuild RTO target, attributed; the drill cycle + cross-region failover. |
| [ADR-06](06-security-and-runtime.md) | Security & runtime | IRSA, OIDC, EKS access entries, scoped deploy keys; PodSecurity `restricted`; secrets kept out of git. |
| [ADR-07](07-workload-self-ownership.md) | Workload self-ownership | *Accepted.* Continues the boundary discipline of ADR-01 + ADR-03 (and ldz ADR-017): application catalog moves to `ApplicationSet` with an SCM-provider generator; workload IAM moves to ACK CRDs in each deploy repo; guardrails (AppProject, Kyverno trust-subject, org SCP) are the precondition. |
| [ADR-08](08-cluster-multi-tenancy.md) | Cluster multi-tenancy | *Accepted.* Shared cluster by default (namespace + NetworkPolicy + Kyverno); dedicated Karpenter NodePool as first escape hatch; dedicated cluster via a paved `modules/dedicated-cluster/` as second; the platform contract is invariant across isolation tiers. |
| [ADR-10](10-release-model-build-once-promote-by-digest.md) | Release model — build once, promote by digest | *Accepted.* Image built once → immutable digest; one shared registry in a dedicated `aegis-deployment` (Deployments OU) account; promote by copying the staging-verified digest into the prod overlay, gated by a `prod` Environment; env differences live in config, not the artifact; Kyverno enforces digest pins. |
| [ADR-11](11-account-dimension-single-source-of-truth.md) | Account dimension — single source of truth | *Accepted.* The account dimension lives in git (`accounts.json`: account ids, env names, enabled regions, overrides, pins, `bootstrap_complete`); secrets hold only credentials-shaped values; role + bucket names derive from `account_id`. Records the gating decisions: prod always under `prod-apply-gated`, version gate hard-fails prod, reaper auto-destroy = ungated `reaper-destroy` env + in-job tag re-verification. |
| [ADR-12](12-registry-injection-vs-digest-pin-field-ownership.md) | Registry injection vs digest pin — field ownership | *Accepted.* `kustomize.images` belongs exclusively to the deploy repo (the digest pin); the platform injects the registry as the `aegis.binhsu.org/ecr-repository` annotation (same channel as region). Rationale: a newName-only images override empirically wipes the overlay's digest entry → `:latest` → ImagePullBackOff. |
| [ADR-13](13-ci-iam-roles-survive-teardown.md) | CI IAM roles seeded in the cold-start layer | *Accepted (operator 2026-06-12).* The four CI roles (apply / destroy / plan / greeter-push) + OIDC trust move from `envs/platform` to `envs/bootstrap` (LOCAL state, operator-seeded), structurally removing the destroy-role self-delete hazard, the orphan `EntityAlreadyExists`, and the post-teardown cold-start chicken-egg observed 2026-06-12. Teardown-to-zero stays **full** (roles not exempt; only the state bucket keeps `prevent_destroy`); what changes is the cold-start contract — one operator command (`make bootstrap`) re-seeds bucket + roles from true zero, idempotent whether the roles exist or were deleted (no import). |
| [ADR-14](14-multi-image-atomic-promotion.md) | Multi-image atomic promotion | *Proposed.* Extends ADR-10 to `aegis-core`'s two images (gateway + engine, one `aegis-core` ECR repo by tag prefix). Two digest pins in the overlay, both bumped in one PR — the atomicity unit is the git commit (greeter ×2); seed Job derives the engine pin. Keep one repo per workload (not two); `validate.yml` asserts both digests move together or neither (guards `gateway-D_new`/`engine-D_old` skew); rollback = revert the one promotion commit. WS1 migrates core CI from mutable tags to digest pins, staged after the PR+auto-merge port. |
| [ADR-15](15-frontend-environment-promotion.md) | Frontend environment promotion | *Proposed.* Extends ADR-10 to the non-OCI artifact class (Vite React SPA, S3 + CloudFront). "The digest" = an immutable git-SHA release prefix `s3://<bucket>/releases/<sha>/`; promotion = repoint prod's CloudFront origin-path/KeyValueStore pointer (git-tracked, PR-gated) at the same prefix staging verified; rollback = repoint; invalidation drops `/*` → `/index.html`. Resolves the baked-env blocker: target = runtime `/config.json` (true build-once), WS1 interim = per-env rebuild promoting the git SHA (zero frontend change). |

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
