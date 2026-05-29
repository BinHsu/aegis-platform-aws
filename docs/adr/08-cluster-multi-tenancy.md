<!-- session-close-review: abstraction-trigger — re-count workload archetypes; if ≥2 share a resource-combination shape and no XRD exists, evaluate abstracting. Cheap stand-in for agent cross-session context loss; superseded by Backstage template inheritance when that arrives. -->

# ADR-08: Cluster multi-tenancy — shared by default, dedicated by exception via a platform module

## Status

Accepted (2026-05-22). **Partially superseded by [ADR-09](09-platform-as-product-xrd.md) (2026-05-28):** the "deferred abstraction ladder" stance below reverses — a platform-defined XRD layer (`WorkloadIdentity`, with vocabulary extended on demand) lands now, not when `count(aegis-platform-<cloud>) > 1`, on platform-as-product reasoning. The **overlay-per-cloud** model named below as the multi-cloud fallback is demoted to a *per-resource* fallback for cases where an XR abstraction would be too leaky to design honestly. Cloud-invariance, previously aspirational here (deploy repos declared AWS-bound ACK CRDs), becomes actual under ADR-09 — deploy repos speak the platform XR vocabulary, vendor CRDs live only inside Compositions. The "abstraction-trigger" session-close marker at the top of this file is satisfied by ADR-09; future re-counts inform XRD vocabulary growth, not the trigger itself.

## Context

[ADR-07](07-workload-self-ownership.md) lets a workload onboard itself — its
own `Application` CR, its own IAM CRDs, no PR to the platform repo. That
answers *what a workload owns*. It does not answer *where a workload runs*.
The unstated default in this repo so far has been "share the per-region EKS
cluster `aegis-platform-aws-${region}`", but the default has never been written
down, and the escape hatch — what to do when a workload genuinely cannot
share — has never been named.

Two postures are easy to slide into without an explicit decision:

- *Cluster per service* — every workload gets its own EKS cluster. Strongest
  isolation; operationally untenable at N > 2 for a small team.
- *Self-service dedicated clusters with no template* — workloads that want
  their own cluster spin one up via their own Terraform. Sounds like
  autonomy; produces baseline drift (different K8s versions, missing
  policies, ad-hoc Karpenter configs) within one release.

The right answer is neither — a default with a named, paved escape hatch.

This decision sits on the same lineage as ADR-07: [ADR-01](01-architecture-and-topology.md)
drew the lifecycle / blast-radius line inside this repo, [ADR-03](03-delivery-cicd-gitops.md)
established per-cluster ArgoCD + deploy repos, and
[ldz ADR-017](https://github.com/BinHsu/aegis-aws-landing-zone/blob/main/docs/decisions/017-platform-tier-extraction.md)
descoped the landing zone to account-fabric-only so this platform tier owns the
cluster question outright. Where ADR-07 fixed *what a workload owns*, this ADR
fixes *where it runs* — and, more importantly below, the **contract** the
platform must hold constant no matter where it runs.

## Decision

**Default: workloads share the per-region cluster.** Isolation is per
namespace, not per cluster:

- **Namespace** per workload, named with the full repo prefix per Rule 11
  (`aegis-core`, `aegis-greeter`, …) — no bare `aegis-` namespace.
- **NetworkPolicy** default-deny on the namespace, with explicit allows for
  the traffic the workload actually needs.
- **RBAC** — ServiceAccount + Role/RoleBinding scoped to the namespace.
- **ResourceQuota + LimitRange** on the namespace, so one workload cannot
  starve another.
- **Kyverno ClusterPolicies** enforce the platform floor — PodSecurity
  Standard `restricted` (per [ADR-06](06-security-and-runtime.md)), no
  `hostPath`, no privileged pods, no PVC where stateless workloads claim
  none.

**First escape hatch — dedicated nodes, shared control plane.** When a
workload needs an instance type the default Karpenter NodePool does not
serve (GPU, ARM, a memory-optimised family), or its appetite is large
enough to risk starving others, the workload's deploy repo declares a
Karpenter `NodePool` + `EC2NodeClass`, and pods bind to it via
NodeSelector and Taint+Toleration. Same EKS control plane, dedicated EC2.
This covers the vast majority of "I need my own cluster" cases — which
usually mean "I need dedicated nodes".

**Second escape hatch — dedicated cluster via `modules/dedicated-cluster/`.**
When the control plane itself has to be separate (different K8s minor
version, compliance boundary, different VPC/CIDR topology), the platform
repo exposes a `modules/dedicated-cluster/` Terraform module. The workload's
deploy repo invokes the module from its own `terraform/cluster/main.tf`,
assuming a deploy-time role into the workload account. The module enforces
the platform baseline: PSS `restricted`, Karpenter, ACK, Kyverno, Alloy, the
ALB controller, cert-manager. The escape hatch is paved — explicit,
documented, audited via the module's own PR review process and semver
upgrades.

## Decision criteria

Stay on the shared cluster unless **one** of these is true:

| Trigger | Promote to |
|---|---|
| Instance type / GPU not on the default Karpenter NodePool | Dedicated NodePool |
| Workload's steady-state appetite ≥ ~30% of the cluster (starvation risk) | Dedicated NodePool |
| Hard latency SLO that cohabitation breaks | Dedicated NodePool |
| Different K8s minor version (legacy stuck on n-2) | Dedicated cluster |
| Compliance boundary forbids a shared control plane (PCI / HIPAA / FedRAMP) | Dedicated cluster |
| Different VPC topology required (private CIDR, peering layout) | Dedicated cluster |

A workload that promotes to a dedicated NodePool stays inside this repo's
ArgoCD and observability wiring. A workload that promotes to a dedicated
cluster runs its own `modules/dedicated-cluster/` apply, but inherits the
same baseline.

## The invariant contract — the same platform across isolation tiers

The escape hatches above are only safe if the platform exposes the **same
contract** across every isolation tier. If a dedicated cluster offered a
*different* interface than the shared cluster, dedicated-by-exception would
silently become a second platform — and platform-as-product would break, because
the workload now has to learn two systems and the platform team has to maintain
two. The thing held constant across tiers is not the *mechanism* (that shifts);
it is the **contract**.

The contract has five **dimensions** — these are coordinate axes for reasoning
about parity, *not* a prescriptive spec. Each dimension must read the same to a
workload regardless of which tier it runs in:

| Dimension | The invariant | What the workload sees the same |
|---|---|---|
| **(a) Cluster baseline** | One reusable module installs the controller set: ALB controller, external-dns, Karpenter, the ArgoCD agent, the observability agents. The shared cluster *consumes* this module; `modules/dedicated-cluster/` *composes the same* module. | Same controllers present, same versions, same defaults. |
| **(b) Observability** | Same OTel endpoint convention, same log format, same metric naming (`aegis_*` namespaces per Rule 11). | Telemetry lands in the same backends with the same shape. |
| **(c) Identity / IAM** | Same IRSA / Pod-Identity wiring and the same ACK pattern (workload declares `Role`/`Policy` CRDs; Kyverno enforces trust-subject↔namespace per ADR-07). | IAM is declared the same way; the org-level `deny-iam-privilege-escalation` SCP (ldz ADR-015) caps escalation the same way. |
| **(d) GitOps** | Same `ApplicationSet` reconcile model — discovery by `aegis-workload` topic, the same `AppProject` allowlist semantics. | The deploy repo's `Application` CR works unchanged. |
| **(e) Secrets / networking** | Same External Secrets convention; the same ingress / egress idioms (NetworkPolicy default-deny, ALB ingress class). | Secrets and traffic are wired the same way. |

**The mechanism shifts by tier; the invariant holds because of how it shifts:**

- **Shared cluster** — the workload's interface is a **CRD interface**: it
  declares namespace-scoped resources (Kustomize overlay, ACK CRDs, NetworkPolicy)
  and the already-installed baseline reconciles them.
- **Dedicated cluster** — the interface is **a Terraform module to *get* a
  cluster, THEN the same CRDs inside it**: the deploy repo invokes
  `modules/dedicated-cluster/`, which installs the *same baseline controllers*,
  after which the workload declares the *same* CRDs it would on the shared
  cluster.

The invariant holds **because the dedicated-cluster module installs the same
controllers** the shared cluster runs — dimension (a) is the load-bearing one;
(b)–(e) are guarantees that follow from a common baseline. A dedicated cluster
is therefore "the shared platform, with the control plane pulled out", not "a
different platform."

**Grounded in greeter, not predicted enclaves.** The concrete shape of this
contract comes bottom-up from greeter's real consumption (the first proving
consumer, per ADR-07), *not* from a god's-eye prediction of a future
`aegis-enclave`'s confidential-computing needs or an `aegis-statefulset`'s
volume needs. We fix the contract those future workloads will *consume*; we do
not pre-design their internals here (see the deferred forward-references below).

## Multi-cloud: the contract is the portability unit, not the code

The whole stack is **AWS-only today, and that is correct, not a gap.** The
useful question for multi-cloud readiness is *not* "is the Terraform
cloud-agnostic" (it cannot meaningfully be — provisioning EKS is intrinsically
AWS) but "**is this contract crisp enough that a second cloud's platform tier
could expose the same one**". The portability unit is the contract, not the
implementation. Three layers, three different answers:

- **Platform tier + landing zone — per-cloud by construction.** VPC, EKS, IRSA,
  ACK, the ALB controller, external-dns→Route 53, ECR, the OIDC provider, AWS
  Organizations + SCPs are all AWS-only. Multi-cloud does **not** mean making
  these cloud-agnostic; it means a *parallel* per-cloud tier
  (`aegis-platform-gcp`, …) that installs the same baseline (dimension (a)) and
  therefore exposes the same five-dimension contract. The mechanism shifts by
  cloud exactly as it shifts by isolation tier above; the contract holds. Even
  adopting Crossplane would not change this — you would write AWS-specific
  Crossplane resources instead of AWS-specific Terraform; only a hand-authored
  XRD Composition abstracts across clouds, and that is the deferred abstraction.
- **Workload deploy repos — mostly portable, with AWS-bound edges.** The core
  manifests (Deployment/Rollout/Service/HPA/NetworkPolicy) are conformant K8s.
  Only the *edges* are AWS-bound: the ALB `Ingress` annotations, the ACM cert
  ARN, the ACK `Role` CRD, and the IRSA annotation. The multi-cloud workload
  model is therefore **overlay-per-cloud inside one deploy repo**
  (`overlays/prod-aws`, `overlays/prod-gcp`), **not** a forked repo-per-cloud —
  the workload is the unit and its contract is cloud-invariant, so the deploy
  repo name carries no cloud suffix (unlike the per-cloud substrate tiers, which
  do). When a second cloud lands, the refactor is localised: extract the
  cloud-specific edge files (`ingress.yaml`, `iam/`) into a per-cloud overlay,
  and point that cloud's ApplicationSet at `overlays/prod-{{cloud}}`. This is a
  bottom-up refactor driven by the second cloud's real requirements, not a
  pre-built guess.
- **App repos — cloud-agnostic.** The container is portable; nothing to do.

The naming convention encodes this: **per-cloud substrate tiers carry a cloud
suffix (`aegis-platform-aws`, `aegis-landing-zone-aws`); workload-side repos
(app + deploy) do not**, because their contract is cloud-invariant. The single
biggest portability lever, if multi-cloud ever becomes a goal, is adopting
**Gateway API** for ingress (it decouples both deploy repos from EKS-specific
ALB annotations) — tracked in [`docs/tradeoffs.md`](../tradeoffs.md).

## Deferred abstraction ladder — enforcement before ergonomics before UX

The current control plane is **headless**: raw ACK CRDs + `ApplicationSet` + the
platform baseline + Kyverno, with no abstraction layer above the CRDs and no
portal UI in front of them. **This suffices today**, and it is the *right*
current form. Higher layers are deferred, each with a named trigger:

- **Crossplane XRD (the abstraction layer)** — triggers when **≥2 workloads
  share a repeated *resource-combination shape***. The trigger is a *shape
  match*, NOT a consumer count: greeter and core are both consumers, but they
  are structurally dissimilar (greeter is a thin stateless service; the core
  engine carries the model/inference resource shape). Two dissimilar consumers do
  not justify an XRD — abstracting now would invent a composite resource neither
  workload actually fits. **No trigger yet.**
- **Backstage / service-catalog (the portal layer)** — triggers at
  **navigation / discovery pain**: roughly 15–30+ services, multiple teams, OR
  operators who refuse to touch YAML. Note that a **"free catalog" already
  exists** with zero portal investment: the GitHub topic `aegis-workload` is the
  inventory, the ArgoCD dashboard is the live view, and the `ApplicationSet`
  enumerates what is reconciled. At the current handful-of-workloads scale that
  is sufficient discovery — **no portal needed now.**

The ordering principle is **enforcement (control plane) before ergonomics
(abstraction) before UX (portal)**. The enforcement three-pack from ADR-07 is
the floor and is already in place; abstraction and portal are conveniences that
ride on top, and adding them before their triggers fire would be building
ergonomics for users and shapes that do not yet exist. **A headless platform is
the correct current form**, not an unfinished one.

## Revisit triggers

Re-evaluate the "abstraction deferred" stance when **any** of these becomes true
— they are checkable, not vibes:

- **≥2 structurally-similar workloads** appear (two workloads that share a
  resource-combination shape, e.g. two stateless-service-plus-IAM-plus-ingress
  workloads, or two model-serving workloads) → evaluate a **Crossplane XRD** for
  the shared shape.
- **Heavy CRD-copy at onboarding** — a new workload's deploy repo is mostly
  copy-pasted ACK/Application/NetworkPolicy boilerplate from an existing one →
  the repeated shape is real; evaluate an XRD.
- **Operators complaining about YAML** — the people onboarding workloads push
  back on hand-writing CRDs, or non-platform operators need to onboard without
  touching YAML → that is the **portal (Backstage) trigger**, distinct from the
  XRD trigger above.
- **A second cloud goes live** — this is a *distinct* axis from the shape-based
  XRD trigger above. [ADR-07](07-workload-self-ownership.md) rejected Crossplane
  on the premise "single-cloud AWS → the multi-cloud abstraction is pure cost";
  a second cloud flips that premise, so it is a real revisit trigger. But the
  precise trigger is narrower than "multi-cloud" — it is the **conjunction**:
  (1) a second cloud is live, AND (2) we want to keep the ACK self-service model
  (workloads declare cloud resources as in-cluster CRDs), AND (3) ACK cannot
  serve it because ACK is AWS-only. Only then does Crossplane earn its place (it
  generalises the ACK pattern across clouds). "Two clouds, each managed by its
  own Terraform" does **not** trigger it — Terraform is already multi-cloud. See
  the multi-cloud section below.

The session-close-review marker at the top of this file is the cheap
cross-session stand-in for these triggers: re-count archetypes each session; if
≥2 share a shape and no XRD exists, this stance is due for re-evaluation.

## Deferred forward-references — anticipated future workloads

`aegis-enclave` (a confidential-computing / Nitro-Enclave isolation workload)
and `aegis-statefulset` (a persistent-volume / stateful workload) are
**anticipated but not yet unlocked**. They are named here only as **deferred
forward-references**: their *design* happens when they are actually unlocked, not
now. This ADR fixes the **interface they will consume** (the five-dimension
contract, the escape-hatch ladder) — it does not pre-design their internals.
When they land, they consume this contract; if they reveal a repeated shape with
an existing workload, they may *also* fire the XRD revisit trigger above.

## Considered alternatives

- **Cluster per service.** Rejected on operational cost. At five workloads
  across two regions that is ten clusters to patch, upgrade, scan, and
  observe. The control-plane overhead does not buy isolation the namespace
  + NetworkPolicy + Kyverno trio cannot give.
- **Cluster per team or domain.** Rejected on premature axis-split. This
  project has one operator; team boundaries are not real yet. Adding the
  axis now bakes in a structure the org does not have. Defer until team
  shape emerges and the cost of *not* splitting is visible.
- **App teams self-provision dedicated clusters via their own Terraform,
  without a platform module.** Rejected on baseline drift. Without the
  paved module, each dedicated cluster diverges — different K8s versions,
  missing Kyverno policies, ad-hoc Karpenter configs, missing Alloy
  wiring. The module is what makes the escape hatch safe.

## Consequences

- Default onboarding is namespace-only: no new AWS resources, no new
  cluster, no new control plane. The unit cost of the second, third, and
  fourth workload is a Kustomize overlay and a tagged deploy repo.
- The Karpenter NodePool tier absorbs the 90% case that gets misdiagnosed
  as "I need my own cluster" — almost always actually "I need dedicated
  nodes".
- `modules/dedicated-cluster/` is a paved-road artefact. Workloads that
  genuinely need a dedicated control plane do not get a wild-west DIY
  experience; they consume a hardened recipe and inherit baseline upgrades
  via module-version bumps.
- The platform team becomes a module author, not an infrastructure ticket
  queue. The module is the contract; the contract is versioned.
- Trade-off: shared-cluster failures are blast-radius-wide within a region.
  Multi-AZ replicas absorb pod / node / AZ failures; region loss is the
  cold-rebuild RTO path ([ADR-05](05-disaster-recovery.md)). A workload
  with a stricter blast-radius requirement promotes itself to a dedicated
  cluster — that is exactly what the escape hatch is for.
