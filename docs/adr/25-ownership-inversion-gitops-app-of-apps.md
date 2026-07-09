# ADR-25: Ownership inversion — GitOps app-of-apps owns platform add-ons

## Status

**Accepted — decided by Bin via epic
[#167](https://github.com/BinHsu/aegis-platform-aws/issues/167) (2026-07-06/07);
recorded retroactively 2026-07-09.** Implemented in full: stages A1–A6 (issues
#173–#178) shipped as PRs #186, #180, #193, #192, #196, #197 — all merged. This
ADR and [ADR-26](26-local-e2e-harness-kind-golden-path.md) were both reserved by
the epic (its open-decision #10) before either file existed; ADR-27 already
notes the reservation. This record is the retroactive write-up epic #167 itself
called for.

## Context

Terraform's `helm_release` resources for platform add-ons (Alloy, Kyverno +
aegis-policies, Crossplane v2, Argo Rollouts, the ALB controller,
external-dns) made Terraform state the **owner** of in-cluster objects. Every
teardown then had to unwind that ownership by hand before `terraform destroy`
could proceed cleanly — the bespoke machinery in `infra-ops.yml`:

- a `state-rm` loop stripping Helm-owned resources out of TF state before
  delete,
- an SG reaper for security groups Helm/EKS leave behind,
- ALB and Route53 backstops cleaning up load balancers / hosted-zone records
  that outlive the Helm uninstall.

Recurring teardown failures (#151, #148, #146, #134, #111, #110, #102, #90,
#71, #68, #67, #66, #63, #60) were symptoms of one design choice, not
independent bugs: **Terraform owns things whose natural owner is GitOps.**
Kyverno's fail-closed admission webhook plus finalizer-bearing CRs had already
deadlocked `helm uninstall` during a live teardown (the 2026-06-06 billing
incident recorded in the `kyverno.tf` tombstone) — the clearest single proof
that the ownership mismatch was not theoretical.

## Decision

### Target end-state

- **Terraform owns**: the VPC, the EKS cluster, node groups, IRSA/Pod Identity
  roles, and a bootstrap ArgoCD install (chart + root `Application` seed
  only) — account infrastructure, not cluster state.
- **App-of-apps (ArgoCD) owns**: every add-on — Alloy, Kyverno/aegis-policies,
  Crossplane, Argo Rollouts, the ALB controller, external-dns — and the
  workload `ApplicationSet`, via `gitops/platform-addons/`.
- **Teardown collapses to**: `terraform destroy` on the VPC+EKS+bootstrap
  stack for an `ephemeral` cluster. No state-rm loop, no SG reaper, no
  ALB/Route53 backstop on that path. A thin `profile==full` backstop remains
  for long-lived clusters (A6).

### Facts bridge (epic decision #3) — the Terraform→GitOps values channel

Terraform writes a single in-cluster ArgoCD `cluster` Secret
(`aegis-cluster-local`, `terraform/modules/regional-stack/gitops-bootstrap.tf`)
carrying:

- **labels** — `argocd.argoproj.io/secret-type: cluster` (registers it with
  ArgoCD's `clusters` generator), `aegis.binhsu.org/observability`,
  `aegis.binhsu.org/profile` (A6) — Cluster/Matrix generator selectors match
  **labels**, not annotations, so every fan-out gate is a label;
- **annotations** — cluster name, region, account id, the same `profile`
  value as a human-readable copy, and (A6) `vpc-id` / `alb-role-arn` /
  `external-dns-role-arn` / `zone-name`, plus (A5) a `workloads` annotation
  carrying `jsonencode(local.workload_list_elements)`.

Platform-addon `ApplicationSet`s read the Secret with a `clusters` (or, for
the workload catalog, a `Matrix(clusters × list.elementsYaml)`) generator and
inject the facts into their templates, so the git manifests under
`gitops/platform-addons/` stay **cluster-agnostic** — no account IDs, role
ARNs, or cert ARNs land in the public repo.

**`registries.auto.tfvars.json` stays the source of truth** (epic decision
#4): Terraform still builds the per-workload element list from it plus AWS
resources (model bucket, per-region ACM cert, Cognito outputs) — A5 changed
only the delivery channel, from inline Helm-value interpolation to the facts
annotation, not who computes the catalog.

**Creds as a TF-written Secret referenced from git** (epic decision #4): the
`monitoring` namespace (privileged Pod Security Standard labels ArgoCD's
`CreateNamespace` cannot set) and the `grafana-cloud-credentials` Secret stay
Terraform-owned, values sourced from SSM at the regional-env layer. Git
references the Secret **by name** (`envFrom`) — no credential ever lands in
git.

### The A1–A6 staging

| Stage | Issue | PR | What moved to GitOps |
|---|---|---|---|
| A1 | #173 | #186 | GitOps scaffold (`root-app.yaml`, app-of-apps `directory.recurse`) + the facts bridge + Alloy/node-exporter/kube-state-metrics |
| A2 | #174 | #180 | Kyverno controller + aegis-policies — **pattern-setter** for A3–A6 |
| A3 | #175 | #193 | Crossplane v2 (core / definitions / providerconfig, three facts-gated `ApplicationSet`s); replaced the `time_sleep 300s` readiness hack with ArgoCD-native retry-until-Healthy |
| A4 | #176 | #192 | Argo Rollouts controller (a plain `Application` — the only add-on needing no account-bound values) |
| A5 | #177 | #196 | The workload `ApplicationSet` + `AppProject` — the values-passing crux; **Bin decided MIGRATE**, 2026-07-06 (issue comment) |
| A6 | #178 | #197 | Ephemeral-profile gating (ALB controller + external-dns, `profile=full` only) + teardown collapse |

### Tombstone convention

When a `helm_release` is deleted, its Terraform file is kept — not
removed — as a comment-only tombstone: what it used to hold, why it moved,
where each piece went (chart pin → Application `source.targetRevision`,
`set` blocks → `spec.source.helm.values`, `depends_on` → ArgoCD sync-waves),
what stayed in Terraform and why, and the one-command revert. See
`kyverno.tf`, `argo-rollouts.tf`, and `crossplane.tf` (partial — the
Pod-Identity role for the S3 provider stays live code, only the three
`helm_release`s tombstoned). `kyverno.tf`'s tombstone explicitly names itself
**"PATTERN FOR A3–A6"** — every later stage cites it as the shape to follow.

### What stays Terraform-owned, and why

- **IAM / IRSA / Pod Identity roles** (ALB controller, external-dns,
  Crossplane's S3 provider) — account infrastructure per the ADR-22
  Terraform↔Crossplane boundary; these are AWS-account-scoped, not
  cluster-scoped, and GitOps has no natural jurisdiction over an IAM trust
  policy.
- **VPC / EKS substrate** and node groups.
- **The bootstrap ArgoCD `helm_release` + facts/creds bridge + root-app
  seed** — Terraform must own enough to bootstrap ArgoCD's ownership of
  everything else; this is the one deliberate chicken-and-egg root, not an
  oversight.
- **The `monitoring` namespace** — its privileged PSS labels are outside what
  ArgoCD's `CreateNamespace` sync option can set.

### As-built refinements (where execution sharpened the epic text)

- **A6 — label, not just annotation.** Epic decision #6 named an annotation;
  the as-built profile gate is a **label** (`aegis.binhsu.org/profile`)
  because `clusters`/`Matrix` generator selectors match labels, following the
  A1 observability-gate idiom. The annotation is kept as the
  human-readable/greppable copy of the same value.
- **A6 — Route53 sweep left in `destroy-platform`, not stripped.** #178's
  text listed the Route53 orphan sweep among things the ephemeral path
  strips; as built, it physically lives in `destroy-platform` (not
  `destroy-region`) and is left in place — external-dns being full-gated
  makes it self-no-op on all-ephemeral accounts, so removing it would have
  broken cleanup for accounts that do run full clusters.
- **A3 — retry-until-Healthy beyond the ownership move.** Migrating
  Crossplane surfaced that the old `time_sleep.crossplane_providers_healthy`
  (300s, gating a CRD that only registers once `provider-family-aws` is
  Healthy) had no GitOps equivalent as a fixed sleep. ArgoCD's own
  exponential-backoff retry (limit 20, 3-minute cap) replaced it —
  condition-driven convergence, not a stopwatch.
- **A5 — `Matrix`, not a plain `Cluster` generator.** The workload catalog is
  per-cluster JSON on the facts Secret, not a static list, so the workload
  `ApplicationSet` reads `Matrix(clusters × list.elementsYaml)`. A5 also
  closed the ordering gap A4 had flagged: removing `helm_release.argo_rollouts`
  dropped the `depends_on` that hard-gated the Rollout CRD ahead of any
  `Rollout` sync, producing a transient `Rollout.argoproj.io "" not found` on
  cold bring-up. A5 restores the ordering by placing the workload
  `ApplicationSet` under the same app-of-apps root at a sync-wave after
  Argo Rollouts, plus a per-generated-Application retry backstop.

## Consequences

- Teardown for an `ephemeral` cluster is a plain `terraform destroy` on the
  VPC+EKS+bootstrap stack — the in-cluster `state rm` loop is removed
  **entirely**, on both profiles; the SG reaper, ALB backstop, and
  Route53 backstop for the ephemeral path are gone (A6).
- ArgoCD sync-wave ordering replaces Terraform `depends_on` as the mechanism
  that sequences dependent installs (CRDs before the resources that need
  them). A wave-ordering regression is now a GitOps bug, not a Terraform
  graph bug — a different debugging surface, not a smaller one.
- The facts-bridge annotation channel is now the **only** sanctioned path for
  an add-on to receive account/cluster-bound values; every future add-on
  migration must extend the Secret, not reach for a Helm `set` block (the
  `kyverno.tf` "PATTERN FOR A3–A6" note is the durable instruction).
- [ADR-26](26-local-e2e-harness-kind-golden-path.md)'s kind harness is this
  ADR's validation precondition: every A-stage PR cites a
  `scripts/e2e` assertion as its acceptance evidence, and each stage's real
  cluster acceptance criteria (documented per-PR) still needs a batched
  ephemeral-EKS run to close its tracking issue.
- One structural risk accepted: the facts Secret is now a single point where
  a missing or stale fact (e.g. a forgotten label on a hand-created cluster)
  silently starves an `ApplicationSet` generator of a match — the same class
  of "forgotten knob" risk ADR-24 names for the tier dial, at cluster scope
  instead of fleet scope.

## Relationship to prior ADRs

- **ADR-22** (Terraform↔Crossplane boundary v2): **upheld, not renegotiated.**
  Crossplane's S3-provider IAM (Pod Identity role/policy/association) stays
  Terraform-owned account infrastructure; this ADR moves only the Crossplane
  **chart** (core/definitions/providerconfig) to GitOps.
- **ADR-24** (fleet governance — no runtime-coupled hub): sibling scope, not
  overlapping. ADR-24 is a fleet/hub topology decision not yet triggered;
  this ADR is a single-cluster ownership boundary, implemented now. The two
  share a shape — ADR-24's "the hub governs, it does not gate runtime" is the
  same decoupling move as this ADR's "GitOps owns cluster state, Terraform
  owns account infrastructure and bootstraps GitOps' ownership of the rest."
- **[ADR-26](26-local-e2e-harness-kind-golden-path.md)** (local E2E harness):
  the validation mechanism this ADR's staged migration depends on — "B gates
  A" per the epic. Every A-stage's kind assertion is ADR-26's harness
  exercised against this ADR's GitOps delivery.
- **ADR-27** (node autoscaling): unrelated decision, same epic-adjacent
  numbering window — ADR-27's own Status section records that ADR-25/26 were
  reserved by epic #167 before this file existed.
- **Epic [#167](https://github.com/BinHsu/aegis-platform-aws/issues/167)**:
  the source decision record (ten numbered open decisions), executed via
  issues #173–#178 (A1–A6, this ADR) and #170–#172 (B1–B3, ADR-26).

## References

- Epic #167 — <https://github.com/BinHsu/aegis-platform-aws/issues/167>
- PRs: [#186](https://github.com/BinHsu/aegis-platform-aws/pull/186) (A1),
  [#180](https://github.com/BinHsu/aegis-platform-aws/pull/180) (A2),
  [#193](https://github.com/BinHsu/aegis-platform-aws/pull/193) (A3),
  [#192](https://github.com/BinHsu/aegis-platform-aws/pull/192) (A4),
  [#196](https://github.com/BinHsu/aegis-platform-aws/pull/196) (A5),
  [#197](https://github.com/BinHsu/aegis-platform-aws/pull/197) (A6)
- Prior teardown-failure issues this ADR resolves the root cause of: #151,
  #148, #146, #134, #111, #110, #102, #90, #71, #68, #67, #66, #63, #60
- [Argo CD — ApplicationSet Cluster generator](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Cluster/)
  and [Matrix generator](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Matrix/) —
  the facts-bridge fan-out mechanism.
- [Argo CD — sync waves](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/) —
  the `depends_on` replacement.
