# WS3 bring-up runbook — first apply of the platform (staging → prod)

> **Status:** authored 2026-06-17. The platform has NEVER been applied
> (`bootstrap_complete:false` both accounts → zero live resources). Everything
> below is the operator (human) path; `terraform apply` is **billable**.
> Tags: **[YOU]** = manual operator step · **[AUTO]** = CI/Terraform does it.

Accounts (from `accounts.json`): staging `251774439261` · prod `506221082337` ·
deployment `162975888022`. Region `eu-central-1`. Domain `binhsu.org`.
Path: the **W3** path (`infra-staging.yml` / `infra-prod.yml` + `accounts.json`),
not the legacy `infra-apply.yml`.

Deterministic per-account names (no need to look up — derived from account id):
- state bucket `aegis-platform-aws-tfstate-<acct>`
- apply role `arn:aws:iam::<acct>:role/gh-tf-apply-platform`
- CI plan role `arn:aws:iam::<acct>:role/aegis-platform-aws-ci`
- model-read policy `arn:aws:iam::<acct>:policy/aegis-core-model-read`
- zones: prod = `binhsu.org`, staging = `staging.binhsu.org`
- hosts: staging `aegis-api.staging.binhsu.org` / `app.staging.binhsu.org`;
  prod `aegis-api.binhsu.org` / `app.binhsu.org`

---

## Phase 0 — prerequisites (one-time)

1. **[YOU] Domain.** `binhsu.org` registered and you can edit its NS at the registrar.
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

`make bootstrap` runs LOCAL-state Terraform that creates the S3 state bucket +
the 6 CI roles (ADR-13). Run as the staging break-glass principal:

```bash
export AWS_PROFILE=<staging-break-glass>     # AWSControlTowerExecution or equiv
cd /path/to/aegis-platform-aws
make bootstrap                # terraform/envs/bootstrap apply (LOCAL state)
make regenerate-backend       # emits ./backend.hcl (gitignored)
terraform -chdir=terraform/envs/bootstrap output    # note the role ARNs + bucket
```

This creates in staging: `gh-tf-apply-platform`, `gh-tf-destroy-platform`,
`aegis-platform-aws-ci`, `aegis-greeter-ci`, `github-actions-aegis-core-ecr`,
`github-actions-aegis-core-frontend`, + the state bucket.

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
| `AWS_INFRA_CI_ROLE_ARN` | `arn:aws:iam::251774439261:role/aegis-platform-aws-ci` (staging — the PR-plan `infra-plan.yml` target) |
| `TFSTATE_BUCKET` | `aegis-platform-aws-tfstate-251774439261` (staging — `infra-plan.yml`) |

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
   `version-gate` → `apply-platform` (Cognito pool/client, model S3 bucket + read policy, **`staging.binhsu.org` Route53 zone**, ECR) → `apply-regional` (EKS `aegis-platform-eu-central-1`, **per-region ACM cert**, ALB controller, external-dns, ACK, ArgoCD + the aegis-core/greeter Applications). `apply-regional` runs in the ungated `staging` environment.
3. **[YOU]** Watch the run green (`gh run watch`). **Billable from here** — EKS + NAT + ALB.

---

## Phase 5 — DNS delegation (after the zones exist)

The apex `binhsu.org` lives in the **prod** account; `staging.binhsu.org` in
staging. So DNS resolves only after both zones exist and are delegated:

1. **[YOU]** After staging `apply-platform`, read the staging zone NS:
   ```bash
   terraform -chdir=terraform/envs/platform output zone_name_servers   # staging.binhsu.org NS
   ```
   (Or from the AWS console → Route53 → `staging.binhsu.org`.)
2. **[YOU]** Bootstrap + apply the **prod** platform too (Phase 1 + 4 for prod, or at least its platform env) so the apex `binhsu.org` zone exists; read its NS.
3. **[YOU]** At the **registrar**, point `binhsu.org` NS → the prod apex zone's 4 NS.
4. **[YOU]** Tell the prod apex to delegate the staging subdomain: set in the prod account's `registries`/tfvars `delegated_subdomains`:
   ```hcl
   delegated_subdomains = { "staging.binhsu.org" = [ <the 4 staging-zone NS> ] }
   ```
   (Passed as `TF_VAR_delegated_subdomains` or a tfvars entry; re-apply prod platform.) Then ACM DNS-01 validation for `*.staging.binhsu.org` resolves and the staging `apply-regional` cert validation completes.

> Until delegation resolves, the regional ACM `aws_acm_certificate_validation`
> waits (up to its timeout) — do Phase 5 promptly after Phase 4, or expect the
> first regional apply's cert step to retry.

---

## Phase 6 — verify STAGING

- **[AUTO/YOU]** ArgoCD syncs aegis-core (engine + gateway) and greeter. The
  ApplicationSet injects: registry, region, engine IRSA role-arn + model-read
  policyArns, the per-region cert onto the gateway Ingress, and fills the
  model-store + gateway-oidc ConfigMaps from the Cognito/bucket outputs.
- **[YOU]** Seed a Cognito user (`aws cognito-idp admin-create-user …` — sign-up
  is admin-only). Confirm gateway 200 over HTTPS at `https://aegis-api.staging.binhsu.org`
  and the SPA at `app.staging.binhsu.org` (after the frontend deploy, Phase 8).
- **[YOU]** `dig aegis-api.staging.binhsu.org` resolves to the ALB.

---

## Phase 7 — PROD (deliberate promotion)

1. **[YOU]** Bootstrap prod (Phase 1 with prod break-glass creds) if not done in Phase 5.
2. **[YOU]** `accounts.prod.bootstrap_complete = true` (merge — does NOT auto-apply prod; the prod trigger is the pin change).
3. **[YOU]** Cut a release tag at the verified commit.
4. **[YOU]** Open a PR changing `accounts.prod.pin` from `v0.0.0-PLACEHOLDER` → the tag. Merge to main.
5. **[AUTO]** `infra-prod.yml` detects the pin change → `infra-apply-account.yml` at the tag → `version-gate` (hard-fails if EKS past support) → `apply-platform` → `apply-regional` in **`prod-apply-gated`**.
6. **[YOU] APPROVE** the `prod-apply-gated` deployment.
7. **[YOU]** Verify prod (same as Phase 6, on `binhsu.org`).

---

## Phase 8 — aegis-core app pipeline + frontend (merge #148)

1. **[YOU]** Set aegis-core repo secrets/vars: `AEGIS_CORE_DEPLOY_PAT` (contents+PR write on aegis-core-deploy), `AWS_ACCOUNT_ID`, `AWS_REGION`, `ECR_PUSH_ROLE_NAME`, `ECR_REPO_NAME`, `FRONTEND_*`, `GATEWAY_DOMAIN`, `BUILDBUDDY_API_KEY`.
2. **[YOU]** Merge aegis-core **#148** (held until now to avoid a pre-bootstrap red ECR-push run). On merge, `release-staging-image.yml` builds + pushes engine+gateway to ECR and opens the digest-pin PR on aegis-core-deploy; `release-staging-frontend.yml` builds the SPA, writes the cloud `config.json`, and syncs to the frontend S3 + CloudFront.
3. **[AUTO]** ArgoCD rolls the pinned digests.

---

## Phase 9 — TWO REGIONS (optional, when you want DR)

Wiring is ready (per-region cert + latency DNS + per-region ecr_region). To turn on eu-west-1:
1. **[YOU]** `regions.auto.tfvars.json`: set `eu-west-1.enabled = true`.
2. **[YOU]** `accounts.json`: add `"eu-west-1"` to the target account's `enabled_regions`.
3. **[AUTO]** Next apply runs `apply-regional` for both regions (matrix). Each region gets its own EKS + ACM cert; external-dns writes coexisting latency records for `aegis-api.<zone>`; ECR replication (already configured) serves the second region.
4. **[YOU]** Confirm Route53 shows two latency records and `dig` returns the nearest region.

---

## Teardown (post-verify, to stop billing) — joint-strike §G gotchas
- `make destroy-region REGION=…` then `make destroy-platform` (or `infra-ops` destroy with approval).
- Known: `VPC DependencyViolation` from orphaned ALB SGs (two-phase sweep handles it); ECR `RepositoryNotEmptyException` (force_delete needs a prior apply cycle); after `destroy-platform`, flip `bootstrap_complete`/`BOOTSTRAP_COMPLETE` back to false or the next plan assumes a deleted role and reds.

---

## What is already DONE (merged, no apply)
WS3 terraform + manifests are on `main`: PRs #86, #13 (WS3), #87, #14 (WS3-R two-region/HTTPS/naming). Only aegis-core **#148** is intentionally still open (Phase 8). Nothing is applied — this runbook is the first apply.
