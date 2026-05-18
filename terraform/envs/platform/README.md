# platform env

Slow-lifecycle infrastructure that **survives the DR drill**: Route 53 hosted zone, ECR repo (+ replication rule when ≥ 2 regions deployed), AWS Budget alarm, GitHub OIDC providers + trust roles, SSM Parameter Store entries for Grafana Cloud credentials, ALB access-logs S3 bucket, and Grafana Cloud dashboards / alerts / contact points (via the `grafana/grafana` TF provider).

## Apply

```bash
make platform
```

The Makefile target runs `terraform init -backend-config=$(ROOT)/backend.hcl` (file generated from `bootstrap`'s outputs) and applies with `-var-file=$(ROOT)/regions.auto.tfvars`.

## Local setup — sensitive vars (NEVER committed)

A blank template ships at `secrets.auto.tfvars.example`. **Copy it once** and fill:

```bash
cp terraform/envs/platform/secrets.auto.tfvars.example \
   terraform/envs/platform/secrets.auto.tfvars
# edit terraform/envs/platform/secrets.auto.tfvars
```

`secrets.auto.tfvars` is gitignored by the `*.tfvars` rule in `.gitignore` — `terraform` still auto-loads any `*.auto.tfvars` in the working dir, so no `-var` flags needed locally once filled.

Where to get each value:

| Var | Source |
|---|---|
| `grafana_cloud_api_token` | `glc_…` — Grafana Cloud → Connections → Cloud Access Policies → create token (metrics/logs/traces/profiles write). Alloy remote_write password. |
| `grafana_auth_token` | `glsa_…` — Grafana instance → Administration → Users and access → Service accounts → new SA (role: Admin) → Add service account token. Auth for the `grafana` TF provider. Distinct from the `glc_` token. |
| `grafana_cloud_{mimir,loki,tempo,pyroscope}_url` | Grafana Cloud → Connections → each backend's "Send …" page — the push/ingest URL |
| `grafana_cloud_{mimir,loki,tempo,pyroscope}_username` | Same pages — each backend has its own instance-ID username (they differ) |
| `budget_alert_email` | Operator-controlled email address (AWS Budget + Grafana alert routing both use it) |
| `github_token` | GitHub fine-grained PAT with `admin:public_key` on the aegis-stateless repo (regional-stack registers one deploy key per region via this) |

All marked `sensitive = true` in `variables.tf`; not echoed in `terraform plan` output.

## CI setup — GitHub Actions secrets (NEVER committed)

`infra-plan.yml` and `infra-apply.yml` read equivalent values from GH Actions secrets. Set once per repo:

```bash
gh secret set GRAFANA_CLOUD_API_TOKEN              -b "glc_..."            --repo BinHsu/aegis-stateless
gh secret set GRAFANA_AUTH_TOKEN                   -b "glsa_..."           --repo BinHsu/aegis-stateless
gh secret set GRAFANA_CLOUD_MIMIR_USERNAME     -b "<mimir-instance-id>"     --repo BinHsu/aegis-stateless
gh secret set GRAFANA_CLOUD_LOKI_USERNAME      -b "<loki-instance-id>"      --repo BinHsu/aegis-stateless
gh secret set GRAFANA_CLOUD_TEMPO_USERNAME     -b "<tempo-instance-id>"     --repo BinHsu/aegis-stateless
gh secret set GRAFANA_CLOUD_PYROSCOPE_USERNAME -b "<pyroscope-instance-id>" --repo BinHsu/aegis-stateless
gh secret set GRAFANA_CLOUD_MIMIR_URL              -b "https://prometheus-prod-XX-..."  --repo BinHsu/aegis-stateless
gh secret set GRAFANA_CLOUD_LOKI_URL               -b "https://logs-prod-XXX-..."       --repo BinHsu/aegis-stateless
gh secret set GRAFANA_CLOUD_TEMPO_URL              -b "https://tempo-prod-XX-..."       --repo BinHsu/aegis-stateless
gh secret set GRAFANA_CLOUD_PYROSCOPE_URL          -b "https://profiles-prod-XXX-..."   --repo BinHsu/aegis-stateless
gh secret set BUDGET_ALERT_EMAIL                   -b "ops@example.com"    --repo BinHsu/aegis-stateless
gh secret set GH_DEPLOY_KEY_PAT                    -b "github_pat_..."     --repo BinHsu/aegis-stateless

# Set after running `make bootstrap` once (capture from `terraform output`):
gh secret set TFSTATE_BUCKET                       -b "aegis-stateless-tfstate-<acct-id>" --repo BinHsu/aegis-stateless
gh secret set TFSTATE_REGION                       -b "eu-central-1"       --repo BinHsu/aegis-stateless

# Set after applying platform once (capture from `terraform output`):
gh secret set AWS_INFRA_CI_ROLE_ARN                -b "arn:aws:iam::<acct>:role/aegis-stateless-ci"    --repo BinHsu/aegis-stateless
gh secret set AWS_INFRA_APPLY_ROLE_ARN             -b "arn:aws:iam::<acct>:role/aegis-stateless-apply" --repo BinHsu/aegis-stateless
```

## CI bootstrap gate — `BOOTSTRAP_COMPLETE`

`infra-plan.yml` / `infra-apply.yml` skip their plan/apply jobs until a repo **variable** (not secret) flags that the AWS foundation exists. This resolves the bootstrap-ordering gap: before `platform/` is applied, the IAM roles + GitHub OIDC provider don't exist, so OIDC role assumption can't succeed — skipping keeps the pipeline green instead of failing on an unavoidable gap.

After the operator has run `make bootstrap` + `make platform` locally (so the roles + OIDC provider exist) and set all the secrets above:

```bash
gh variable set BOOTSTRAP_COMPLETE -b "true" --repo BinHsu/aegis-stateless
```

From then on, `infra-plan` plans and `infra-apply` applies on every push to `main`. Before it, only `gitleaks` + `fmt/validate/lint/sec` + k8s-manifest validation run (and pass) — the plan/apply jobs show as `skipped`.

Per CLAUDE.md anonymization policy: real values NEVER appear in committed files — including this README's command examples (use the placeholder strings above).

## Drift detection

After every apply, `terraform plan` should report **zero diff** — including Grafana resources. Any drift indicates a manual UI edit, which is forbidden per the locked observability discipline.

## Outputs consumed by regional/

`platform/` exports `zone_id`, `ecr_url`, `oidc_role_arns`, `grafana_cloud_ssm_paths`, `alb_access_logs_bucket`, `public_dashboard_urls`. `regional/` reads these via `data.terraform_remote_state.platform`.
