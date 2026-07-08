# ADR-24: Fleet governance — supersede "no hub" with "no runtime-coupled hub"

## Status

Accepted (2026-07-07, decided by Bin; drafted 2026-06-22, designed with Bin). **No code
ships in this ADR.** It records
a topology decision for the hybrid / fleet phase and the trigger conditions that
adopt it. It is **not** applied to the current two-cluster build — implementation is
deferred until a trigger below fires (see Consequences → Trigger conditions).

## Context

ADR-01 and ADR-03 chose a fully decentralized topology. Region is data
(`regions.auto.tfvars.json`), each region has its own Terraform state, and each EKS
cluster runs its own ArgoCD — no `ApplicationSet`, no `argocd cluster add`, no
cross-cluster RBAC. ADR-03 stated the reason directly: "hub-spoke would make the hub
a single point of failure and a cross-cluster blast radius," and its consequence
"No GitOps-layer SPOF." ADR-03 also flagged the revisit: "no single pane of glass
across clusters. At this scale a non-issue; a fleet of dozens would revisit it."

That choice is correct **at the current scale** — two clusters, one team,
Terraform-per-env, no fleet-wide compliance requirement. Three forces push past it:

1. **Hybrid intent.** The north-star goal is the same architecture running on AWS
   *and* on-prem. That needs a provider-neutral way to provision and govern clusters
   on heterogeneous substrate.
2. **CAPI brings a hub by definition.** The industry-standard answer to
   "provider-neutral, tiered, declarative cluster provisioning" is Cluster API (CAPI)
   + `ClusterClass` (CAPA for EKS, Sidero/Talos for on-prem). CAPI's model **is** a
   management cluster that holds the `Cluster` objects and reconciles workload
   clusters. Adopting CAPI for substrate is adopting a hub.
3. **A `critical` tier needs provable compliance.** "Is every cluster in the fleet
   compliant right now?" has no single answer under no-hub. Worse, a drifted or
   compromised edge can silently opt itself out of its own GitOps, and nothing outside
   notices. Attestation — proving fleet posture to an auditor — requires an external
   observer that a no-hub topology does not have.

The framing "hub vs no-hub" is a false binary. What ADR-03 actually protected was
**data-plane survival** — a region keeps serving when its peers, or any central
component, are gone. It expressed that protection bluntly as "no hub," which also
forecloses fleet governance, provable compliance, and provider-neutral provisioning —
things the hybrid/fleet ambition needs.

## Decision

**The hub governs; it does not gate runtime.** Supersede ADR-03's "no hub" with
**"no *runtime-coupled* hub."** The distinction is the whole decision.

### The constraint

- A governance / management hub **MAY** own:
  - **Fleet inventory + lifecycle** — CAPI `Cluster` objects; `kubectl get clusters`
    is the fleet truth, replacing "read N Terraform state files."
  - **Posture assertion + compliance roll-up** — an OCM/ACM-style `PolicySet` +
    `Placement`, or a GitOps source-of-truth, asserting tier posture from outside and
    rolling up compliance centrally.
  - **The tier→bundle mapping** — `tier: critical` expands to its policy / identity /
    observability bundle in one reviewed place.
- A governance hub **MUST NOT** sit on the data-plane critical path:
  - Workload clusters keep serving when the hub is unreachable.
  - Each cluster runs its **own** reconciler (Argo / Flux / Crossplane) that continues
    from last-known-good during a partition and re-syncs on reconnect.
  - Hub loss degrades **manageability and governance freshness**, never **availability**.
- The hub is **HA** (multi-replica, ideally multi-region). A total hub outage **freezes
  governance, not traffic** — an acceptable degradation, including for tactical-edge,
  where the edge holds last-known-good and re-asserts on reconnect.

This preserves ADR-03's real intent (data-plane survival, no correlated SPOF) and
unblocks what its blanket wording forbade.

### The realization — two planes plus an optional front door

| Plane | Owns | Standard tool | Tier expressed as |
|---|---|---|---|
| **Substrate** | provision the cluster (aws + on-prem) | CAPI + `ClusterClass` (CAPA / Sidero-Talos) | `ClusterClass` variant / variables |
| **Posture** | tiered security/policy/identity/observability config | GitOps (Argo/Flux) + Kyverno; OCM-style `PolicySet` on the hub when attestation is required | per-tier overlay / `PolicySet` + `Placement` selector |
| **Front door** *(optional)* | one `SecureCluster{environment, tier}` API | Kratix Promise or **thin** Crossplane XRD that **orchestrates** the two planes | a field on the XR |

- **Substrate:** CAPI/`ClusterClass` replaces Terraform-per-env as the fleet grows.
  Terraform keeps substrate where CAPI is not yet adopted, and keeps all stateful /
  data-bearing resources — the ADR-22 Terraform↔Crossplane boundary stands.
- **Posture:** today's per-cluster Argo + Kyverno is already the standard posture
  plane. Add an external assertion layer (OCM-style `PolicySet`, hub-pushed,
  per-cluster reconciled) only when provable compliance is a requirement.
- **Front door:** the single `SecureCluster` kind is realized as an orchestrator over
  CAPI + GitOps, **never** as a monolith that composes the ~70 resources directly. It
  is scale-gated — justified only at fleet / multi-team self-service scale.

## Consequences

### Maintenance benefits — every one is the same move: decoupling

Each benefit separates two things that change at different rates, carry different
blast radius, or demand different trust — so a change to one stops dragging the other.
That is what the abstraction buys: a stable interface that lets the often-changing
side move without disturbing the side that must stay stable.

1. **Intent ⊥ implementation (the tier dial).** Today "make this cluster critical" is
   an emergent property of scattered knobs (`require_digest_action`,
   `enable_observability`, default-deny, node sizing) an operator must remember to set
   consistently — a forgotten knob on a new region is silently non-critical until an
   unsigned image runs. After: `tier: critical` is one declared field; the mapping is
   authored and reviewed once. No loose knobs to forget.
2. **Posture lifecycle ⊥ substrate lifecycle (change cadence).** Today posture and
   substrate share one Terraform module, apply, and state — tightening one Kyverno
   policy across the fleet means N `terraform apply`s, each surfacing a full substrate
   plan and the risk of an unrelated change riding along. After: a policy change is one
   Git commit / `PolicySet` edit; the substrate plan never enters the picture.
3. **Auditor ⊥ audited (attestation).** Today compliance rests on each cluster
   honestly reporting on itself; a drifted edge goes unnoticed. After: the hub asserts
   posture from outside and rolls up compliance — the cluster cannot unilaterally opt
   out, and non-compliance shows up in one place.
4. **Contract ⊥ fulfillment (provider-neutral).** Today AWS posture is EKS/Terraform-
   specific; on-prem would be a separate, drifting toolchain. After: one
   `SecureCluster{environment, tier}` API, with the provider implementation selected
   behind it; adding a substrate is one variant, not a re-implementation.
5. **Provisioning ⊥ operation (fleet inventory).** Today standing up a cluster is a
   Terraform apply with its own state/lock; inventory is "read N state files." After:
   CAPI holds the `Cluster` objects; the fleet's desired state is declarative and
   continuously reconciled — provided the hub stays off the data-plane path.

The core decoupling underneath all five is **control-plane availability ⊥ data-plane
availability** — exactly what ADR-03 wanted, expressed correctly this time.

### The honest tax (decoupling is not free)

- More moving parts (hub, CAPI, OCM) to operate, patch, keep HA, back up, and upgrade.
- Indirection lengthens debugging — "why did this policy land?" now traverses
  orchestrator → composition → managed resource → object.
- Abstraction can hide coupling: a posture that quietly assumes a substrate feature
  looks decoupled but is not.
- A governance hub is a new trust boundary and a tempting blast-radius surface; the
  "governs-not-gates" rule and staged (canary-one-tier-then-the-rest) rollout bound it
  but do not erase it.

### Trigger conditions — adopt when one fires, not before

At the current two-cluster, single-team scale this is **premature**; adopting it now
would add operational surface for governance no one is asking to prove. Implement when:

- CAPI is adopted for provider-neutral substrate (the hub arrives by definition), **or**
- a fleet-wide compliance / attestation requirement appears (critical / defense tier), **or**
- cluster count outgrows hand-managed per-env state, **or**
- on-prem becomes a live, reconciling leg (the hybrid goal goes real).

Until then, the per-cluster topology of ADR-01 / ADR-03 stands unchanged.

## Relationship to prior ADRs

- **ADR-01 / ADR-03** (topology; per-cluster ArgoCD over hub-spoke): **amended**.
  "Per-cluster ArgoCD, no hub" becomes "per-cluster *reconcile*, no *runtime-coupled*
  hub." The data-plane-survival intent is preserved and made explicit; the blanket
  no-hub is narrowed to a no-runtime-coupling rule. ADR-03's own "a fleet of dozens
  would revisit it" is the revisit.
- **ADR-08** (multi-tenancy escape hatches; platform contract invariant across
  isolation tiers): the governance hub is the fleet-scale continuation of the same
  idea — one contract, many fulfillments.
- **ADR-16 / ADR-22** (provider-neutral injection; Terraform↔Crossplane boundary):
  **upheld**. CAPI/`ClusterClass` is the substrate-plane realization of
  provider-neutrality; Crossplane stays the workload-resource layer; stateful stays in
  Terraform.

## References

- [Cluster API — ClusterClass](https://cluster-api.sigs.k8s.io/tasks/experimental-features/cluster-class/) — provider-neutral, variable-driven cluster templating (the substrate-plane "tier").
- [Open Cluster Management — Policy / PolicySet](https://open-cluster-management.io/docs/getting-started/integration/policy-controllers/policy/) and [policy-collection](https://github.com/open-cluster-management-io/policy-collection) — hub-asserted, per-cluster-reconciled posture bundle with `Placement` tier selectors.
- [Kratix — Promises](https://docs.kratix.io/main/reference/promises/intro) and [Compound Promises](https://docs.kratix.io/main/guides/compound-promises) — platform API fulfilled by a pipeline; the closest analog to a `SecureCluster` front door, hub-pushed + per-cluster GitOps.
- [Argo CD — ApplicationSet cluster generator](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Cluster/) — the per-cluster-friendly posture fan-out.
- [Upbound platform-ref-aws](https://github.com/upbound/platform-ref-aws) — Crossplane reference platform; substrate-provisioning (L5), recorded as the path **not** taken for posture.
