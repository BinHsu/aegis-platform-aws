# ADR-07: Workload self-ownership — application catalog & IAM out of the platform tier

## Status

Proposed.

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
2. **Workload IAM** — the engine's IRSA role
   (`aegis-staging-aegis-engine`, trust subject
   `system:serviceaccount:aegis-core:aegis-core-engine`) is declared in
   `aegis-aws-landing-zone`. The account-fabric tier owns a per-workload trust
   policy, which means a workload's identity scope is a cross-repo change.

Both arrangements work; both leak the workload upward. The same argument that
moved manifests into deploy repos applies here: the boundary should follow the
unit of ownership.

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
workload picks the trust subject. The existing
`aegis-staging-aegis-engine` role is destroyed in the landing-zone tier and
re-provisioned by ACK CRDs in `aegis-core-deploy` with the same trust
subject.

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
  `aegis-platform`, zero PR to `aegis-aws-landing-zone`.
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

This ADR is the commitment; the refactor lands as four follow-up PRs. Sketch:

1. **`aegis-platform`** — install the ACK IAM controller in
   `modules/regional-stack`; replace `for_each var.workloads` with one
   `ApplicationSet` resource; delete `workloads.auto.tfvars.json`.
2. **`aegis-core-deploy`** — add `argocd/application.yaml` +
   `k8s/base/iam/aegis-core-engine-role.yaml`; tag the repo with the
   `aegis-workload` GitHub topic.
3. **`aegis-greeter-deploy`** — same shape (Application CR + ACK CRDs for any
   workload-scoped IAM it needs).
4. **`aegis-aws-landing-zone`** — destroy `aegis-staging-aegis-engine`; narrow
   the tier's role to the OIDC provider only.
