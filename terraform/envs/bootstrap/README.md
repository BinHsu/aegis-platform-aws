# bootstrap env — the per-account seed layer

Creates the S3 bucket that the `platform/` and `regional/` envs use as their remote backend, **and** seeds the four CI IAM roles (the GitHub OIDC trust + apply / destroy / plan / greeter-push roles) — see [ADR-13](../../../docs/adr/13-ci-iam-roles-survive-teardown.md). **No DynamoDB lock table** — TF ≥ 1.11 supports native S3 conditional-write locking via `use_lockfile = true` in each downstream backend block (DynamoDB-based locking is deprecated upstream and will be removed in a future minor version).

## Apply once, never destroy — and the roles persist through teardown-to-zero

This env's own state is **local** (gitignored `terraform.tfstate`) by design: migrating bootstrap state into the very bucket it provisions would create a chicken-and-egg cycle. Bootstrap is intentionally one-shot.

Every resource here carries `lifecycle { prevent_destroy = true }` — the state bucket and the four CI roles. To remove any of them, an operator must edit that block first.

**Day-zero seed runs from the operator's laptop as break-glass / `AWSControlTowerExecution`** (a principal the org SCP permits to write IAM — SSO principals are denied). The roles cannot create themselves; the seed principal must. After day zero, the `infra-ops` bootstrap job (which assumes `gh-tf-apply-platform`) can re-apply to reconcile baseline drift — `prevent_destroy` keeps a re-apply from ever deleting the roles.

This is why `destroy-platform` leaves the account at **zero billable + zero workload** while the free CI federation roles persist (ADR-13): the roles live here, not in the platform state the teardown destroys, so the self-delete hazard / orphan-role / cold-start chicken-egg observed 2026-06-12 are structurally gone.

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
