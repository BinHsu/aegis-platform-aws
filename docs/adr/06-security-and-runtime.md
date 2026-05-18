# ADR-06: Security & runtime

## Status

Accepted.

## Context

An infrastructure repo's security posture is the sum of many small decisions —
how identity is granted, how the workload is constrained at runtime, how
credentials are scoped, how secrets are kept out of git. Recorded here as one
theme so the posture is reviewable in one place, not reverse-engineered from
Terraform.

## Decision

**Identity — least-privilege, scoped per purpose.**

- *Workloads* use IRSA (IAM Roles for Service Accounts) where they need AWS
  APIs — the ALB controller and external-dns each assume a role scoped to
  exactly its own actions (load-balancer APIs; Route 53 record writes on the
  one hosted zone), not the node's IAM role, so a pod cannot inherit node-wide
  permissions.
- *CI* uses GitHub OIDC, no static keys — two roles split trust (read-only for
  PR plans, apply pinned to `refs/heads/main`; see
  [ADR-03](03-delivery-cicd-gitops.md)).
- *Cluster access* uses EKS access entries, explicit and deterministic.
  `enable_cluster_creator_admin_permissions` is off — it injects the running
  caller's ARN, which differs between a local apply and a CI apply; the access
  list is the explicit `access_entries` map instead.
- *ArgoCD → repo* uses a dedicated read-only SSH deploy key per cluster, scoped
  to this repo only — a leaked key has repo-only, not account-wide, blast radius.

**Runtime — constrained by default.**

- The greeter namespace enforces PodSecurity Standards `restricted` — the
  modern replacement for the deprecated PodSecurityPolicy — via namespace
  labels, no admission-controller install.
- The pod's `securityContext` runs non-root, read-only root filesystem, no
  privilege escalation, all Linux capabilities dropped, `seccompProfile:
  RuntimeDefault`.

**Secrets — kept out of git, shifted left.**

- Real `*.tfvars` are gitignored; `*.example` templates ship in their place.
- Grafana Cloud credentials live in AWS SSM Parameter Store and reach Alloy as
  a Kubernetes Secret — never committed.
- A pre-commit hook runs `gitleaks` on staged changes; CI runs a full-history
  `gitleaks` scan — a credential is blocked before it can enter history.

## Consequences

- A compromised pod, CI run, or deploy key has a bounded blast radius — the
  scope was decided up front, not after an incident.
- The runtime baseline is the strictest standard tier; a reviewer sees the
  modern posture (PSS, not PSP) at a glance.
- Deliberate, documented gaps: the EKS API endpoint is public (no bastion), the
  CI apply role is `AdministratorAccess`, and at-rest encryption uses
  AWS-managed keys rather than customer-managed CMKs. Each is a cost/scope
  trade-off recorded in [`tradeoffs.md`](../tradeoffs.md) with its production
  hardening path.
