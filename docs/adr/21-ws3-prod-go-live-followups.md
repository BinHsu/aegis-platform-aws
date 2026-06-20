# ADR-21: WS3 prod go-live forward-fixes — Pod Identity, deploy-enable split, prod release + ECR, cold-start safety net

## Status

**Proposed** (2026-06-18). Bin reviews before any section lands. This ADR records
decisions surfaced by the WS3 prod dual-region go-live (2026-06-18); it changes
**no code** by itself. Each section is independently adoptable.

Extends [ADR-10](10-release-model-build-once-promote-by-digest.md) (build once,
promote by digest), [ADR-11](11-account-dimension-single-source-of-truth.md)
(`accounts.json` as the account-dimension source of truth),
[ADR-13](13-ci-iam-roles-survive-teardown.md) (lifecycle-layer placement of IAM
that must survive teardown), and [ADR-19](19-aws-public-edge-domain-acm-cognito.md)
(the WS3 edge the go-live exercised).

## Context

The WS3 prod cold start hit five distinct latent bugs **on the prod path**
(region-suffixed IAM policy names #108, zone-fallback placeholders #107, an
empty-state version-gate plan #106, the orphaned-state-lock self-heal #103, and
the IRSA-vs-Crossplane teardown hazard below). Each was a first-ever-cold-start
defect that no prior run could have surfaced, because prod had never been built
from true zero. The go-live succeeded after those fixes, then prod was torn down
and parked (#112) with both `accounts.json` flags left `false`.

Three structural problems the go-live exposed are not yet fixed, plus one
meta-problem — that prod was the first environment to ever cold-start. This ADR
records the canonical fix for each. They share one theme: **a lifecycle or
intent boundary was conflated with something else**, and the conflation only bit
on the first real cold start.

---

## SECTION A — Replace Crossplane-composed IRSA with EKS Pod Identity

### A.1 Problem (from the go-live)

The engine's IAM role is composed **inside the cluster** by Crossplane. A
`WorkloadIdentity` claim (XRD `xworkloadidentities.platform.aegis.io`, Composition
`workloadidentity-ack-iam-role`, in
`terraform/modules/regional-stack/charts/aegis-xrds/`) renders an upjet
`iam.aws.upbound.io/v1beta1/Role` (provider
`xpkg.upbound.io/upbound/provider-aws-iam:v1.21.0`), which the
`provider-aws-iam` controller creates in AWS as role `aegis-core-engine` at IAM
path `/aegis-workload/`. This is "fix B" — it replaced ACK with a cluster-scoped
upjet Role to dodge a namespace bug.

The go-live proved this places the engine's IAM role in the **wrong lifecycle
layer**, with three concrete costs:

1. **Orphan on teardown.** Crossplane created `aegis-core-engine` (path
   `/aegis-workload/`); Terraform does not manage it. When the cluster was torn
   down, the Crossplane controller went away **before** it deleted the role, so
   the role survived teardown — an orphan in IAM. An org SCP denies manual
   deletion of the `/aegis-workload/` path, so the operator cannot break-glass
   delete it either. This is the same orphan-IAM failure class
   [ADR-13](13-ci-iam-roles-survive-teardown.md) fixed for the CI roles, recurring
   one layer down for workload roles.
2. **Re-apply collision.** The orphan will block the next clean cold start. The
   composed role attaches a managed policy named `aegis-core-model-read-<region>`
   (`model-store.tf`). A re-apply that re-creates the role hits a duplicate
   policy-name collision (`EntityAlreadyExists`) on that region-suffixed name —
   the cold-start cannot be clean while the orphan holds the name.
3. **Operational complexity in the IAM hot path.** Putting upjet in the role's
   creation path dragged in the provider/family-provider race, three
   `DeploymentRuntimeConfig`s (`provider-aws-iam-runtime`, `family-aws-runtime`,
   `aegis-function-runtime`) to satisfy the `restricted` PodSecurity admission on
   `crossplane-system`, and a dedicated provider IRSA role
   (`aegis-platform-aws-ack-iam-<region>`). Several of the five go-live bugs trace
   to this machinery, not to the workload.

The role being *composed in-cluster* means its lifecycle is bound to the
**controller's reconcile loop**, not to the **Terraform stack**. Teardown deletes
the stack; the controller is gone before it reaps what it made.

### A.2 Decision

**Provision workload IAM with EKS Pod Identity, managed directly in the
`regional-stack` Terraform — not composed in-cluster by Crossplane.**

EKS Pod Identity (GA 2023) associates an IAM role to a Kubernetes ServiceAccount
through an EKS control-plane API (`eks:CreatePodIdentityAssociation`), via the
`eks-pod-identity-agent` add-on. The association's lifecycle is the **cluster**;
no OIDC-provider trust wiring, no `aud`/`sub` condition hand-authoring, no
in-cluster IAM controller.

Per workload, the `regional-stack` module owns three normal Terraform resources:

```hcl
resource "aws_iam_role" "engine" {
  name                 = "aegis-core-engine-${var.region}"   # region-suffixed, ADR-21 §C precedent
  assume_role_policy   = data.aws_iam_policy_document.pod_identity_trust.json
}
resource "aws_iam_role_policy" "engine_model_read" { ... }   # inline — no shared managed-policy name to collide
resource "aws_eks_pod_identity_association" "engine" {
  cluster_name    = module.eks.cluster_name
  namespace       = "aegis-core"
  service_account = "aegis-core-engine"
  role_arn        = aws_iam_role.engine.arn
}
```

The trust policy is the fixed Pod Identity principal
(`pods.eks.amazonaws.com`, `sts:AssumeRole` + `sts:TagSession`) — identical
across regions, no per-cluster OIDC issuer to thread.

This makes **teardown clean**: `terraform destroy` deletes the role, the policy,
and the association with the stack. No orphan, no `/aegis-workload/` SCP wall, no
`aegis-core-model-read-<region>` collision on re-apply. The workload IAM joins the
CI roles in being managed by the same Terraform that owns the cluster — the
[ADR-13](13-ci-iam-roles-survive-teardown.md) principle applied to workload
identity.

The provider-neutral injection contract ([ADR-16](16-provider-neutral-injection-contract.md))
is unchanged: the platform still binds identity to the `aegis-core-engine`
ServiceAccount; only the *mechanism* changes (Pod Identity association vs.
IRSA-annotation-via-Crossplane). The deploy repo's `aws-binding` keeps the bare
ServiceAccount; it carries no role ARN.

### A.3 Comparison

| | IRSA (OIDC) | Pod Identity | Crossplane-composed IRSA (current) |
|---|---|---|---|
| Role↔SA binding | OIDC trust `sub` condition | EKS API association | OIDC trust, rendered by upjet MR |
| Trust wiring per cluster | hand-authored `aud`/`sub` | none (fixed principal) | hand-authored, in the Composition |
| Who creates the IAM role | Terraform | Terraform | in-cluster controller |
| Role lifecycle bound to | the stack | the cluster (+ stack) | the **controller reconcile loop** |
| Teardown leaves an orphan? | no | no | **yes** (controller gone before reap) |
| Cross-account role | supported | supported (assoc references any role) | supported |
| Moving parts | OIDC provider, trust policy | Pod Identity add-on | upjet provider + family + 3 DRCs + provider IRSA |

Pod Identity wins on the axis the go-live failed: lifecycle. It is also AWS's
forward-recommended mechanism for new clusters, removing the per-cluster OIDC
trust authoring IRSA requires.

### A.4 Interim mitigation (fallback, if Pod Identity is not adopted now)

If the engine stays on Crossplane-composed IRSA, the teardown order must let the
controller reap what it made **before** the cluster goes away:

1. `destroy-region` first deletes the ArgoCD `Application`s and the
   `WorkloadIdentity` claims (`kubectl delete`), then **waits** for Crossplane to
   reconcile the composed-resource deletion — the `iam.aws.upbound.io/Role` MR
   reaches `Synced/Ready=False, deleting`, then is gone — confirming the AWS role
   was deleted.
2. **Only then** run `terraform destroy` of the cluster.

This is strictly a fallback: it adds an ordered, controller-paced wait to the
teardown critical path (a failure mid-wait re-creates the orphan) and keeps every
A.1 complexity cost. It is recorded so a partial adoption is safe, **not**
recommended over A.2.

### A.5 This-cycle cleanup

One orphan exists now: role `aegis-core-engine` at path `/aegis-workload/` in the
prod account, surviving the #112 teardown, name-blocked by the SCP. Deleting it
needs either (a) a temporary SCP exception (break-glass via
`AWSControlTowerExecution` from management, the [ADR-13](13-ci-iam-roles-survive-teardown.md)
break-glass principal), or (b) re-running the Crossplane controller against it to
reap it through the path it was created by. Track as a cold-start precondition for
the next prod build — same shape as the ADR-13 orphan-delete block.

---

## SECTION B — Decouple "bootstrapped" from "deploy-enabled"

### B.1 Problem

`accounts.json`'s `bootstrap_complete` is **one** flag carrying **two** meanings:

- a **fact** — the state bucket + CI roles exist
  ([ADR-13](13-ci-iam-roles-survive-teardown.md) made this literally true), and
- an **intent** — CI may apply this account.

The apply workflows gate on it directly: `infra-staging.yml` /
`infra-prod.yml` extract `bootstrap_complete` from `accounts.json` and pass it
to `infra-apply-account.yml`, which gates every apply job
(`if: ${{ inputs.bootstrap_complete }}`). `accounts.json` is therefore a
**trigger path**: a commit that flips the flag to `true` itself starts an apply
and spins up a billable cluster.

The go-live made the cost of this conflation concrete. Staging is fully proven
and we would like the *fact* "staging is bootstrapped" recorded — but recording
it by setting `staging.bootstrap_complete = true` would **immediately trigger an
infra-staging apply** and stand up a billable cluster. So the fact cannot be
written without firing the intent. Operationally, **`staging.bootstrap_complete`
must stay `false`** for now, which makes the recorded data *wrong on the fact
axis* to keep it *safe on the intent axis*. One flag cannot serve both.

### B.2 Decision

**Split the two meanings.** Recommended for this repo: **option (a), two fields.**

- `bootstrapped` — a read-only **fact**: the state bucket + CI roles exist.
  Written by the operator (or, better, asserted by the bootstrap apply) after
  `make bootstrap`. CI never apply-gates on it; it documents the account's state
  and may gate *read-only* paths (e.g. the reaper's scan target list).
- `deploy_enabled` — an **intent switch**: CI may apply this account. The apply
  workflows gate on **this** (`if: ${{ inputs.deploy_enabled }}`). Flipping it
  `true` is the deliberate "go live" act; flipping it `false` parks the account
  without erasing the fact that it was bootstrapped.

This lets `staging.bootstrapped = true` (record the fact) and
`staging.deploy_enabled = false` (stay parked, no apply triggered)
co-exist — exactly the state the go-live needs and cannot express today.

The reaper already consumes the flag (`select(.value.bootstrap_complete == true)`)
to choose scan targets — that consumer wants the **fact** (`bootstrapped`), which
makes the split cleaner, not harder: scan-eligibility follows existence, apply
follows intent.

**Option (b) — a GitOps pull model** (an ArgoCD `ApplicationSet` whose generator
reads git-declared environments, `suspend: true` to park) — is the stronger
long-term shape: presence is declared, not imperatively triggered, so flipping a
field never *runs* anything; a controller reconciles toward the declaration.
Rejected as the *immediate* fix only because it is a larger re-architecture of
the CI-driven-apply substrate ([ADR-03](03-delivery-cicd-gitops.md)); the
two-field split delivers the decoupling now with a one-field schema change and a
gate rename. Option (b) is the named evolution.

**This is a future refactor; no code changes in this ADR.** Until it lands,
`staging.bootstrap_complete` and `prod.bootstrap_complete` both stay `false` — the
safe-but-fact-wrong state — and the operator knows the staging fact out of band.

### B.3 Consequences

- The schema migration is one rename + one add (`bootstrap_complete` →
  `bootstrapped` + new `deploy_enabled`), touching `accounts.json` and the three
  workflows that read it (`infra-staging.yml`, `infra-prod.yml`,
  `infra-apply-account.yml`) plus the reaper.
- The early-exit warning in `infra-apply-account.yml` switches to gate on
  `deploy_enabled`; its message changes from "bootstrap_complete=false → skip" to
  "deploy_enabled=false → parked".
- The gating decisions in [ADR-11](11-account-dimension-single-source-of-truth.md)
  (prod always under `prod-apply-gated`, version gate hard-fails prod) are
  unchanged — they sit *downstream* of `deploy_enabled`.

---

## SECTION C — Prod image release + ECR cross-region

### C.1 Problem

Prod gateway and engine could not run, for two compounding reasons:

1. **Placeholder digest.** The `aegis-core-deploy` prod overlay still pins a
   placeholder image digest (`sha256:0000…`); `accounts.json`'s `prod.pin` is
   `v0.0.0-PLACEHOLDER`. The "prod CI release (tag→digest)" step that
   [ADR-17](17-core-release-parity-and-neutral-base.md) deferred to WS3 was never
   cut, so there is no real digest to promote. ArgoCD syncs the placeholder →
   `ImagePullBackOff`.
2. **No in-region image.** The deploy injects the in-region ECR
   (`<acct>.dkr.ecr.eu-west-1.amazonaws.com/…`, per the ADR-12 registry
   annotation), but the core images live **only** in eu-central-1 — in the
   shared-services / deployment registry, account `162975888022`, ~158 MB. There
   is no eu-west-1 replica. A prod second region cannot pull what is not there.

The registry topology is **correct**: a shared registry in a separate deployment
account (`deployment-ecr.tf`, gated on `deployment_account_id`,
`provider = aws.deployment`) is the [ADR-10](10-release-model-build-once-promote-by-digest.md)
model and proper AWS multi-account practice. It must **not** be torn down per-env.
The gap is the missing release cut and the missing per-region copy.

### C.2 Decision

Three parts.

**(1) Cut the prod release flow (tag→digest, commit-back).** A CI release job in
the `aegis-core` build repo builds, pushes to the deployment-account ECR, and
**commits the immutable digest back** to the `aegis-core-deploy` prod overlay —
the missing realization of [ADR-10](10-release-model-build-once-promote-by-digest.md)
§"How a prod release is triggered" and the WS3 deferral in
[ADR-17](17-core-release-parity-and-neutral-base.md). The digest is captured from
the push (`docker buildx --metadata-file` / `crane digest`) and written as
`@sha256:…` (SLSA-style digest pinning); `accounts.json`'s `prod.pin` moves from
`v0.0.0-PLACEHOLDER` to the released `vX.Y.Z`. Both core images move atomically
per [ADR-14](14-multi-image-atomic-promotion.md).

**(2) Replicate the registry per enabled region — already built, must be
exercised.** ECR registry replication already exists in
`terraform/envs/platform/ecr.tf` (`aws_ecr_replication_configuration.main`,
count-gated on enabled regions != `platform_region`). It is currently inert
because only `eu-central-1` is enabled. **The fix is to enable eu-west-1 in
`regions.auto.tfvars.json` *before* the prod apply**, so replication activates
and every enabled region gets an in-region copy at the same digest. The
**source of truth** for the *deployment-account* shared registry should
likewise replicate to each enabled region (a registry replication rule on the
deployment account), so cross-region pull is never required. Pulling
cross-region is the deliberate fallback — accepted only for a single-region
prod, rejected for the dual-region target because it makes one region's image
availability depend on another region's ECR.

**(3) ECR lifecycle policy.** Add a lifecycle policy on the core repositories to
**expire untagged images** (e.g. older than N days / keep last M), bounding
registry growth as releases accumulate. Tagged release digests are retained;
`IMMUTABLE` tags ([ADR-10](10-release-model-build-once-promote-by-digest.md))
plus this expiry give a bounded, auditable registry.

### C.3 Consequences

- The prod overlay stops carrying a placeholder; the digest is real and
  promotable. `validate.yml`'s both-or-neither + digest-shape checks
  ([ADR-17](17-core-release-parity-and-neutral-base.md)) now have a real digest to
  assert.
- Enabling eu-west-1 in `regions.auto.tfvars.json` must precede (or accompany) the
  dual-region prod apply, so replication seeds the second region's ECR before any
  pod schedules there. Ordering matters: replication is async; a same-apply race
  could still `ImagePullBackOff` on the first sync — seed-then-deploy.
- The deployment account (`162975888022`) and its shared ECR stay up across env
  teardowns; only the cluster-account regional copies churn. Correct AWS
  multi-account practice — do not couple the registry's lifecycle to any one
  environment.

---

## SECTION D — Prevent the next cold-start surprise

### D.1 Problem

Prod was the **first environment to ever cold-start from true zero**, and it
surfaced five latent bugs **on the prod path** — the most expensive place to find
them. Every one was a cold-start-only defect (empty-state plan, zone-fallback
placeholders, region-suffix collisions, orphaned state lock, the §A IAM orphan):
a disposable, throwaway cold-start would have caught all five **off** prod.

### D.2 Decision

Build a cold-start safety net so a first-ever build surfaces latent bugs off the
prod path. Two complementary layers:

**(1) A plan-against-empty-state CI gate** — and, since no `*.tftest.hcl` exists
anywhere in the repo today, adopt **Terraform `test` (TF 1.6+)**. A `run` block
with `command = plan` against an empty/fresh state asserts the module plans
cleanly from zero — catching the empty-state-plan class (#106), unresolved
fallbacks (#107), and name collisions (#108) at PR time, free, with no AWS calls.
This is the cheapest backstop and has no current coverage; it lands first.

**(2) An ephemeral / preview cold-start environment** — a throwaway target where a
*real* first-ever apply runs off the prod path. Two shapes:

- a **disposable AWS account** (or a reused, always-torn-down sandbox account)
  that runs the full cold-start apply→verify→destroy on a schedule or pre-release,
  exercising real IAM/EKS/ECR — the highest-fidelity catch, at real (bounded,
  short-lived) cost; or
- a **vcluster / virtual-cluster** preview for the in-cluster layer (ArgoCD,
  Crossplane/Pod-Identity wiring, Kyverno) where the bug is Kubernetes-shaped, not
  AWS-account-shaped — cheaper, lower fidelity (no real IAM).

**Recommendation:** layer (1) now (zero cost, zero current coverage, catches the
plan-time classes); layer (2) as a periodic disposable-account cold-start drill
before each prod go-live, because the §A IAM-orphan and the ECR-replication-race
classes are only reproducible against real AWS. The drill *is* the cold start —
run to true zero and back — so the first real prod build is no longer the first
build.

### D.3 Consequences

- A `tests/*.tftest.hcl` suite enters the repo and runs in CI (plan-only, no
  credentials), gating PRs on clean-from-zero plans.
- A disposable cold-start drill is sequenced before prod go-lives; its teardown
  must itself reach true zero (the §A orphan check is part of its exit criteria),
  closing the loop with [ADR-13](13-ci-iam-roles-survive-teardown.md)'s
  teardown-to-zero discipline.

---

## Alternatives considered (cross-section)

- **§A — keep Crossplane IRSA, guard with ordered teardown only.** Rejected as the
  primary fix (it is the §A.4 fallback): it leaves every complexity cost and adds
  a controller-paced wait whose failure re-creates the orphan. Pod Identity removes
  the orphan *by construction*.
- **§A — plain IRSA (Terraform-managed OIDC trust) instead of Pod Identity.**
  Defensible — Terraform-managed IRSA also tears down cleanly. Pod Identity is
  preferred because it drops per-cluster OIDC trust authoring and is AWS's forward
  mechanism; IRSA is the acceptable second choice if a cluster cannot run the Pod
  Identity add-on.
- **§B — keep one flag, never write the staging fact.** Rejected: it permanently
  trades a true record for trigger-safety; the split costs one schema field.
- **§C — single shared registry, pull cross-region (no per-region replica).**
  Rejected for dual-region prod (couples one region's availability to another's
  ECR); accepted only for single-region prod. Replication is already built —
  enable it.
- **§D — rely on staging as the cold-start proxy.** Rejected: staging is
  long-lived and was never itself cold-started to zero, so it does not exercise
  the first-build path. A *disposable* environment that is built from zero and
  destroyed is what surfaces cold-start bugs.

## Consequences (summary)

- §A removes the workload-IAM orphan class entirely (Pod Identity, Terraform-owned)
  and deletes the upjet/DRC machinery from the IAM hot path.
- §B lets the bootstrapped *fact* and the deploy *intent* be recorded
  independently, unblocking an honest `accounts.json` without triggering an apply.
- §C cuts the missing prod release and seeds every enabled region's ECR before
  deploy, so prod pods can pull; the shared deployment-account registry stays up
  across env teardowns.
- §D moves first-cold-start bug discovery off the prod path (a TF `test` gate now,
  a disposable cold-start drill before go-lives).
- None of these ship in this ADR. Each is independently adoptable; §A and §C are
  the prod-go-live blockers, §B and §D are durability investments.

## Related

[ADR-10](10-release-model-build-once-promote-by-digest.md) ·
[ADR-11](11-account-dimension-single-source-of-truth.md) ·
[ADR-12](12-registry-injection-vs-digest-pin-field-ownership.md) ·
[ADR-13](13-ci-iam-roles-survive-teardown.md) ·
[ADR-14](14-multi-image-atomic-promotion.md) ·
[ADR-16](16-provider-neutral-injection-contract.md) ·
[ADR-17](17-core-release-parity-and-neutral-base.md) ·
[ADR-19](19-aws-public-edge-domain-acm-cognito.md) ·
[`docs/runbooks/2026-06-20-dual-region-full-verification.md`](../runbooks/2026-06-20-dual-region-full-verification.md)
