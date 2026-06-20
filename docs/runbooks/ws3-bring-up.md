# WS3 bring-up runbook — first apply of the platform (staging → prod)

> **Status:** authored 2026-06-17. The platform was applied + torn down on the
> 6/12 joint-strike; teardown deleted all infra + the CI roles, so today there
> are **zero live billable resources** (no EKS) — but the state buckets survived
> (`prevent_destroy`) with empty post-destroy state, and `bootstrap_complete` is
> still `false`. So bootstrap must be **re-run** (idempotent; re-seeds the roles,
> adopts the bucket). `terraform apply` is **billable**.
> Tags: **[YOU]** = manual operator step · **[AUTO]** = CI/Terraform does it.

Accounts (from `accounts.json`): staging `251774439261` · prod `506221082337` ·
deployment `162975888022`. Region `eu-central-1`.
**DNS (WS3-R):** per-env subdomain under `aws.binhsu.org` — the `binhsu.org` apex
stays on **Cloudflare** (personal homepage); each account owns its own Route 53
zone `<env>.aws.binhsu.org`, delegated directly from Cloudflare.
Path: the **W3** path (`infra-staging.yml` / `infra-prod.yml` + `accounts.json`),
not the legacy `infra-apply.yml`.

Deterministic per-account names (no need to look up — derived from account id):
- state bucket `aegis-platform-aws-tfstate-<acct>`
- apply role `arn:aws:iam::<acct>:role/gh-tf-apply-platform`
- CI plan role `arn:aws:iam::<acct>:role/aegis-platform-aws-ci`
- model-read policy `arn:aws:iam::<acct>:policy/aegis-core-model-read`
- zones: prod = `prod.aws.binhsu.org`, staging = `staging.aws.binhsu.org`
- hosts: staging `aegis-api.staging.aws.binhsu.org` / `app.staging.aws.binhsu.org`;
  prod `aegis-api.prod.aws.binhsu.org` / `app.prod.aws.binhsu.org`

---

## Phase 0 — prerequisites (one-time)

1. **[YOU] Domain.** `binhsu.org` is on **Cloudflare** (personal homepage — apex untouched). You'll add per-env `NS` records under it to delegate `<env>.aws.binhsu.org` to Route 53 (Phase 5).
2. **[YOU] GitHub OIDC provider** in BOTH cluster accounts (usually already seeded by the landing zone). If missing in an account:
   ```bash
   aws iam create-open-id-connect-provider \
     --url https://token.actions.githubusercontent.com \
     --client-id-list sts.amazonaws.com \
     --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
   ```
3. **[YOU] Break-glass admin creds** per account (the org SCP blocks SSO from `iam:CreateRole`). Intended principal: `AWSControlTowerExecution` (or equivalent IAM-admin/break-glass role). Bootstrap day-zero MUST run as this.
4. **[YOU] Member-account Cost Explorer access** enabled in the management console (else `aws_ce_anomaly_*` fails at platform apply). Joint-strike §B step 1.

---

## Phase 1 — bootstrap STAGING (break-glass creds)

`make bootstrap` runs LOCAL-state Terraform that creates the 6 CI roles (ADR-13 —
`iam:CreateRole`) and manages the S3 state bucket. The org SCP
`deny-iam-privilege-escalation` denies `iam:CreateRole` for SSO; it exempts
`AWSControlTowerExecution`, `aegis-emergency-*`, `gh-tf-*`, etc. The per-account
`aegis-emergency-break-glass` role is the self-serve option BUT its S3 grant is
scoped to a DIFFERENT project's bucket (`aegis-statefulset-tfstate-*`) — it
cannot even refresh `aegis-platform-aws-tfstate-*`, so it FAILS this bootstrap.
Use the full-admin **`AWSControlTowerExecution`** (assumed from the management
account) for this one-time cold start; afterwards `gh-tf-apply-platform` (also
SCP-exempt) runs every apply via CI/OIDC — no more break-glass.

> The bootstrap LOCAL state (`terraform/envs/bootstrap/terraform.tfstate`,
> gitignored) survived 6/12 and already tracks the state bucket → no import; the
> apply just re-creates the (deleted) roles, bucket is a no-op refresh.

```bash
creds=$(aws sts assume-role --role-arn arn:aws:iam::251774439261:role/AWSControlTowerExecution --role-session-name bootstrap-staging --profile aegis-management-admin --query Credentials --output json)
export AWS_ACCESS_KEY_ID=$(echo "$creds" | jq -r .AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(echo "$creds" | jq -r .SecretAccessKey)
export AWS_SESSION_TOKEN=$(echo "$creds" | jq -r .SessionToken)
aws sts get-caller-identity --query Arn --output text
cd /path/to/aegis-platform-aws
make bootstrap ENV=staging          # ENV selects the per-account workspace (issue #90)
make regenerate-backend ENV=staging
terraform -chdir=terraform/envs/bootstrap output
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
```
(Prod bootstrap, Phase 7: same with `506221082337` and `ENV=prod` — each account
gets its own workspace, so staging and prod local state no longer collide.
AWSControlTowerExecution is assumed from `--profile aegis-management-admin` in
both cases.)

This creates in staging: `gh-tf-apply-platform`, `gh-tf-destroy-platform`,
`aegis-platform-aws-ci`, `aegis-greeter-ci`, `github-actions-aegis-core-ecr`,
`github-actions-aegis-core-frontend`, + the state bucket.

---

## Phase 1b — deployment-account trust is now Terraform-managed (ADR-10)

Verified read-only on `aegis-deployments` (162975888022): GitHub OIDC,
`AWSControlTowerExecution`, `gh-tf-apply-deployment` (AdministratorAccess),
`aegis-greeter-ci-push` + the `aegis-greeter` ECR all **already exist** (6/12
survivors). The `aegis-core` ECR + `aegis-core-ci-push` are created by the
platform apply's `deployment-ecr.tf` (`shared_core`) — no manual seed.

**The manual break-glass trust patch is RETIRED.** `gh-tf-apply-deployment` — the
role + its trust + its AdministratorAccess attachment — is now Terraform-managed
in the landing-zone `deployment/bootstrap` layer
(`terraform/environments/deployment/bootstrap/oidc-github-apply-deployment-role.tf`).
Apply that layer (via `gh-tf-apply-baseline`, the landing-zone CI apply role) and
the trust is reproducible — it no longer dangles on a deleted role id, and it now
trusts BOTH platform CI roles:

- `gh-tf-apply-platform` — used by the platform APPLY (`infra-apply-account.yml`).
- `gh-tf-destroy-platform` — used by the platform DESTROY (`infra-ops.yml`
  destroy-platform). The earlier hand-patched trust permitted only the apply role,
  so `destroy-platform` got `AssumeRole` AccessDenied configuring the
  `aws.deployment` provider and aborted before deleting the shared-registry
  resources. Trusting the destroy role too closes that cross-account teardown gap.

Only **staging**'s roles are trusted today — staging owns `deployment_account_id`
in `accounts.json`, so it is the only apply/destroy context that assumes this role.
To move registry ownership to prod, add prod's account id to
`deployment_owning_platform_account_ids` in that landing-zone file IN LOCK-STEP
with moving the `deployment_account_id` field in `accounts.json`.

> Historical: before this was Terraform-managed, the trust was re-pointed by hand
> via `aws iam update-assume-role-policy` through `AWSControlTowerExecution`
> break-glass (SCP blocks SSO from IAM writes). That manual step is obsolete — do
> not run it; apply the landing-zone layer instead.

---

## Phase 2 — GitHub config on `aegis-platform-aws` (one-time, serves both accounts)

The W3 apply path derives the account's role + bucket inline from `account_id`,
so most account-specific values are NOT secrets. Set these **repo secrets**
(Settings → Secrets and variables → Actions). They are account-agnostic:

| Secret | Value / source |
|---|---|
| `TFSTATE_REGION` | `eu-central-1` |
| `GH_DEPLOY_KEY_PAT` | fine-grained PAT: `variables:write` + `contents:write` on this repo (ArgoCD deploy keys via `TF_VAR_github_token`) |
| `BUDGET_ALERT_EMAIL` | your alert email |
| `GRAFANA_CLOUD_API_TOKEN` | `glc_…` (metrics/logs/traces/profiles write) |
| `GRAFANA_AUTH_TOKEN` | `glsa_…` (Admin; the `grafana` TF provider) |
| `GRAFANA_CLOUD_MIMIR_USERNAME` / `_URL` | Mimir instance-id / push URL |
| `GRAFANA_CLOUD_LOKI_USERNAME` / `_URL` | Loki instance-id / push URL |
| `GRAFANA_CLOUD_TEMPO_USERNAME` / `_URL` | Tempo instance-id / OTLP host:port |
| `GRAFANA_CLOUD_PYROSCOPE_USERNAME` / `_URL` | Pyroscope instance-id / push URL |
| `AWS_INFRA_CI_ROLE_ARN` | `arn:aws:iam::251774439261:role/aegis-platform-aws-ci` (staging — the PR-plan `infra-plan.yml` read-only role) |
| `AWS_INFRA_APPLY_ROLE_ARN` | `arn:aws:iam::251774439261:role/gh-tf-apply-platform` (staging — only the LEGACY break-glass `infra-apply.yml`; the W3 path does not use it) |
| `TFSTATE_BUCKET` | `aegis-platform-aws-tfstate-251774439261` (staging — used by BOTH `infra-plan.yml` and the legacy `infra-apply.yml`) |

> These three are for the LEGACY workflows only (`infra-plan.yml` PR plan + the
> `infra-apply.yml` break-glass dispatch), so they carry staging values. The W3
> apply path (`infra-staging.yml` / `infra-prod.yml`) derives the per-account
> role (`gh-tf-apply-platform`) + bucket inline from `accounts.json` — operators
> set NO per-account apply-role/bucket secrets for W3.

**Repo variables:**

| Variable | Value |
|---|---|
| `REGISTRIES_JSON` | the full `registries.auto.tfvars.json` contents (see Phase 5 — set the deterministic `model-read` policy ARN now; cert_arn omitted — auto per-region; ConfigMaps auto-injected) |
| `BOOTSTRAP_COMPLETE` | `true` (gates the legacy `infra-plan.yml` PR plan; the W3 apply gates on `accounts.json` instead) |
| `ENABLE_CLOUDWATCH_DATASOURCE` | `false` (set `true` only with the two extra Grafana CW secrets) |

**GitHub Environments** (Settings → Environments):

| Environment | Reviewers |
|---|---|
| `staging` | none (ungated) |
| `prod-apply` | none |
| `prod-apply-gated` | **required reviewer = you** |
| `destroy` | **required reviewer = you** |
| `reaper-destroy` | none |

---

## Phase 3 — REGISTRIES_JSON content (set in Phase 2's variable)

Copy `registries.auto.tfvars.json.example`, fill the gitignored real values. The
deterministic model-read policy ARN can be set NOW (it doesn't need the apply):

```json
{
  "workload_registries": {
    "aegis-greeter-deploy": { "ecr_account_id": "162975888022", "ecr_region": "eu-central-1" },
    "aegis-core-deploy": {
      "ecr_account_id": "162975888022",
      "ecr_region": "eu-central-1",
      "engine_irsa": {
        "service_account": "aegis-core-engine",
        "role_name": "aegis-workload/aegis-core-engine",
        "policy_arns": ["arn:aws:iam::251774439261:policy/aegis-core-model-read"]
      },
      "ingress_cert": { "ingress_name": "aegis-core-gateway" }
    }
  }
}
```
(For the prod account the `policy_arns` ARN uses `506221082337`. WS3-R: cert_arn
is OMITTED — the per-region module cert is injected automatically; the model
bucket + Cognito ConfigMaps are filled by the ApplicationSet from platform
outputs — no hand-wiring.)

---

## Phase 4 — first STAGING apply (flip the gate → auto-applies)

1. **[YOU]** Edit `accounts.json`: `accounts.staging.bootstrap_complete = true`. Commit + merge to `main`.
2. **[AUTO]** The merge triggers `infra-staging.yml` → `infra-apply-account.yml`:
   `version-gate` → `apply-platform` (Cognito pool/client, model S3 bucket + read policy, **`staging.aws.binhsu.org` Route53 zone**, ECR, + the deployment-account `shared_core` ECR via the `gh-tf-apply-deployment` assume) → `apply-regional` (EKS `aegis-platform-eu-central-1`, **per-region ACM cert**, ALB controller, external-dns, ACK, ArgoCD + the aegis-core/greeter Applications). `apply-regional` runs in the ungated `staging` environment.
3. **[YOU]** Watch the run green (`gh run watch`). **Billable from here** — EKS + NAT + ALB.

---

## Phase 5 — Cloudflare per-env delegation (do this BEFORE the full apply)

Each env account owns its own zone `<env>.aws.binhsu.org`, delegated DIRECTLY
from Cloudflare (no AWS-side cross-account delegation). `binhsu.org` apex +
homepage stay untouched on Cloudflare. To avoid the regional ACM validation
waiting on un-delegated DNS, **pre-create the zone and delegate before the full
regional apply** (the W3 auto-apply runs platform→regional in one shot, so there
is no pause between them):

1. **[YOU]** After Phase 1 bootstrap, targeted-apply JUST the zone (per account, using the apply role or break-glass):
   ```bash
   terraform -chdir=terraform/envs/platform apply -target=aws_route53_zone.main
   terraform -chdir=terraform/envs/platform output zone_name_servers   # the 4 NS for <env>.aws.binhsu.org
   ```
2. **[YOU]** In **Cloudflare** (the `binhsu.org` zone), add ONE `NS` record per env, pointing the subdomain at that account's 4 NS:
   - Name `staging.aws` (i.e. `staging.aws.binhsu.org`) → the staging zone's 4 NS
   - Name `prod.aws` (i.e. `prod.aws.binhsu.org`) → the prod zone's 4 NS
   (Cloudflare → DNS → Records → Add record → Type NS, one per NS value, or one record set.)
3. **[YOU]** Confirm delegation: `dig NS staging.aws.binhsu.org +short` returns the AWS NS.

After this, the full apply's regional ACM DNS-01 validation resolves immediately
(no wait). If you skip the pre-create and just flip the gate (Phase 4), the
`apply-regional` ACM step will WAIT for you to add the Cloudflare NS within its
validation timeout.

---

## Phase 6 — verify STAGING

- **[AUTO/YOU]** ArgoCD syncs aegis-core (engine + gateway) and greeter. The
  ApplicationSet injects: registry, region, engine IRSA role-arn + model-read
  policyArns, the per-region cert onto the gateway Ingress, and fills the
  model-store + gateway-oidc ConfigMaps from the Cognito/bucket outputs.
- **[YOU]** Seed a Cognito user (`aws cognito-idp admin-create-user …` — sign-up
  is admin-only). Confirm gateway 200 over HTTPS at `https://aegis-api.staging.aws.binhsu.org`
  and the SPA at `app.staging.aws.binhsu.org` (after the frontend deploy, Phase 8).
- **[YOU]** `dig aegis-api.staging.aws.binhsu.org` resolves to the ALB.

---

## Phase 7 — PROD (deliberate promotion)

1. **[YOU]** Bootstrap prod (Phase 1 with prod break-glass creds) if not done in Phase 5.
2. **[YOU]** `accounts.prod.bootstrap_complete = true` (merge — does NOT auto-apply prod; the prod trigger is the pin change).
3. **[YOU]** Cut a release tag at the verified commit.
4. **[YOU]** Open a PR changing `accounts.prod.pin` from `v0.0.0-PLACEHOLDER` → the tag. Merge to main.
5. **[AUTO]** `infra-prod.yml` detects the pin change → `infra-apply-account.yml` at the tag → `version-gate` (hard-fails if EKS past support) → `apply-platform` → `apply-regional` in **`prod-apply-gated`**.
6. **[YOU] APPROVE** the `prod-apply-gated` deployment.
7. **[YOU]** Verify prod (same as Phase 6, on `prod.aws.binhsu.org`).

---

## Phase 8 — aegis-core app pipeline + frontend (merge #148)

1. **[YOU]** Set aegis-core repo secrets/vars: `AEGIS_CORE_DEPLOY_PAT` (contents+PR write on aegis-core-deploy), `AWS_ACCOUNT_ID`, `AWS_REGION`, `ECR_PUSH_ROLE_NAME`, `ECR_REPO_NAME`, `FRONTEND_*`, `GATEWAY_DOMAIN`, `BUILDBUDDY_API_KEY`.
2. **[YOU]** Merge aegis-core **#148** (held until now to avoid a pre-bootstrap red ECR-push run). On merge, `release-staging-image.yml` builds + pushes engine+gateway to ECR and opens the digest-pin PR on aegis-core-deploy; `release-staging-frontend.yml` builds the SPA, writes the cloud `config.json`, and syncs to the frontend S3 + CloudFront.
3. **[AUTO]** ArgoCD rolls the pinned digests.

---

## Phase 9 — TWO REGIONS (prod only, validates multi-region/DR)

**Decision (2026-06-17): staging stays single-region (`eu-central-1`); prod is dual-region (`eu-central-1` + `eu-west-1`).** Separation of concerns — staging validates the complete flow and function (gateway OIDC, frontend PKCE, engine model-pull, ArgoCD sync, ACM/HTTPS, Cognito login), for which one region suffices and double-billing EKS adds no proof value. Prod adds the one dimension single-region cannot exercise: external-dns coexisting latency records, Route53 health-failover, ECR cross-region replication — the ADR-05 DR posture. Function correctness converges in staging; multi-region/DR is validated only at prod, and the second EKS bill (~+$0.20/hr, dual-region prod ~$0.40/hr) is paid only when actually validating multi-region.

Wiring is ready (per-region cert + latency DNS + per-region ecr_region). To turn on eu-west-1 **at the prod phase**:
1. **[YOU]** `regions.auto.tfvars.json`: set `eu-west-1.enabled = true` (global flag → ECR replication makes eu-west-1 a real destination).
2. **[YOU]** `accounts.json`: add `"eu-west-1"` to **prod's** `enabled_regions` only — leave staging at `["eu-central-1"]`; the per-account gate keeps the two environments isolated.
3. **[AUTO]** Next apply runs `apply-regional` for both regions (matrix). Each region gets its own EKS + ACM cert; external-dns writes coexisting latency records for `aegis-api.<zone>`; ECR replication (already configured) serves the second region.
4. **[YOU]** Confirm Route53 shows two latency records and `dig` returns the nearest region.

---

## Teardown (post-verify, to stop billing) — joint-strike §G gotchas
- `make destroy-region REGION=…` then `make destroy-platform` (or `infra-ops` destroy with approval).
- Known: `VPC DependencyViolation` from orphaned ALB SGs (two-phase sweep handles it); ECR `RepositoryNotEmptyException` (force_delete needs a prior apply cycle); after `destroy-platform`, flip `bootstrap_complete`/`BOOTSTRAP_COMPLETE` back to false or the next plan assumes a deleted role and reds.

---

## What is already DONE (merged, no apply)
WS3 terraform + manifests are on `main`: PRs #86, #13 (WS3), #87, #14 (WS3-R two-region/HTTPS/naming). Only aegis-core **#148** is intentionally still open (Phase 8). Nothing is applied — this runbook is the first apply.
