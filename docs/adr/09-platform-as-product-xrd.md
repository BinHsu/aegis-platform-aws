# ADR-09: Platform-as-product XRD — developer-owned workloads, platform-owned vocabulary

## Status

**Accepted** — with a partial supersede (2026-05-28).

> The platform-as-product XRD principle is **live** (the WorkloadIdentity XRD is
> implemented in the regional-stack charts). **Partial supersede:** the
> *identity-specific* WorkloadIdentity→IAM composition described below is **superseded by
> ADR-21** (EKS Pod Identity now owns workload identity). ADR-09's default-ownership rule
> continues to govern **non-identity** workload cloud resources under **ADR-22**
> (Crossplane v2).

## Context

[ADR-07](07-workload-self-ownership.md) established workload self-ownership: each workload's IAM (and, by implication, other workload-scoped state) lives in its deploy repo as Kubernetes-native CRDs reconciled by in-cluster controllers — ACK IAM today. The decision rested on a four-layer enforcement model that bounds the blast radius of a workload-tier compromise to the workload's own namespace:

| Layer | Owner tier | Bounds |
|---|---|---|
| 1. Org SCP `deny-iam-privilege-escalation` + `ArnNotLike` carve-out for `aegis-platform-aws-ack-iam-*` | landing-zone | the **principal** allowed to create IAM is one named IRSA |
| 2. ACK controller's own policy scoped to `/aegis-workload/*` IAM path | platform | the **target** the carved-out principal may touch |
| 3. Kyverno ClusterPolicy `trust-subject` (`charts/aegis-policies`) | platform (admission) | the **trust subject** a workload's CRD-rendered role may claim |
| 4. Default-deny NetworkPolicy + namespace-scoped ServiceAccount | cluster baseline | **lateral movement** of the assumed role |

The four layers are functionally and tier-orthogonal: simultaneous compromise requires defeating four independently-owned controls. The worst case bounds to "an IAM role under `/aegis-workload/<namespace>/` trusting the workload's own deploy repo" — equivalent to direct deploy-repo compromise, no privilege escalation.

ADR-07 explicitly rejected Crossplane on two grounds: "single-cloud → abstraction is pure cost" and "ACK is AWS-official, AWS-only — the right tool for the actual scope."

[ADR-08](08-cluster-multi-tenancy.md) named *contract cloud-invariance* as the workload-tier property to defend across `aegis-platform-<cloud>` substrates, and proposed **overlay-per-cloud** (`overlays/prod-aws`, `overlays/prod-gcp`, ...) as the deploy-repo materialization mechanism when `count(aegis-platform-<cloud>) > 1`. ADR-08 also documented a "Deferred abstraction ladder": raw ACK CRDs + ApplicationSet + Kyverno today, with an XRD layer deferred until "≥2 workload archetypes share a resource-combination shape."

Two observations now reshape that posture.

### 1. ADR-07's "cloud-invariant" claim was aspirational, not actual

Deploy repos declare `iam.services.k8s.aws/Role` — an AWS-bound CRD. The cloud-invariance claim works only because `count(aegis-platform-<cloud>) == 1`. The first day a non-AWS substrate (`aegis-platform-ionos`, `aegis-platform-gcp`) lands, the claim breaks visibly: either the deploy repo grows cloud-aware overlays (ADR-08's named fallback), or its CRD layer must change to a cloud-neutral type. The current model defers that work to an unbounded future moment.

### 2. The developer / platform contract is platform-as-product, not gatekeeper-as-process

The workload team owns service + service-deploy autonomously. The platform team provides vocabulary and guardrails; its review duty is **structural** (the four-pack enforcement runs without per-PR review) and **advisory** (consultation on vocabulary changes), **not approval-gate over workload PRs**. Raw vendor CRDs in deploy repos cement two anti-properties of that contract:

- The workload-facing API is a vendor-coupled artifact. Workload PRs that touch IAM speak `iam.services.k8s.aws/v1alpha1` — a schema published by AWS Controllers for Kubernetes, not by the platform team. The deploy repo's API surface drifts every time ACK ships a new version.
- Deploy-repo cloud-invariance stays permanently aspirational. The promise in ADR-08 (workload repos do not carry a cloud suffix because their contract is cloud-invariant) cannot be tested while the only contract instance is AWS-bound.

Both observations point to the same conclusion: the abstraction trigger that ADR-08 deferred to "count > 1 + ≥2 archetypes" should fire on the platform-as-product reasoning alone, before either condition is observed.

## Decision

The deploy repo's workload-facing CRD layer is **platform-defined XRD**, not vendor CRDs. Initial vocabulary is minimal:

- **`WorkloadIdentity`** — supersedes direct ACK `Role` declaration. Encapsulates the service-account binding, the workload-scoped IAM role, and the trust subject (constrained to the workload's own deploy repo per the Kyverno admission rule). Per-namespace, declared by the workload team.

Further XR types (`WorkloadQueue`, `WorkloadBucket`, `WorkloadDatabaseCluster`, ...) are added **only on real workload demand**, not preemptively. Each new XR type is a single platform PR adding a shared capability; existing workloads are not migrated until they have a reason to use the new shape.

The platform tier defines XRDs; AWS-side Compositions implement them on top of ACK. The four-pack enforcement model is preserved unchanged — ACK still holds the IRSA, the `/aegis-workload/*` path scoping, the SCP carve-out, and the Kyverno trust-subject policy. The Composition is the implementation detail the workload never sees; the XR is the workload-facing API the platform team owns.

### Developer / platform contract

| Subject | Owns | Does not own / not required |
|---|---|---|
| **Developer (workload team)** | `aegis-<svc>` source, `aegis-<svc>-deploy` manifests, XR instance declarations in the deploy repo | XRD definitions, Compositions, enforcement (SCPs / Kyverno / NetworkPolicy), platform TF, landing-zone TF |
| **Platform engineer** | XRD vocabulary, Compositions (per-cloud backend mapping), enforcement layers, golden-path docs + examples | Review of individual workload XR instances (not gated); workload PR approval (not required) |

Platform's "review duty" is:

- **Structural** — the four-pack enforces correctness without per-PR review; the XR admission layer adds a fifth checkpoint at the workload-facing API.
- **Advisory** — XRD / Composition / enforcement PRs need platform review. Individual workload XR instances do not.

**Workload teams do not need a platform PR to add, change, or remove XR instances.** The cluster's admission layer and the cloud-side controllers enforce the boundary.

### Default ownership rule for workload AWS resources

Generalizing ADR-07 from IAM to all workload-scoped AWS resources:

**Default — declared by the workload's deploy repo as an XR instance.**

**Promote to platform tier only when one of these triggers fires:**

1. ≥2 consumers from different workloads.
2. Producers from ≥2 workloads writing to the same resource.
3. Lifecycle outlives any single workload (event sourcing, audit, registry).
4. Cross-account / cross-region access required.
5. Operational blast radius exceeds what a deploy-repo PR review can manage (RDS-class: failover, parameter groups, version upgrades, replicas).

**Tie-breaker for 1-producer + 1-consumer across two workloads:** the consumer owns the resource. The producer is granted access via the consumer's policy XR listing the producer's IRSA ARN as principal (cross-workload IAM grant).

**Promotion path** when a resource graduates from deploy-repo to platform:

1. Set `deletionPolicy: orphan` on the relevant CRD instance.
2. ArgoCD removes the XR (resource is unmanaged, still alive in AWS).
3. `terraform import` into platform TF with the same ARN.
4. Cross-workload IAM grants unchanged (ARN is stable).

The path is non-disruptive — no in-flight message loss for queues, no IAM role recreation, no consumer-side reconfiguration.

### Schema versioning

XRDs ship at `v1alpha1`. Breaking-change license is explicit; the schema is allowed to evolve as workload demand surfaces requirements the initial shape did not anticipate. Stabilization to `v1` is gated on either:

- At least one **second-cloud Composition** validating that the shape carries across substrates, or
- Six months of steady-state single-cloud production use with no breaking schema change.

Single-cloud-only stabilization is *not* the cheap path it appears: a `v1` XR locked before a second cloud is the most expensive form of premature commitment, because it forces the second-cloud Composition to either subset what the XR already promised or grow a parallel `v2`. The two-condition gate above is the cost of honest stabilization.

## Alternatives considered

- **Stay on raw ACK CRDs in deploy repos; introduce XRD only when `count(aegis-platform-<cloud>) > 1`.** Rejected: defers the design indefinitely; concentrates migration cost into a single multi-cloud transition; keeps the deploy-repo cloud-invariance promise permanently aspirational. The platform-as-product reasoning is independent of multi-cloud and already applies at `count == 1`.

- **Overlay-per-cloud in deploy repo (ADR-08's named fallback).** Demoted to a *per-resource* fallback for resource families where XR abstraction would be too leaky to design honestly (e.g., resources whose semantics differ deeply across clouds). Default direction is platform XRD; overlay is the named exit.

- **Custom platform operator instead of Crossplane.** Rejected: reinvents the Composition primitive for marginal benefit. Crossplane v1 Composition is the mature, well-understood implementation of this pattern. The cost of a custom operator (lifecycle, reconciliation correctness, status reporting) outweighs the gain of avoiding Crossplane's surface.

- **Crossplane Functions / KCL pipeline (v1.20+).** Deferred. Stay on the v1 Composition API + patch-and-transform DSL — meaning `apiextensions.crossplane.io/v1` with `mode: Pipeline` + `function-patch-and-transform` (the same DSL as the deprecated `mode: Resources`, on the non-deprecated rail). Smaller surface, fewer failure modes than `function-go-templating` or KCL. Re-evaluate when a Composition genuinely needs branching, loops, or dynamic field generation that `CombineFromComposite` + transforms cannot express.

- **Wait for multi-cloud reality before pivoting (the "design without validation" objection).** Acknowledged but rejected: a `v1alpha1` schema with an explicit breaking-change license absorbs the design-without-validation risk. The alternative (no abstraction at all until `count > 1`) defers learning indefinitely and pays the entire migration cost in one event.

## Consequences

- **Workload velocity increases.** Workload PRs land without platform PR cycles. The platform team is not in the critical path for workload changes; their bandwidth is freed for XRD vocabulary curation and Composition maintenance.

- **Platform team scope narrows and clarifies.** Vocabulary curation + Composition maintenance + enforcement. Not workload PR review. This is Conway's law applied: the team that owns the platform tier owns the platform-tier *contract*, not the consumer-tier *instances*.

- **Four-pack enforcement is preserved.** ACK still has the IRSA, the path scoping, the SCP carve-out, and the trust-subject policy. XR admission adds a fifth layer at the workload-facing API. Net safety model strictly improves.

- **Single-cloud-designed XR risks being the wrong abstraction.** Mitigation: minimal initial vocabulary (`WorkloadIdentity` only); `v1alpha1` with breaking-change license; expansion only on real workload demand; explicit acknowledgement in *Schema versioning* above that single-cloud stabilization is the most expensive form of commitment.

- **ADR-07 retains its core decision** (workload self-ownership) and forfeits its mechanism choice (raw ACK CRD as workload-facing API). The four-pack stays.

- **ADR-08's overlay-per-cloud is demoted to a per-resource fallback.** Cloud-invariance becomes actual: deploy repos speak platform XR vocabulary; vendor CRDs live only inside Compositions. The "Deferred abstraction ladder" section's "no abstraction layer ... suffices today" stance is reversed.

- **Crossplane is now in the dependency surface — but a narrow slice of it.** Crossplane core only; no Crossplane Provider packages (no `provider-aws` etc.) — Compositions render into ACK CRDs, ACK calls AWS. New failure modes are scoped to in-cluster composition behavior: Composition rendering errors, patch DSL mismatches, XRD/Composition version drift. AWS-side execution failure modes are unchanged (still ACK). No new AWS credentials introduced. Operational cost is further bounded by sticking to v1 Composition resources (not Functions / KCL pipeline).

## Implementation phases

1. **ADR landing — this PR.** `aegis-platform-aws/docs/adr/09-...`, with amendments to ADR-07 and ADR-08 status sections. No code changes; the platform tier remains dormant pending bootstrap.

2. **Crossplane install — core only.** A platform PR adds `terraform/modules/regional-stack/crossplane.tf`: the Crossplane core helm release and nothing else. Specifically **no `provider-aws` package, no `ProviderConfig`, no Crossplane-side IRSA, no sibling SCP carve-out, no four-pack replication.** Crossplane in this architecture is a pure Kubernetes-internal abstraction engine — it reconciles XRs into ACK CRDs and stops there; it never calls AWS, never holds AWS credentials, never touches IAM. The single AWS-side execution path remains ACK, which already owns the four-pack (org SCP carve-out for `aegis-platform-aws-ack-iam-*`, `/aegis-workload/*` path scoping, Kyverno trust-subject policy, default-deny NetworkPolicy). XR admission adds a fifth layer at the workload-facing API, enforced by Kyverno at the cluster's K8s API — also Kubernetes-internal, also without AWS credentials. The chain is: `WorkloadIdentity` (XR, deploy repo) → Crossplane Composition (renders) → `iam.services.k8s.aws/Role` (ACK CRD) → ACK IAM controller (its existing IRSA) → AWS IAM API.

3. **First XRD: `WorkloadIdentity`.** XRD + AWS Composition (uses ACK `Role` underneath); Kyverno ClusterPolicy extended to validate XR claims at admission (the workload-facing fifth layer).

4. **Migration of existing deploy repos.** `aegis-core-deploy/k8s/base/iam/aegis-core-engine-role.yaml` and the greeter equivalent move from `iam.services.k8s.aws/Role` to `WorkloadIdentity`. Migration is workload-PR-driven; deploy repos are not edited by the platform team.

5. **Vocabulary extension on demand.** When a workload genuinely needs a new XR (e.g., `WorkloadBucket` for a per-service S3 bucket), the platform team adds the XRD + Composition in one PR. The default ownership rule above governs whether a given resource is workload-XR or platform-TF.

## References

- [ADR-07](07-workload-self-ownership.md) — superseded in part; see status note there.
- [ADR-08](08-cluster-multi-tenancy.md) — overlay-per-cloud demoted; "deferred abstraction ladder" reversed; aspirational cloud-invariance becomes actual.
- landing-zone `docs/decisions/015-permission-boundary-hardening.md` — the SCP carve-out mechanism extended by ADR-09 implementation phase 2.
- landing-zone `docs/decisions/017-platform-tier-extraction.md` — the lineage anchor for workload self-ownership.
- landing-zone `docs/decisions/030-*` — OIDC `repository_id` pin (informs the trust-subject Kyverno rule).
- `terraform/modules/regional-stack/charts/aegis-policies/templates/clusterpolicy-trust-subject.yaml` — the cluster admission layer that gets extended to validate XR claims.
- `terraform/modules/regional-stack/irsa-ack-iam.tf` — the path-scoping policy preserved unchanged under Compositions.

## Amendment 2026-06-18 — fix B: ACK → Crossplane upjet provider-aws-iam

The original Phase 2 design rendered `WorkloadIdentity` into a namespaced ACK `iam.services.k8s.aws/v1alpha1/Role`. That failed at install: `WorkloadIdentity`'s XR is cluster-scoped, and a cluster-scoped XR composing a namespaced managed resource forces `spec.resourceRefs[].namespace` on the XR — a field the XR CRD schema rejects. The Composition never rendered.

Fix B replaces ACK with Crossplane's own upjet provider `provider-aws-iam`. Its `iam.aws.upbound.io/v1beta1/Role` managed resource is **cluster-scoped**, so the cluster-scoped XR composes it with no `resourceRefs[].namespace` and the schema error is gone. Proven live end-to-end 2026-06-18: the engine assumed its rendered `/aegis-workload/` role and pulled its model.

Consequences for the enforcement model:

- **Crossplane now holds AWS credentials.** The provider calls IAM and gets creds via IRSA, **reusing the existing `irsa-ack-iam.tf` role** — the role name keeps its `aegis-platform-aws-ack-iam-` prefix, so the fabric SCP carve-out still matches with no landing-zone change. The trust subject moves to `crossplane-system:provider-aws-iam` (the provider pod's stable SA, named by a DeploymentRuntimeConfig).
- **Reconcile reads broadened.** upjet observes a not-yet-existing role with `iam:GetRole` against the name-only ARN `role/<name>` (no path), which the path-scoped mutate statements do not cover. The read statement is broadened to `iam:Get*`/`iam:List*` on `*`; the mutating statements stay scoped to `/aegis-workload/*`.
- **ACK is removed** (`ack-iam.tf` deleted; the `ack-system` namespace and controller go with it).
- **On-prem is unchanged** — it stays SPIRE→MinIO-STS; this provider is AWS-only.
- **The provider-neutral seam is intact.** Workloads still declare the `WorkloadIdentity` XR; ACK-vs-upjet is a Composition implementation detail the workload never sees.
