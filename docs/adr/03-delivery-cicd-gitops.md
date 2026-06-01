# ADR-03: Delivery — CI/CD & GitOps

## Status

Accepted.

## Context

Two delivery questions. **How does Terraform reach AWS** — an operator's laptop
(simple, but unaudited, credential-dependent, drifts from "git is the source of
truth") or CI (which needs an approval model so a merge cannot silently mutate
cloud infrastructure). **How does Kubernetes reach the cluster** — `kubectl
apply` from CI, or GitOps reconciliation; and if ArgoCD, hub-spoke (one central
ArgoCD managing remote clusters) or per-cluster.

## Decision

**CI-driven apply, pure-GitOps model.** Push to `main` runs `infra-apply`
(`terraform apply` per env). The gate is the PR: `infra-plan` posts the plan
diff as a PR comment, and `main` branch protection requires the plan's status
check + linear history before merge. No post-merge approval button — PR review
of the plan diff is the human gate, symmetric with how ArgoCD auto-applies
Kubernetes changes. `workflow_dispatch` (`infra-ops`) covers one-shots:
bootstrap and the DR drill.

**Trust is split across two GitHub OIDC roles** — a read-only role for PR plans
(trusted from any ref) and an apply role whose trust is pinned to
`refs/heads/main`, so a PR branch cannot assume it. No static AWS keys.

**GitHub OIDC provider ownership — landing-zone, not platform** *(2026-06-01).*
`token.actions.githubusercontent.com` is a per-account singleton and an
account-foundation federation root. It is owned and lifecycle-managed by the
landing-zone — the same tier that owns the break-glass role, the state backend,
and the org SCP — and this composition references it via a `data` source
(`envs/platform/oidc.tf`), not a `resource`. Two reasons: a platform `terraform
destroy` must not delete the provider out from under every other repo's CI roles
that federate the same singleton; and minting a new federation root
(`iam:CreateOpenIDConnectProvider`) is escalation-adjacent and belongs to the
foundation tier, not a workload apply path. **Dependency:** platform's target
account must already have the landing-zone-provisioned provider before
`terraform apply` (it exists in staging / shared / management; prod would need an
LZ prod-OIDC bootstrap first). The per-cluster **EKS IRSA** OIDC providers
(`oidc.eks.<region>...`) are unaffected — those are workload artifacts, one per
cluster, created and owned by `modules/regional-stack`. The enclave made the same
move in its ADR-0052.

**Per-cluster ArgoCD.** Each EKS cluster runs its own ArgoCD, installed by
`modules/regional-stack`, with one `Application` per workload — each pointing at
that workload's deploy repo (`k8s/overlays/prod/`). The workload set is data
(`workloads.auto.tfvars.json`): one entry per deploy repo, fanned out by
`for_each`. No `ApplicationSet`, no cross-cluster RBAC, no `argocd cluster add`
— hub-spoke would make the hub a single point of failure and a cross-cluster
blast radius.

The image flow closes the loop: a workload's application repo (e.g.
`aegis-greeter`) builds the container in CI, pushes it to ECR, and commits the
image-tag bump to its deploy repo's `k8s/overlays/prod/kustomization.yaml`;
ArgoCD reconciles the change.

## Consequences

- Every infrastructure change is a reviewed, audited Git event; the apply
  identity (`refs/heads/main`-pinned) cannot be assumed from a PR branch.
- No GitOps-layer SPOF: a region's ArgoCD failure is contained to that region,
  and each region reconciles itself with no dependency on a hub.
- A bootstrap-ordering gap: before `platform` is applied, the IAM roles the
  workflows assume do not exist. A `BOOTSTRAP_COMPLETE` repo variable gates the
  plan/apply jobs — they skip cleanly until an operator has bootstrapped,
  keeping the pipeline green rather than failing on an unavoidable gap.
- Branch protection on a *private* repo needs GitHub Pro, so the
  `github_branch_protection` resource is gated on `var.enable_branch_protection`
  (off by default) — until the repo is public or on Pro the gate is convention.
- The apply role is broad (`AdministratorAccess`); least-privilege is deferred
  ([`tradeoffs.md`](../tradeoffs.md)).
- Cost: N ArgoCD installs and no single pane of glass across clusters. At this
  scale a non-issue; a fleet of dozens would revisit it.
