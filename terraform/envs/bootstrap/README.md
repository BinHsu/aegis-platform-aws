# bootstrap env — the per-account seed layer

Creates the S3 bucket that the `platform/` and `regional/` envs use as their remote backend, **and** seeds the four CI IAM roles (the GitHub OIDC trust + apply / destroy / plan / greeter-push roles) — see [ADR-13](../../../docs/adr/13-ci-iam-roles-survive-teardown.md). **No DynamoDB lock table** — TF ≥ 1.11 supports native S3 conditional-write locking via `use_lockfile = true` in each downstream backend block (DynamoDB-based locking is deprecated upstream and will be removed in a future minor version).

## The seed layer — local state, break-glass-applied, cold-start-from-zero

This env's own state is **local** (gitignored `terraform.tfstate`) by design: migrating bootstrap state into the very bucket it provisions would create a chicken-and-egg cycle.

Only the **state bucket** carries `lifecycle { prevent_destroy = true }` — losing it loses every downstream env's state (irreversible). The four CI roles (`iam-seed.tf`, ADR-13) carry **no** such guard: they are cheaply, idempotently recreatable, so a full teardown may delete them and a later seed apply restores them from zero.

**The seed apply runs from the operator's laptop as break-glass / `AWSControlTowerExecution`** (a principal the org SCP permits to write IAM — SSO principals are denied). The roles cannot create themselves; the seed principal must. After the seed exists, the `infra-ops` bootstrap job (which assumes `gh-tf-apply-platform`) can re-apply to reconcile baseline drift.

`destroy-platform` (the workload teardown) no longer touches these roles — they live here, not in the platform state — so the self-delete hazard / orphan-role / cold-start chicken-egg observed 2026-06-12 are structurally gone. **Teardown-to-zero stays full** (the roles are not exempt); what changed is the **cold-start contract**: one operator command (`make bootstrap`) seeds bucket + roles from true zero. Idempotent from both states — roles exist (no-op) or roles deleted (clean recreate via `terraform refresh`, no import). Full cold-start sequence + the per-account break-glass orphan-delete commands: [ADR-13](../../../docs/adr/13-ci-iam-roles-survive-teardown.md) (Cold-start runbook + This-cycle migration).

## Prerequisites (forker cold-start checklist)

Before running `make bootstrap` in a fresh fork or a fresh AWS account, satisfy every row in this table.

| Requirement | This repo's setup | Forker action |
|---|---|---|
| **AWS account** (or member account in an org) | Staging `251774439261`, prod `506221082337` (example IDs — your account IDs differ) | Any AWS account with billing enabled. Member account in an org is fine; standalone account works too. |
| **Admin-capable principal for the one-time bootstrap apply** | `AWSControlTowerExecution` (org SCP permits this role to write IAM; SSO principals are denied by the SCP) | Any IAM principal with `iam:CreateRole` + `iam:AttachRolePolicy` in the target account. If you have no org SCP blocking IAM writes, your own IAM admin user or SSO admin role works directly. If you do have an org SCP blocking SSO principals (as we do), use your equivalent break-glass role. |
| **GitHub Actions OIDC provider in the target account** | Owned by the landing-zone repo (`iam:CreateOpenIDConnectProvider` runs there). `iam-seed.tf` references it via `data` source — it must already exist. | Create it once per account if it does not exist: Provider URL = `https://token.actions.githubusercontent.com`, Audience = `sts.amazonaws.com`. AWS console: IAM → Identity providers → Add provider → OpenID Connect. CLI: `aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com --client-id-list sts.amazonaws.com --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1`. |
| **`github_owner` set in `regions.auto.tfvars.json`** | `"github_owner": "BinHsu"` in the committed example. | Set `github_owner` to your GitHub org or username before running `make bootstrap`. This value is embedded in every OIDC trust `sub` condition in `iam-seed.tf` — an incorrect value means CI cannot assume any of the four roles. No default is provided; Terraform will error if the variable is unset. |
| **GitHub repo secrets and variables** (see table below) | Set in `BinHsu/aegis-platform-aws` — your fork needs its own values | Set per-account values in your fork's Settings → Secrets and variables → Actions |

### Required GitHub Actions secrets and variables

Values marked **deterministic** can be derived from your account ID without a cloud lookup.

| Name | Type | Value / how to derive |
|---|---|---|
| `AWS_INFRA_APPLY_ROLE_ARN` | Secret | `arn:aws:iam::<account_id>:role/gh-tf-apply-platform` — **deterministic** from account ID; set after bootstrap apply creates the role. |
| `AWS_INFRA_CI_ROLE_ARN` | Secret | `arn:aws:iam::<account_id>:role/aegis-platform-aws-ci` — **deterministic**; set after bootstrap apply. |
| `TFSTATE_REGION` | Secret | The AWS region where the state bucket was created (the `platform_region` you set in `regions.auto.tfvars.json` before bootstrap). |
| `TFSTATE_BUCKET` | Secret | `aegis-platform-aws-tfstate-<account_id>` — **deterministic**; also emitted by `terraform output backend_hcl` after bootstrap. |
| `GH_DEPLOY_KEY_PAT` | Secret | A GitHub fine-grained PAT with `variables:write` permission on this repo (GITHUB_TOKEN cannot write repo variables). |
| `OPERATOR_PRINCIPAL_ARN` | Secret | ARN of the operator's IAM principal that the EKS access entry grants `cluster-admin` (e.g. your SSO role ARN, or your IAM user ARN). |
| `BUDGET_ALERT_EMAIL` | Secret | Email address for AWS Budgets threshold alerts. |
| `BOOTSTRAP_COMPLETE` | Variable | `false` initially; set to `true` after bootstrap apply + secrets are in place (step 3 in the cold-start order below). |
| `REGISTRIES_JSON` | Variable | JSON blob listing ECR registry IDs by account; see `registries.auto.tfvars.json.example` for the schema. |
| Grafana Cloud secrets (`GRAFANA_CLOUD_API_TOKEN`, etc.) | Secrets | Optional — only needed if `ENABLE_CLOUDWATCH_DATASOURCE=true`. Obtain from your Grafana Cloud stack. |

### Cold-start order

1. **Operator (break-glass / admin principal), local laptop** — run `make bootstrap`. This creates the state bucket and all four CI roles in one apply (`iam-seed.tf`). Precondition: the GitHub OIDC provider row above is satisfied.
2. **Operator, local** — run `make regenerate-backend` to emit `./backend.hcl` from bootstrap outputs. Downstream envs (`platform`/`regional`) use this file on `terraform init`.
3. **Operator** — set all the GitHub secrets/variables above in your fork's Actions settings. Then set `BOOTSTRAP_COMPLETE = true` (the variable) to hand the account to CI.
4. **CI (no operator action)** — push to main; `infra-plan` assumes `aegis-platform-aws-ci` and runs a read-only plan. Green plan confirms the OIDC trust is wired correctly end-to-end.

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
