# bootstrap env — the per-account seed layer

Creates the S3 bucket that the `platform/` and `regional/` envs use as their remote backend, **and** seeds the four CI IAM roles (the GitHub OIDC trust + apply / destroy / plan / greeter-push roles) — see [ADR-13](../../../docs/adr/13-ci-iam-roles-survive-teardown.md). **No DynamoDB lock table** — TF ≥ 1.11 supports native S3 conditional-write locking via `use_lockfile = true` in each downstream backend block (DynamoDB-based locking is deprecated upstream and will be removed in a future minor version).

## The seed layer — local state, break-glass-applied, cold-start-from-zero

This env's own state is **local** (gitignored `terraform.tfstate`) by design: migrating bootstrap state into the very bucket it provisions would create a chicken-and-egg cycle.

Only the **state bucket** carries `lifecycle { prevent_destroy = true }` — losing it loses every downstream env's state (irreversible). The four CI roles (`iam-seed.tf`, ADR-13) carry **no** such guard: they are cheaply, idempotently recreatable, so a full teardown may delete them and a later seed apply restores them from zero.

**The seed apply runs from the operator's laptop as break-glass / `AWSControlTowerExecution`** (a principal the org SCP permits to write IAM — SSO principals are denied). The roles cannot create themselves; the seed principal must. After the seed exists, the `infra-ops` bootstrap job (which assumes `gh-tf-apply-platform`) can re-apply to reconcile baseline drift.

`destroy-platform` (the workload teardown) no longer touches these roles — they live here, not in the platform state — so the self-delete hazard / orphan-role / cold-start chicken-egg observed 2026-06-12 are structurally gone. **Teardown-to-zero stays full** (the roles are not exempt); what changed is the **cold-start contract**: one operator command (`make bootstrap`) seeds bucket + roles from true zero. Idempotent from both states — roles exist (no-op) or roles deleted (clean recreate via `terraform refresh`, no import). Full cold-start sequence + the per-account break-glass orphan-delete commands: [ADR-13](../../../docs/adr/13-ci-iam-roles-survive-teardown.md) (Cold-start runbook + This-cycle migration).

## Usage

```bash
make bootstrap   # local-state apply (reads regions.auto.tfvars.json for platform_region)
```

After apply, the Makefile reads the `backend_hcl` output and writes a `backend.hcl` file at repo root (gitignored). Downstream envs then run `terraform init -backend-config=$(ROOT)/backend.hcl`.

## What it creates

| Resource | Why |
|---|---|
| S3 bucket `aegis-platform-aws-tfstate-${account_id}` | Remote state for platform + regional. Versioned + SSE-KMS (`alias/aws/s3`) + Block Public Access. Lock files live at `<state_key>.tflock` in the same bucket (TF ≥ 1.11 native locking via PutObject IfNoneMatch). |
| `gh-tf-apply-platform` | CI `terraform apply` (AdministratorAccess). Trust = `refs/heads/main` + the apply environments. `iam-seed.tf`. |
| `gh-tf-destroy-platform` | CI `terraform destroy` (AdministratorAccess; A7 destroy-scoped policy staged in `destroy-policy.tf`). Trust = `environment:destroy` / `:reaper-destroy`. `iam-seed.tf`. |
| `aegis-platform-aws-ci` | CI `terraform plan` (ReadOnlyAccess), any ref/PR. `iam-seed.tf`. |
| `aegis-greeter-ci` | aegis-greeter ECR push, main-ref only. `iam-seed.tf`. |

## Production hardening (out of scope, documented in tradeoffs)

- Customer-managed KMS key (granular key policy + cross-account access) instead of `aws/s3`.
- S3 Object Lock for compliance write-once semantics.
- Cross-region replication of the state bucket for region-failure resilience.
