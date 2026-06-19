# ADR-07: Workload self-ownership — application catalog & IAM out of the platform tier

## Status

Accepted (2026-05-22). **Partially superseded by [ADR-09](09-platform-as-product-xrd.md) (2026-05-28):** the core *workload self-ownership* decision is retained — the workload still owns its IAM declaration in its deploy repo. The *workload-facing CRD mechanism* shifts: deploy repos no longer declare `iam.services.k8s.aws/Role` directly; they declare a platform-defined XR (`WorkloadIdentity`), and an AWS-side Crossplane Composition wraps the same ACK implementation underneath. The "ACK because single-cloud" rejection of Crossplane in *Alternatives Considered* is reversed — not on multi-cloud grounds, but on platform-as-product API hygiene + developer autonomy grounds (see ADR-09 Context). The four-pack enforcement model is preserved unchanged.

## Context

[ADR-01](01-architecture-and-topology.md) drew the lifecycle line *inside* this
repo — `bootstrap` / `platform` / `regional` split by change cadence and blast
radius. [ADR-03](03-delivery-cicd-gitops.md) drew the repo line *outward* —
workload manifests live in their own deploy repos (`aegis-greeter-deploy`,
`aegis-core-deploy`), ArgoCD reconciles them, and the workload set is data
(`workloads.auto.tfvars.json`) iterated by `for_each` in
`terraform/modules/regional-stack/argocd.tf`. Same Conway's-law logic, one tier
outward.

This ADR draws the next line, one tier further out: the **platform / workload**
boundary. Two pieces of workload-scoped state still live in this repo, or in
the landing-zone tier below it:

1. **The application catalog** — `workloads.auto.tfvars.json` enumerates every
   workload ArgoCD knows about. Adding a workload is a one-line JSON change,
   but the change still lands as a PR *in the platform repo*. That keeps the
   platform team on the critical path for every onboard.
2. **Workload IAM** — `aegis-core-deploy`'s engine ServiceAccount carries a
   role-arn annotation pointing at `aegis-staging-aegis-engine` (trust subject
   `system:serviceaccount:aegis-core:aegis-core-engine`), but that role was
   **never actually provisioned** in `aegis-landing-zone-aws`'s Terraform — it
   is a dangling reference. The open question is whether the fabric tier should
   own per-workload IAM at all; today it owns neither a working role nor should.

Both arrangements work; both leak the workload upward. The same argument that
moved manifests into deploy repos applies here: the boundary should follow the
unit of ownership.

This boundary is the workload-tier end of a lineage the sibling repo already
recorded: **[ldz ADR-017](https://github.com/BinHsu/aegis-landing-zone-aws/blob/main/docs/decisions/017-platform-tier-extraction.md)**
descoped the landing zone to account-fabric-only and extracted the platform
tier into this repo. ldz ADR-017's own consequence — "per-workload IRSA roles
do not live in the landing zone; they are provisioned by the workload per
aegis-platform-aws ADR-07" — forward-references this ADR. This ADR is the
consumer-side half of that decision: the per-workload role the fabric does not
own is *created* in the workload's deploy repo (not migrated — there is no
working fabric role to migrate).

Timing matters. The platform tier and every regional stack are currently
destroyed (cost — only `bootstrap` + `platform` state survive between drills).
The migration cost of moving these resources today is the cost of editing two
files; the migration cost once a second workload is live on a steady-state
cluster is a careful coordinated re-provisioning of running IAM and ArgoCD
state. Greenfield is the cheap window.

## Decision

**Workload-scoped resources move out of the platform tier and the landing-zone
tier, into each workload's own deploy repo.** Two changes:

**Application catalog — `ApplicationSet` with an SCM-provider generator.** The
catalog stops being a JSON map in this repo and becomes a query: ArgoCD
discovers workloads by scanning GitHub for repositories tagged with the topic
`aegis-workload` and reading a conventional path (`argocd/application.yaml`)
from each. The `for_each var.workloads` block in
`terraform/modules/regional-stack/argocd.tf` is replaced with a single
`ApplicationSet` resource; `workloads.auto.tfvars.json` is deleted. Each
deploy repo declares its own `Application` CR — the cluster does not need to
be told what to reconcile.

**Workload IAM — AWS Controllers for Kubernetes (ACK).** The IAM IRSA role
moves from the landing-zone tier (Terraform) into the workload's own deploy
repo, declared as ACK CRDs (`Role` / `Policy` from `iam.services.k8s.aws`) at
a conventional path (e.g. `k8s/base/iam/`). The platform tier installs the
ACK IAM controller as a paved-road service, alongside ArgoCD, Alloy, the ALB
controller, and external-dns. The landing-zone tier's role narrows to OIDC
provider trust anchor only — it issues the IAM identity primitive; the
workload picks the trust subject. The `aegis-staging-aegis-engine` role the
engine ServiceAccount references was never actually provisioned in the landing
zone (a dangling role-arn annotation); ACK *creates* it in `aegis-core-deploy`
with the same trust subject, reconciling the dangling reference. Nothing is
destroyed in the landing-zone tier — there is no working role there to destroy.

## Enforcement is the safety floor — guardrails precede dev-ownership

Workload self-ownership is **not** an abstraction story; its safety floor is
**enforcement**. The reason a deploy repo can be handed to its owning team
without the platform team auditing every sync is that the platform mechanically
*cannot* let one workload harm another. Three automated guardrails — the
**enforcement three-pack** — are the MUST-HAVE precondition; a fourth,
non-automatable tier closes the residual gap:

1. **ArgoCD `AppProject` destination-allowlist + `ApplicationSet`
   namespace-derivation** — namespace-squatting defense. The `ApplicationSet`
   derives each `Application`'s destination namespace from the discovered repo
   (the `aegis-workload` topic + a conventional name), and the `AppProject`
   allowlists only that destination. A deploy repo physically cannot sync a
   manifest into another workload's namespace, even if it tries.
2. **Kyverno: ACK `Role` trust-subject must match its namespace** —
   cross-workload IAM-theft defense. A Kyverno policy rejects any ACK `Role`
   CRD whose trust subject does not name the same namespace the CRD lives in.
   `aegis-greeter`'s deploy repo cannot declare an IAM role that trusts
   `system:serviceaccount:aegis-core:...`.
3. **Org-level SCP `deny-iam-privilege-escalation`** ([ldz ADR-015](https://github.com/BinHsu/aegis-landing-zone-aws/blob/main/docs/decisions/015-permission-boundary-hardening.md),
   `management/scps`) — escalation ceiling. ADR-015 §A2 *rejected* per-role
   permission boundaries (a role can drop its own boundary) and put the wall at
   the SCP layer, which member-account roles cannot self-modify. The SCP denies
   IAM-mutating actions org-wide except an allow-list. **Consequence for this
   ADR: the ACK IAM controller role must join that allow-list** (a scoped
   carve-out, exactly like the existing `*-karpenter-controller` entry) or it
   cannot `iam:CreateRole` from the CRDs at all. The carve-out is what lets ACK
   work while the SCP still blocks escalation-to-Admin — see roll-forward step 4.
4. **Least-privilege review (non-automatable tier)** — in the current
   solo-operator model, the operator reviewing the ACK-CRD PR. This is the one
   tier no policy engine fully replaces; it catches "technically within the
   boundary but obviously wrong" intent.

**Guardrails are the PRECONDITION for dev-ownership, not a nice-to-have on top
of it.** Without them, the platform team must centrally own the deploy repos —
re-introducing the very onboarding bottleneck this ADR removes — because the
only thing standing between a careless deploy repo and a cross-workload incident
would be human review of every sync. With them, dev-team ownership is *safe* by
construction. Abstraction (a Crossplane XRD) and a portal (Backstage) do **not**
substitute for these guardrails — they sit *above* the enforcement floor and
are deferred (see ADR-08); the floor itself is non-negotiable.

## Ownership split by layer, not by repo

Ownership divides by **layer**, not cleanly by repository. The deploy repo
nominally belongs to the stream-aligned (workload) team, but its contents are
co-owned:

- **Dev owns intent.** The overlay values (replica counts, image tags,
  resource requests, env-specific config) and the *IAM intent* — which AWS
  permissions the workload declares it needs, expressed as ACK CRDs.
- **Platform owns base + policy + scaffold.** The Kustomize base, the Kyverno
  ClusterPolicies that bound what intent is admissible, the `ApplicationSet`
  that discovers the repo, and the scaffold/template the deploy repo is seeded
  from.

The repository boundary is therefore a *nominal* owner (the workload team) over
a *layered* substrate (platform-authored base + policy underneath
workload-authored intent). This is why "the deploy repo belongs to the workload
team" and "the platform still controls the floor" are both true at once.

## Team-ready, not team-active — the honest framing

At the current scale — one solo operator (plus an agent) — the same actor wears
the platform hat *and* the workload hat. The marquee benefit of this ADR
(self-service onboarding with zero platform-team PR) is therefore **latent, not
realized**: there is no second team to be unblocked, so "zero PR to
aegis-platform-aws" saves the operator a context switch, not a cross-team handoff.

The honest reason to adopt this now is **technical, not organizational**:

- a single unified control plane (everything reconciles through ArgoCD + ACK
  inside the cluster the workload already owns);
- GitOps-native (the deploy repo *is* the desired state; no second
  Terraform plane per workload);
- a single audit trail (one ArgoCD sync history + CloudTrail, not Terraform
  state plus ArgoCD);
- the least-privilege boundary holds uniformly across workloads.

The **organizational** payoff — true self-service, no platform bottleneck — is
realized only when teams actually split. This ADR builds the interface so that
day is a no-op rather than a migration. The system is **team-ready, not
team-active**, and saying so plainly is the honest framing: we are paying a
small structural cost now to make a future org split cheap, while collecting
real technical benefits in the meantime.

## Considered alternatives

- **Keep `workloads.auto.tfvars.json` + the existing IRSA role in landing-zone.**
  Rejected on Conway's-law consistency with ADR-01 + ADR-03. The same argument
  that put manifests in deploy repos puts the application catalog and IAM
  there too. Inconsistent boundaries leak responsibility upward.
- **Crossplane instead of ACK.** Crossplane's strength is multi-cloud
  abstraction over heterogeneous backends. This portfolio is single-cloud AWS;
  the abstraction layer would be pure cost. ACK is AWS-official, AWS-only, GA
  per service, and emits the same K8s-native CRD ergonomics — the right tool
  for the actual scope.
- **Per-deploy-repo Terraform for IAM** — i.e. each deploy repo runs its own
  `terraform apply` for its IAM role. Rejected on operational uniformity: the
  workload would then have two deploy planes (Terraform + ArgoCD), each with
  its own state, lock, and apply role. ACK CRDs reconcile inside the cluster
  the workload already owns; one declarative paradigm, one ArgoCD sync, one
  audit trail.

## Consequences

- Onboarding a new workload becomes self-service. Create the deploy repo, tag
  it with the GitHub topic `aegis-workload`, declare
  `argocd/application.yaml` and `k8s/base/iam/*.yaml`. Zero PR to
  `aegis-platform-aws`, zero PR to `aegis-landing-zone-aws`.
- The platform tier narrows to **paved-road provider**: EKS, the ArgoCD root
  + `ApplicationSet`, the ACK IAM controller, cert-manager, the ALB
  controller, the Alloy DaemonSet, the observability wiring. It stops being
  the workload catalog owner.
- The landing-zone tier narrows to **OIDC provider trust anchor only**. It
  issues the identity primitive; workload-specific trust subjects live with
  the workload.
- Trade-off: app teams own their IAM, which means more autonomy and more
  responsibility. The new gate is ACK-CRD PR review inside the deploy repo,
  with the platform team's Kyverno baseline (PSS `restricted`,
  least-privilege policy hygiene — see [ADR-06](06-security-and-runtime.md))
  enforcing the floor on what they can declare.
- A small reconciliation-loop cost: ACK runs as a controller in-cluster,
  consuming a small footprint; the `ApplicationSet` re-queries GitHub on a
  cadence. Both negligible at this scale.

## Roll-forward plan

This ADR is the commitment; the refactor lands as four follow-up PRs. The order
is **greeter-first** and deliberately bottom-up: the interface's concrete shape
emerges from a real consumer's real consumption, not from a god's-eye prediction
of every future workload's needs. **greeter** is the first proving consumer — it
is the simplest workload, already deployed, and exercises the full interface
(Application CR discovery + ACK-CRD IAM) end-to-end. We prove the interface on
greeter, *then* apply it to the more complex `aegis-core` engine, *then* tear
down the fabric's now-orphaned role.

1. **`aegis-platform-aws`** — install the ACK IAM controller in
   `modules/regional-stack`; replace `for_each var.workloads` with one
   `ApplicationSet` resource (+ the `AppProject` allowlist and Kyverno
   trust-subject policy from the enforcement three-pack); delete
   `workloads.auto.tfvars.json`. This lays down the skeleton the consumers prove.
2. **`aegis-greeter-deploy`** — the **first proving consumer**. Add
   `argocd/application.yaml` + the ACK CRDs for any workload-scoped IAM it needs;
   tag the repo with the `aegis-workload` GitHub topic. greeter's real
   consumption is what fixes the interface's concrete shape.
3. **`aegis-core-deploy`** — the **second consumer**, applying the now-proven
   interface to the engine: `argocd/application.yaml` +
   `k8s/base/iam/aegis-core-engine-role.yaml`, same `aegis-workload` topic.
4. **`aegis-landing-zone-aws`** — add the ACK IAM controller role to the
   `deny-iam-privilege-escalation` SCP allow-list (scoped carve-out, like the
   Karpenter entry) so ACK can provision workload roles; then reconcile the
   dangling `aegis-staging-aegis-engine` role-arn annotation (point the engine
   SA at the ACK-created role, or drop the annotation). There is no per-workload
   role here to destroy — the fabric keeps only the OIDC trust anchor + the
   org-level SCPs, completing the ldz ADR-017 descope from the workload side.
