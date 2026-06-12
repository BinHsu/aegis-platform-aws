# ADR-13: CI IAM roles live in a seed layer that survives teardown-to-zero

## Status

Proposed — **needs operator sign-off** (it adjusts the "teardown-to-zero"
definition). Extends [ADR-03](03-delivery-cicd-gitops.md) (the two-OIDC-role CI
trust split) and [ADR-11](11-account-dimension-single-source-of-truth.md) (role
names derive from `account_id`).

## Context

Until this ADR, all four CI IAM roles lived in `terraform/envs/platform`
(`oidc.tf`):

| Role | Name | Trust | Permission |
|---|---|---|---|
| apply | `gh-tf-apply-platform` | `refs/heads/main` + apply environments | AdministratorAccess |
| destroy | `gh-tf-destroy-platform` | `environment:destroy` / `:reaper-destroy` | AdministratorAccess |
| plan | `aegis-platform-aws-ci` | any ref on the infra repo | ReadOnlyAccess |
| push | `aegis-greeter-ci` | `aegis-greeter` main ref | ECR push to one repo |

`destroy-platform` (infra-ops.yml) runs `terraform destroy` against the platform
state **as `gh-tf-destroy-platform`**, and that state contained the roles
themselves. The 2026-06-12 joint-strike window
([runbook §G](../runbooks/2026-06-12-joint-strike.md)) drove this to four live
failures:

1. **Self-delete hazard.** `terraform destroy` would delete `gh-tf-destroy-platform`
   (the role it is running as) mid-run, invalidating the live STS session →
   `AccessDenied` on the remaining calls → a half-destroyed, still-billing
   platform (same shape as the 2026-06-06 cost incident). Mitigated by a
   pre-destroy `terraform state rm` of the role + its attachment (PR #64),
   proven live on both accounts.
2. **Orphaned admin roles.** That `state rm` leaves `gh-tf-destroy-platform`
   (AdministratorAccess attached) alive but out-of-state in **both** accounts
   (staging `251774439261`, prod `506221082337`). The next apply cycle's
   `iam:CreateRole` for the same name will hit `EntityAlreadyExists`.
3. **Cold-start chicken-egg.** The destroy also deleted `gh-tf-apply-platform`
   and `aegis-platform-aws-ci` (still in state). After teardown there is **no
   OIDC path** left into the account — the next cycle cannot
   `AssumeRoleWithWebIdentity` anything, so the operator must break-glass seed
   via `AWSControlTowerExecution` from the management account again.
4. **infra-plan red light.** `infra-plan` assumes `aegis-platform-aws-ci`; once
   that role is deleted the plan job fails OIDC AssumeRole until the account is
   re-seeded.

The roles are free (IAM roles incur no charge). They are federation entry
points, not workload or billable resources — yet they were caught in the
workload teardown only because of where their Terraform definitions happened to
live.

The seed path on day zero is fixed and external to these roles: a principal that
can write IAM (the org SCP `deny-iam-privilege-escalation` denies IAM writes to
SSO principals but permits the `gh-tf-*` glob, break-glass, and
`AWSControlTowerExecution`) must create the roles — **the roles cannot create
themselves**. `envs/bootstrap` already runs in exactly this posture: LOCAL state
(it survives the remote-state-bucket teardown), applied once per account by the
operator, guarding its one resource with `prevent_destroy`.

## Decision

**Relocate the four CI roles, their OIDC trust, and their baseline policy
attachments out of `envs/platform` and into `envs/bootstrap`** — the existing
LOCAL-state, operator-seeded layer. Concretely:

- `terraform/envs/bootstrap/iam-seed.tf` (new) owns the four `aws_iam_role`
  resources + trusts + attachments, each with `lifecycle { prevent_destroy =
  true }`. It references the LZ-owned GitHub OIDC provider via `data` source
  (unchanged from ADR-03), and constructs the `aegis-greeter` ECR repo ARN from
  `account_id` + `region` rather than reading platform's remote state — bootstrap
  must have **zero upstream dependency** (it is the seed layer; nothing exists
  before it).
- `terraform/envs/bootstrap/destroy-policy.tf` (moved from `envs/platform`) keeps
  the empirically-authored A7 destroy-scoped policy next to the role it targets,
  so the future "swap admin → scoped" attach never re-splits one role across two
  states.
- `terraform/envs/platform/oidc.tf` becomes four `data "aws_iam_role"` lookups.
  `outputs.tf` re-exports the ARNs from those data sources, so the downstream
  `envs/regional` cluster-access roster keeps reading them from the platform
  remote state — **its contract is unchanged**. `budget.tf` (cost-freeze action)
  references the apply role via the same data source.
- `infra-ops.yml`: the pre-destroy self-delete `state rm` is **removed** (the
  hazard is structurally gone — the platform state no longer contains the
  destroy role). The bootstrap job is documented as the **reconcile** path; the
  day-zero seed is operator-local break-glass.

**"Teardown-to-zero" is redefined to: zero billable resources + zero workload
resources. The CI seed roles (free, federation roots) persist by design.** The
2026-06-10 operator teardown decision targeted billable resources + the shared
ECR; it never required deleting free IAM federation roles. This ADR makes that
boundary explicit rather than incidental.

## Alternatives considered

### (a) `envs/bootstrap` — CHOSEN

The roles live with the state bucket in the LOCAL-state seed layer.

- **Day-zero seed:** operator-local `terraform apply` as break-glass /
  `AWSControlTowerExecution` — the same principal that already applies bootstrap
  to create the state bucket. No new seed mechanism.
- **Chicken-egg:** dissolved. The roles never destroy themselves (bootstrap has
  no `destroy-platform`; `prevent_destroy` blocks accidental deletion). The CI
  bootstrap-reconcile job assumes `gh-tf-apply-platform`, which is fine *after*
  day zero — and the day-zero apply is explicitly operator-local.
- **Drift between accounts:** one code path (`iam-seed.tf`) applied per account;
  no per-account divergence beyond `account_id`, consistent with ADR-11.
- **Cost:** none — IAM roles are free; bootstrap state stays local.
- **W3 accounts.json:** `bootstrap_complete` already means "state bucket + CI
  roles exist"; this ADR makes the second half literally true (before, the flag
  implied roles that platform created on first apply — a subtle lie after a
  teardown that deleted them).

Cost: the bootstrap env grows from "just the state bucket" to "state bucket + CI
identity". Acceptable — both are account-foundation singletons with identical
lifecycle (seed once, never tear down).

### (b) The landing-zone repo (org-level seeding)

Precedent exists: the GitHub OIDC provider is already LZ-owned (ADR-03), and the
enclave imported its CI role into its own bootstrap (ADR-0052).

- **Rejected for these roles** because they are **platform-repo-specific**: their
  OIDC trust subjects name `aegis-platform-aws` / `aegis-greeter` workflows and
  environments, their permission sets are platform-shaped (the greeter ECR repo,
  the A7 destroy policy authored from platform teardowns), and the W3 account
  model derives them from `account_id` inside this repo. Pushing them to the LZ
  would split a single repo's CI identity across two repos and force an LZ change
  on every platform CI trust adjustment. The LZ correctly owns the *provider*
  (the shared federation root, one per account, used by many repos); it should
  not own each consumer repo's roles. This is the same boundary the enclave drew:
  the provider is LZ-owned, the consumer's *own* CI role lives in the consumer's
  *own* seed layer (its bootstrap). Option (a) mirrors that exactly.

### (c) Keep in `envs/platform` + `prevent_destroy` + state-rm choreography

The status-quo-plus: add `prevent_destroy` to the roles and keep (or extend) the
pre-destroy `state rm` dance.

- **Rejected.** `prevent_destroy` makes `destroy-platform` *fail* (it refuses to
  delete a guarded resource) unless the resource is `state rm`'d first — so the
  choreography is still required, and the orphan-role problem (consequence #2)
  persists: every teardown leaves admin-attached roles out-of-state. It also
  keeps the roles coupled to the workload teardown's blast radius for no benefit.
  This is the weakest option: it treats the symptom (delete-order) and leaves the
  cause (roles in the wrong lifecycle layer).

## Consequences

- **The self-delete hazard is structurally eliminated**, not worked around: the
  platform state `destroy-platform` tears down no longer contains the role it
  runs as. The `state rm` choreography is deleted from `infra-ops.yml`.
- **No orphan roles, no next-cycle `EntityAlreadyExists`**: the roles are never
  deleted, so they are never recreated.
- **No cold-start chicken-egg after a normal teardown**: `destroy-platform`
  leaves the OIDC path intact. The break-glass seed is needed only on true
  day-zero (a brand-new account), never as a recovery from a routine teardown.
- **"Teardown-to-zero" now means zero billable + zero workload**, with the CI
  seed roles persisting. This is the operator-sign-off item: anyone auditing
  "is the account at zero?" must know free IAM federation roles are intentionally
  retained (verify cost = zero, not resource-count = zero).
- **`bootstrap_complete` becomes honest**: it now literally means "state bucket +
  CI roles exist", because bootstrap creates both.
- **The day-zero seed is operator-local**, documented in `infra-ops.yml` and the
  bootstrap README — the CI bootstrap job is the reconcile path for an
  already-seeded account.
- **Downstream contracts unchanged**: `envs/regional` still reads the four role
  ARNs from the platform remote state (re-exported via data sources);
  `budget.tf`'s cost-freeze action still binds to the apply role.
- **Cost**: zero. IAM roles are free; bootstrap state stays local.

## Migration plan — the current orphan state

After the 2026-06-12 teardown, both accounts are in a specific shape that this
migration must handle:

- `gh-tf-destroy-platform` exists, **AdministratorAccess attached, out of every
  Terraform state** (the `state rm` orphan, consequence #2), in **both** accounts.
- `gh-tf-apply-platform` and `aegis-platform-aws-ci` were **deleted** by the
  destroy (consequence #3) — they do not exist.
- `aegis-greeter-ci` state depends on whether the greeter push role survived the
  last teardown; treat as "verify, then create-or-import".

The cutover is therefore **mostly create-in-new-layer + import-the-one-orphan**,
not a state move (the platform state is empty post-teardown and the apply/CI
roles are gone — there is nothing to `moved {}` from). Per account, once per
account, then never again:

1. **Pull bootstrap state local** for the account (`envs/bootstrap` is local
   state; fetch the operator's copy / artifact for that account).
2. **Import the one orphan** so Terraform manages it instead of colliding:
   ```
   terraform -chdir=terraform/envs/bootstrap import \
     aws_iam_role.infra_destroy gh-tf-destroy-platform
   terraform -chdir=terraform/envs/bootstrap import \
     aws_iam_role_policy_attachment.infra_destroy_admin \
     gh-tf-destroy-platform/arn:aws:iam::aws:policy/AdministratorAccess
   ```
   (Run as break-glass / `AWSControlTowerExecution` — `iam:GetRole` etc. under
   the SCP.)
3. **Apply `envs/bootstrap`** as the seed principal. Terraform **creates**
   `gh-tf-apply-platform`, `aegis-platform-aws-ci`, `aegis-greeter-ci` (+ their
   trusts/attachments) and reconciles the imported destroy role. `prevent_destroy`
   is now in force on all four.
4. **Re-seed repo secrets / vars** from bootstrap outputs:
   `AWS_INFRA_APPLY_ROLE_ARN` ← `infra_apply_role_arn`, `AWS_DESTROY_ROLE_ARN` ←
   `infra_destroy_role_arn` (or rely on the account_id-derived ARN the W3 path
   uses), and confirm `accounts.json.<account>.bootstrap_complete = true`.
5. **Verify** `infra-plan` (assumes the recreated `aegis-platform-aws-ci`) goes
   green — closes consequence #4.

From this point a `destroy-platform` tears down only the workload + billable
platform; the four roles persist. The break-glass seed is never needed again for
this account unless the account itself is decommissioned.

If `aegis-greeter-ci` *did* survive a prior teardown (it sometimes outlived the
platform state), import it in step 2 as well
(`terraform import aws_iam_role.greeter_ci aegis-greeter-ci`) to avoid an
`EntityAlreadyExists` on step 3.

## Related ADRs

- [ADR-03](03-delivery-cicd-gitops.md) — the two-OIDC-role CI trust split + the
  LZ-owned OIDC provider; this ADR moves the *roles* (not the provider) to the
  seed layer.
- [ADR-11](11-account-dimension-single-source-of-truth.md) — role/bucket names
  derive from `account_id`; this ADR keeps that derivation in `iam-seed.tf`.
- Enclave ADR-0052 — the same boundary in the sibling repo: LZ owns the OIDC
  provider, the consumer repo's own CI role lives in the consumer's own bootstrap.
