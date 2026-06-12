# ADR-13: CI IAM roles live in the cold-start seed layer (teardown-to-zero stays full)

## Status

Accepted — **operator decision 2026-06-12**. The operator's verbatim intent:

> 「這次可以全拆,讓下一次的冷啟動是完整的不再是補丁手敲的」
> (This cycle we can tear down *everything* — let the next cold start be
> complete, no longer a hand-typed patch.)

Two consequences flow directly from that intent and are baked into this ADR's
Decision below: (1) teardown-to-zero stays **full** — the CI roles are **not**
exempt; (2) the next cold start must be a **complete, formalized first-class
path** — one operator command, no orphan imports, no `state rm` choreography.

Extends [ADR-03](03-delivery-cicd-gitops.md) (the two-OIDC-role CI trust split)
and [ADR-11](11-account-dimension-single-source-of-truth.md) (role names derive
from `account_id`).

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

All four failures share one root cause: the roles were caught in the **workload
teardown** only because their Terraform definitions happened to live in the
workload state (`envs/platform`). They are federation entry points whose
lifecycle is the *account*, not the *workload* — yet `destroy-platform` swept
them up with the EKS cluster. The fix is to move them to the layer whose
lifecycle is the account.

The seed path on day zero is fixed and external to these roles: a principal that
can write IAM (the org SCP `deny-iam-privilege-escalation` denies IAM writes to
SSO principals but permits the `gh-tf-*` glob, break-glass, and
`AWSControlTowerExecution`) must create the roles — **the roles cannot create
themselves**. `envs/bootstrap` already runs in exactly this posture: LOCAL state
(it survives the remote-state-bucket teardown), applied per cold start by the
operator. It guards its one irreversible resource — the state bucket — with
`prevent_destroy`; the CI roles do **not** take that guard (they are cheaply,
idempotently recreatable, so a full teardown may delete them and the next seed
apply restores them).

## Decision

**Relocate the four CI roles, their OIDC trust, and their baseline policy
attachments out of `envs/platform` and into `envs/bootstrap`** — the existing
LOCAL-state, operator-seeded layer. Concretely:

- `terraform/envs/bootstrap/iam-seed.tf` (new) owns the four `aws_iam_role`
  resources + trusts + attachments. They carry **no `prevent_destroy`** — only
  the state bucket (`main.tf`) keeps that guard, because losing the bucket is
  irreversible (every downstream env loses its state) whereas the roles are
  cheaply, idempotently recreatable by the seed apply. It references the
  LZ-owned GitHub OIDC provider via `data` source
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

**"Teardown-to-zero" is UNCHANGED — it still means true zero, the CI roles
included.** The 2026-06-12 operator decision is explicit: a full close-out may
delete these roles. What changes is the **cold-start contract**, not the
teardown definition:

- Before ADR-13: cold start after a full teardown was a *patch* — break-glass
  recreate the deleted apply/CI roles, import the orphaned destroy role, run
  `state rm` to keep the destroy from killing itself. Hand-typed, error-prone,
  undocumented.
- After ADR-13: cold start is **one formal operator command** —
  `terraform apply` on `envs/bootstrap` as break-glass — that seeds the state
  bucket **and** the four CI roles from true zero. A separate operator step then
  sets `BOOTSTRAP_COMPLETE` via `gh variable set` (Cold-start runbook step 3),
  which hands the account to CI. No orphan imports, no `state rm` choreography.

The full sequence is the **Cold-start runbook** section below. The key structural
property: the seed apply is idempotent from **both** starting states — roles
already exist (no-op) or roles deleted (clean recreate: `terraform apply` refreshes
state during planning, detects `NoSuchEntity`, plans a Create — no import). That
is what makes the next cold start a first-class path rather than a patch.

## Alternatives considered

### (a) `envs/bootstrap` — CHOSEN

The roles live with the state bucket in the LOCAL-state seed layer.

- **Day-zero seed:** operator-local `terraform apply` as break-glass /
  `AWSControlTowerExecution` — the same principal that already applies bootstrap
  to create the state bucket. No new seed mechanism.
- **Chicken-egg:** dissolved. The roles never destroy *themselves*
  (`destroy-platform` runs against the platform state, which no longer contains
  them — so the running role cannot delete itself mid-teardown). A full close-out
  may still delete them (a `terraform destroy` of `envs/bootstrap` minus the
  bucket, or an operator break-glass delete) — and the next cold start recreates
  them with one operator-local `terraform apply`. The CI bootstrap-reconcile job
  assumes `gh-tf-apply-platform`, which is fine *after* the seed exists — and the
  cold-start seed apply is explicitly operator-local break-glass.
- **Drift between accounts:** one code path (`iam-seed.tf`) applied per account;
  no per-account divergence beyond `account_id`, consistent with ADR-11.
- **Cost:** none — IAM roles are free; bootstrap state stays local.
- **W3 accounts.json:** `bootstrap_complete` already means "state bucket + CI
  roles exist"; this ADR makes the second half literally true (before, the flag
  implied roles that platform created on first apply — a subtle lie after a
  teardown that deleted them).

Cost: the bootstrap env grows from "just the state bucket" to "state bucket + CI
identity". Acceptable — both are account-foundation singletons. Their lifecycles
differ on one axis only: the bucket is `prevent_destroy`-guarded (irreversible),
the roles are not (a full teardown may delete them; the seed apply recreates them
idempotently from zero). Both are seeded by the same one operator command.

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

- **Rejected.** Leaving the roles in `envs/platform` keeps them coupled to the
  workload teardown's blast radius — the root cause. `prevent_destroy` there only
  makes `destroy-platform` *fail* (it refuses to delete a guarded resource) unless
  the resource is `state rm`'d first, so the choreography is still required and
  the orphan-role problem (consequence #2) persists: every teardown leaves
  admin-attached roles out-of-state. This is the weakest option: it treats the
  symptom (delete-order) and leaves the cause (roles in the wrong lifecycle
  layer). The CHOSEN option (a) does not adopt `prevent_destroy` on the roles at
  all — it moves them to the right layer, where a full teardown deleting them is
  fine because the seed apply recreates them from zero.

## Consequences

- **The self-delete hazard is structurally eliminated**, not worked around: the
  platform state `destroy-platform` tears down no longer contains the role it
  runs as. The `state rm` choreography is deleted from `infra-ops.yml`.
- **No `state rm` orphan**: `destroy-platform` no longer touches the destroy
  role, so it never leaves an admin-attached role out-of-state. A full
  *bootstrap* teardown (or a break-glass delete) removes the role cleanly *with*
  its state, so the next seed apply Creates rather than collides — no
  `EntityAlreadyExists`, no import.
- **Teardown-to-zero stays full** — the CI roles are not exempt. The operator may
  tear down to true zero (roles included). What changed is the cold start: it is
  now one operator command (the Cold-start runbook below), not a hand patch.
- **Cold start is idempotent from both states**: the seed `terraform apply`
  converges whether the roles exist (no-op) or were deleted (clean recreate:
  `terraform apply` refreshes state during planning, observes `NoSuchEntity` from
  `GetRole`, plans a Create — no import). This is the property that makes the
  next cold start first-class.
- **`bootstrap_complete` becomes honest**: it now literally means "state bucket +
  CI roles exist", because bootstrap creates both. After a full teardown it is
  reset to `false` (the `infra-ops` destroy-platform job already does this). The
  seed apply does **not** flip it — that is a distinct operator step (`gh variable
  set BOOTSTRAP_COMPLETE --body true`, cold-start runbook step 3) so CI is handed
  over only after the operator confirms secrets/vars are in place.
- **Repo secrets/vars do NOT need re-seeding between cycles**: the role ARNs are
  **deterministic** — `arn:aws:iam::<account_id>:role/<fixed-name>` — so they are
  identical across teardown/recreate cycles. `AWS_INFRA_APPLY_ROLE_ARN` /
  `AWS_DESTROY_ROLE_ARN` stay valid; the W3 path derives the ARN from
  `account_id` and needs no secret at all. The only repo-var that toggles is
  `BOOTSTRAP_COMPLETE`. (See the Cold-start runbook step on secrets.)
- **Downstream contracts unchanged**: `envs/regional` still reads the four role
  ARNs from the platform remote state (re-exported via data sources);
  `budget.tf`'s cost-freeze action still binds to the apply role.
- **Cost**: zero. IAM roles are free; bootstrap state stays local.

## This-cycle migration — break-glass-delete the two orphan destroy roles

After the 2026-06-12 teardown both accounts hold one orphan:
`gh-tf-destroy-platform` (AdministratorAccess attached, out of every Terraform
state — the `state rm` orphan). The apply/CI/greeter roles were deleted by the
teardown and do not exist. Per the operator decision ("這次可以全拆" — full
teardown), this cycle **deletes** the two orphans rather than importing them.
There is **no import step anywhere** — the next cold start recreates all four
roles from zero (the Cold-start runbook below).

The orphan is admin-attached, so the operator must **detach the managed policy
first, then delete the role**, per account, running as
`AWSControlTowerExecution` assumed from the **management** account (SCP denies
IAM writes to SSO principals — confirmed live 2026-06-12; the
`AWSControlTowerExecution` path is the permitted break-glass seed/teardown
principal).

```bash
# --- One-time setup: management-account credentials in the shell ---------------
# (operator's SSO into the management/payer account, or its access keys)
MGMT_PROFILE=aegis-management   # the management account profile

# Repeat the block below per account. account_id values are fixed:
#   staging = 251774439261 ; prod = 506221082337
for ACCT in 251774439261 506221082337; do
  echo "=== break-glass delete gh-tf-destroy-platform in ${ACCT} ==="

  # 1. Assume AWSControlTowerExecution into the member account.
  CREDS=$(aws sts assume-role \
    --profile "${MGMT_PROFILE}" \
    --role-arn "arn:aws:iam::${ACCT}:role/AWSControlTowerExecution" \
    --role-session-name "adr13-orphan-delete" \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
    --output text)
  export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | cut -f1)
  export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | cut -f2)
  export AWS_SESSION_TOKEN=$(echo "$CREDS" | cut -f3)

  # 2. Detach the AdministratorAccess managed policy (a role with attachments
  #    cannot be deleted — DeleteConflict otherwise).
  aws iam detach-role-policy \
    --role-name gh-tf-destroy-platform \
    --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

  # 3. (Defensive) drop any inline policy the role may carry. Empty list = no-op.
  for P in $(aws iam list-role-policies --role-name gh-tf-destroy-platform \
               --query 'PolicyNames' --output text); do
    aws iam delete-role-policy --role-name gh-tf-destroy-platform --policy-name "$P"
  done

  # 4. Delete the now-detached role.
  aws iam delete-role --role-name gh-tf-destroy-platform

  # 5. Confirm it is gone (NoSuchEntity is the success signal).
  aws iam get-role --role-name gh-tf-destroy-platform 2>&1 | grep -q NoSuchEntity \
    && echo "OK: gh-tf-destroy-platform deleted in ${ACCT}" \
    || echo "WARN: gh-tf-destroy-platform still present in ${ACCT} — investigate"

  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
done
```

After this, **both accounts are at true zero** (no CI roles, no state bucket
content beyond what `prevent_destroy` protects). The accounts are ready for the
cold-start seed below whenever the next cycle opens.

## Cold-start runbook — one operator command, from true zero

This is the formalized first-class path that replaces the old hand-typed patch.
Run it per account, on a true cold start (a fresh account, or an account torn
down to zero as above). Ordering matters; the principal differs by step.

| # | Who | Command | Why |
|---|---|---|---|
| 1 | **operator, break-glass** (`AWSControlTowerExecution` from management — SCP denies SSO) | `make bootstrap` (= `terraform -chdir=terraform/envs/bootstrap apply`, local state) | Seeds the state bucket **and** all four CI roles in one apply. Idempotent from both states: fresh account → Creates everything; roles-deleted → `terraform apply` refreshes state during planning, observes `NoSuchEntity`, plans clean Creates (no import). **Precondition:** the LZ-owned GitHub OIDC provider already exists in the account (the `data` lookup in `iam-seed.tf` depends on it — LZ bootstrap creates it). |
| 2 | operator, local | `make regenerate-backend` | Re-emit `./backend.hcl` from bootstrap outputs so downstream `platform`/`regional` envs can `init` against the new state bucket. |
| 3 | operator | `gh variable set BOOTSTRAP_COMPLETE --body true --repo BinHsu/aegis-platform-aws` (or set `accounts.json.<account>.bootstrap_complete = true` for the W3 path) | Hands the account to CI. Until this flips, `infra-plan`/`infra-apply` skip the account (they would otherwise try to assume the not-yet-seeded role). |
| 4 | CI (no operator action) | push to main → `infra-plan` assumes `aegis-platform-aws-ci` | Green plan confirms the seed worked end-to-end (closes the old "infra-plan red light"). |

**Repo secrets do NOT need re-seeding.** The role ARNs are deterministic
(`arn:aws:iam::<account_id>:role/gh-tf-apply-platform`, etc.) — identical across
every teardown/recreate cycle. `AWS_INFRA_APPLY_ROLE_ARN` and
`AWS_DESTROY_ROLE_ARN` set in a prior cycle stay valid; the W3 path derives the
ARN from `account_id` and uses no secret. **The only repo-var that toggles is
`BOOTSTRAP_COMPLETE`** (step 3). This is why the cold start is one command plus a
flag flip, not a secret-re-seeding ceremony.

## Teardown completeness — keeping "no hand patches" honest

A full-zero close-out has two equally-formal shapes; pick per cycle:

- **(i) Leave the roles, delete them next cold start as a documented operator
  command.** After `destroy-platform` (which already resets `BOOTSTRAP_COMPLETE`
  to `false`), the four roles linger until the operator runs the break-glass
  delete block above. A single documented command is a **formal path, not a
  patch** — so "lingering until an operator command" is honest.
- **(ii) `terraform destroy` on `envs/bootstrap` minus the bucket.** Because the
  roles carry no `prevent_destroy`, `terraform -chdir=terraform/envs/bootstrap
  destroy -target=…` (targeting the four roles + their attachments, **not** the
  `prevent_destroy`-guarded bucket) removes them *with* their state — no orphan,
  the next seed apply Creates cleanly. Run as break-glass (SCP).

Both reach true zero with no hand patch. Shape (i) is the lighter default for a
routine cycle (the destroy-platform already happened; the roles are free and
deleting them is optional cleanup); shape (ii) is the choice when the operator
wants the account provably empty of CI identity in the same teardown window. This
cycle used shape (i) — the break-glass delete block above is that documented
operator command.

## Related ADRs

- [ADR-03](03-delivery-cicd-gitops.md) — the two-OIDC-role CI trust split + the
  LZ-owned OIDC provider; this ADR moves the *roles* (not the provider) to the
  seed layer.
- [ADR-11](11-account-dimension-single-source-of-truth.md) — role/bucket names
  derive from `account_id`; this ADR keeps that derivation in `iam-seed.tf`.
- Enclave ADR-0052 — the same boundary in the sibling repo: LZ owns the OIDC
  provider, the consumer repo's own CI role lives in the consumer's own bootstrap.
