# aegis-stateless

Infrastructure for a stateless HTTP greeter on AWS EKS — Terraform for the cloud
substrate, ArgoCD for in-cluster GitOps, Grafana Cloud for observability, and a
DR drill that rebuilds the workload from git.

This repository is the **infrastructure half** of a two-repo split. The
application (a Go `net/http` greeter, its Dockerfile, and the image-publish CI)
lives in the sibling repo `aegis-greeter`. This repo owns the AWS infrastructure,
the Kubernetes manifests, the ArgoCD installation, and the CI/CD that ties them
together.

## Who is this for

| You want to… | Start here |
|---|---|
| Review the submission | [`docs/SUBMISSION.md`](docs/SUBMISSION.md) — what this is, status, service-level targets |
| Understand the architecture | [Architecture](#architecture) below, then [`docs/adr/`](docs/adr/README.md) |
| Read the reasoning behind a decision | [`docs/adr/README.md`](docs/adr/README.md) — ADR index with a reading order per audience |
| Stand it up from scratch | [First-time setup](#first-time-setup) below |
| Operate it day-to-day | [Day-to-day operations](#day-to-day-operations) below |
| See what's monitored and alerted on | [`docs/metrics-and-alerts.md`](docs/metrics-and-alerts.md) — panel + alert catalog |
| Run / understand the DR drill | [`docs/dr-plan.md`](docs/dr-plan.md) + [DR drill](#dr-drill) below |
| Know what it costs to run | [`docs/finops.md`](docs/finops.md) — cost model + the ephemeral-teardown strategy |
| See what was deliberately deferred | [`docs/tradeoffs.md`](docs/tradeoffs.md) |

## Architecture

```mermaid
flowchart TB
    subgraph app_repo["aegis-greeter — application repo"]
        app["greeter.go · Dockerfile · publish.yml"]
    end
    subgraph this_repo["aegis-stateless — this repo"]
        tf["terraform/ · bootstrap / platform / regional"]
        kust["k8s/overlays/prod/kustomization.yaml"]
        argocd["ArgoCD · per cluster"]
    end
    subgraph aws["AWS · per region"]
        eks["EKS — greeter Deployment + Grafana Alloy DaemonSet"]
        ecr[("ECR")]
        cw["CloudWatch · audit side-effect"]
    end
    gc["Grafana Cloud · Mimir / Loki / Tempo / Pyroscope"]

    app -->|build + push image| ecr
    app -->|commit image-tag bump| kust
    tf -->|provisions| eks
    kust --> argocd
    argocd -->|syncs| eks
    ecr -.image.-> eks
    eks -->|OTLP · logs · profiles · scrape| gc
    eks -.control plane + ALB logs.-> cw
```

- **Terraform**, three lifecycle-separated environments: `bootstrap` (state
  backend), `platform` (slow lifecycle — Route 53, ECR, OIDC, budgets, Grafana
  dashboards), `regional` (fast lifecycle — VPC + EKS + ArgoCD + Alloy, applied
  once per region).
- **Multi-region topology as data** — the region set is data (`regions.auto.tfvars.json`),
  not code. Adding a region is a one-line data change; an external loop
  (Makefile / GitHub Actions matrix) applies `regional` once per region with
  per-region state isolation.
- **ArgoCD per cluster** — each EKS cluster runs its own ArgoCD, eliminating a
  GitOps-layer single point of failure.
- **Observability** — the app emits OpenTelemetry + Pyroscope to a node-local
  Grafana Alloy DaemonSet, which forwards to Grafana Cloud. CloudWatch is kept
  only for EKS control-plane logs + ALB access logs (audit side-effect).

See [`docs/adr/`](docs/adr/README.md) for the reasoning behind each decision and
[`docs/tradeoffs.md`](docs/tradeoffs.md) for what was deliberately deferred.

## Repository layout

```
regions.auto.tfvars.json   Single source of truth — platform_region + regions{}
terraform/
  envs/bootstrap/          S3 state bucket (local state, one-shot)
  envs/platform/           Route 53, ECR, OIDC, budget, SSM, Grafana, branch protection
  envs/regional/           VPC + EKS + ArgoCD + Alloy — applied once per region
  modules/regional-stack/  The per-region stack, invoked by envs/regional/
k8s/
  base/                    Kustomize base — namespace, deployment, service, ingress, hpa
  overlays/prod/           Image tag bumped by the aegis-greeter CI
grafana/dashboards/        Dashboard JSON, applied by the grafana/grafana TF provider
.github/workflows/         infra-plan, infra-apply, infra-ops
docs/adr/                  Architecture Decision Records
docs/tradeoffs.md          Deferred work + production-hardening path
Makefile                   Local dev + emergency apply (CI is the canonical path)
scripts/install-tools.sh   Pinned project-local toolchain → ./bin/
```

## Prerequisites

- An AWS account with permission to create VPC / EKS / IAM / ECR / Route 53 / S3.
- A Grafana Cloud stack (free tier is sufficient).
- `terraform` ≥ 1.11 (`.terraform-version` pins 1.14.8 for `tfenv`/`tenv`).
- `make`, `git`, `bash`, `aws` CLI, `kubectl`, `gh` (GitHub CLI — used to set
  the Actions secrets/variables during setup). All other tools (tflint, tfsec,
  kubeconform, jq, kustomize, gitleaks) install into `./bin/` via `make dev-setup`.

## First-time setup

The CI pipeline cannot create the very infrastructure it authenticates against,
so the foundation is bootstrapped once from an operator's machine; CI takes over
after that.

```bash
# 1. Project-local toolchain → ./bin/  (tflint, tfsec, kubeconform, hadolint,
#    jq, kustomize, gitleaks) + wire the pre-commit hook.
make dev-setup

# 2. Fill in secrets (templates ship as *.example):
cp terraform/envs/platform/secrets.auto.tfvars.example terraform/envs/platform/secrets.auto.tfvars
cp terraform/envs/regional/secrets.auto.tfvars.example terraform/envs/regional/secrets.auto.tfvars
# …edit both with real Grafana Cloud + GitHub PAT values (gitignored).

# 3. Pick the regions — regions.auto.tfvars.json is the single source of
#    truth, with two keys:
#      platform_region — where the Terraform state bucket and the slow-
#        lifecycle platform layer live (ECR, OIDC, Route 53, budget, SSM).
#        Set once; it is also the state-bucket region.
#      regions{}       — which region(s) the workload (VPC + EKS + ArgoCD)
#        deploys to. eu-central-1 and eu-west-1 both ship `enabled: true`;
#        flip a region's `enabled` flag to add or drop one.

# 4. Create the remote state backend (local state, one-shot).
export AWS_PROFILE=<your-profile>
make bootstrap

# 5. Apply the slow-lifecycle platform env.
make platform

# 6. Apply the workload, looping over every enabled region.
make regional
```

After `make platform`, capture its outputs and finish the CI wiring:

```bash
# GitHub Actions secrets — the authoritative list and the full `gh secret set`
# commands live in terraform/envs/platform/README.md (each value is piped from
# `terraform output`, so nothing is typed by hand).

# GitHub Actions repo variables for the sibling app repo, from platform outputs:
gh variable set ECR_REPO_URL  -b "$(terraform -chdir=terraform/envs/platform output -raw ecr_repository_url)"  --repo BinHsu/aegis-greeter
gh variable set ECR_REGISTRY  -b "$(terraform -chdir=terraform/envs/platform output -raw ecr_registry)"        --repo BinHsu/aegis-greeter
gh variable set OIDC_ROLE_ARN -b "$(terraform -chdir=terraform/envs/platform output -raw greeter_ci_role_arn)" --repo BinHsu/aegis-greeter
gh variable set AWS_REGION    -b "$(terraform -chdir=terraform/envs/platform output -raw aws_region)"          --repo BinHsu/aegis-greeter

# Flip the CI bootstrap gate — infra-plan/infra-apply plan/apply jobs un-skip.
gh variable set BOOTSTRAP_COMPLETE -b "true" --repo BinHsu/aegis-stateless
```

### Publish the first application image — cross-repo step

`make regional` brings up the cluster and ArgoCD, but the greeter Deployment
references an image that does not exist yet — its pods sit in
`ImagePullBackOff` until the **sibling `aegis-greeter` repo** publishes one.
That repo's `publish.yml` builds the image, pushes it to the ECR repository
provisioned here, and commits the image-tag bump back to
`k8s/overlays/prod/kustomization.yaml`. Trigger it by pushing to `aegis-greeter`'s
`main` (it needs the four repo variables set above). ArgoCD then reconciles the
new tag and the greeter pods reach `Running`.

### Verify

```bash
aws eks update-kubeconfig --name aegis-stateless-eu-central-1 --region eu-central-1
kubectl get pods -n greeter       # greeter pods 1/1 Running (not ImagePullBackOff)
kubectl get pods -n argocd        # ArgoCD healthy
kubectl get pods -n monitoring    # Alloy + node-exporter + kube-state-metrics
kubectl -n greeter port-forward svc/aegis-greeter 8080:80 &
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/healthz   # 200
```

From here, every push to `main` runs `infra-plan` (PR) / `infra-apply`
(merge); see [CI/CD](#cicd) below.

## Day-to-day operations

```bash
make help          # list every target
make fmt           # terraform fmt -recursive
make validate      # terraform validate, all envs
make lint          # tflint
make sec           # tfsec
make platform      # apply the platform env
make regional      # apply every enabled region
make regional-one REGION=eu-central-1   # apply a single region
```

The pre-commit hook (`.githooks/pre-commit`, wired by `make dev-setup`) runs
`terraform fmt -check` + a `gitleaks` secret scan on every commit.

## Cost

| Scope | Rate | Note |
|---|---|---|
| Per region | ~$0.20/hr | EKS control plane + Spot nodes + ALB + NAT gateway |
| Platform env | ~$0/mo | Route 53 zone + ECR storage — safe to leave running |
| Per DR drill | ~$1–2 | ~6 h: stand up → drill → tear down |

Regional infrastructure is **ephemeral** — stood up for a demo or DR drill, torn
down when idle (`make destroy-region`). The `bootstrap`/`platform`/`regional`
lifecycle split keeps this safe: a teardown never touches ECR images, the
Route 53 zone, or Grafana dashboards. An AWS Budget ($10 warn / $25 hard)
backstops a forgotten teardown. Cost scales linearly per region.

Full breakdown — itemised rates, the interval math, and the levers pulled — in
[`docs/finops.md`](docs/finops.md).

## DR drill

The drill proves the workload is reconstructible from git — Terraform state is
the source of truth, ArgoCD converges the cluster from zero. The failure-mode
matrix, RTO/RPO targets, and the full procedure are in
[`docs/dr-plan.md`](docs/dr-plan.md).

Run it with the helper script — it sequences the phases, times each, captures
CLI evidence, and writes a timestamped report under `docs/evidence/`:

```bash
scripts/dr/dr-drill.sh eu-central-1
```

Or step through it manually:

```bash
# Tear down one region's workload. The platform env (Route 53, ECR, Grafana
# dashboards) is untouched; other regions, if any, stay alive.
make destroy-region REGION=eu-central-1

# Rebuild it. EKS cold-provisioning dominates — the drill measured 11m 21s.
make regional-one REGION=eu-central-1

# Verify the workload reconverged from git.
kubectl get pods -n greeter
```

Or run it through GitHub Actions: the `infra-ops` workflow (`workflow_dispatch`)
exposes `destroy-region` as an operator-triggered, audit-logged operation.

Measured cold-rebuild RTO (2026-05-17 drill): **11m 21s** — Terraform re-apply
11m 3s + ArgoCD reconverge 18 s, region-down to greeter pods Ready. ~20-30 min
is the conservative budget; EKS control-plane provisioning is the variable
bottleneck. See [ADR-05](docs/adr/05-disaster-recovery.md).

## Observability

The app emits metrics, traces, logs, and continuous profiles via OpenTelemetry +
Pyroscope to a node-local Grafana Alloy DaemonSet, which forwards to Grafana
Cloud. Dashboards and alert rules are declared in Terraform
(`terraform/envs/platform/grafana.tf` + `grafana/dashboards/`) — no manual UI
edits, so the DR drill reconstructs them from git. The full panel and alert
inventory is in [`docs/metrics-and-alerts.md`](docs/metrics-and-alerts.md).

Sample queries (full set in `docs/runbooks/`):

```promql
# request latency p95
histogram_quantile(0.95,
  sum by (le, route) (rate(http_server_request_duration_seconds_bucket{service_name="aegis-greeter"}[5m])))
```
```logql
# 5xx log lines in the last hour, by pod
sum by (pod) (count_over_time(
  {app="aegis-greeter"} | json | level="ERROR" | status >= 500 [1h]))
```

## CI/CD

| Workflow | Trigger | Does |
|---|---|---|
| `infra-plan` | PR / push to `main` | fmt, validate, tflint, tfsec, kubeconform, gitleaks, `terraform plan` per env; posts the plan diff as a PR comment |
| `infra-apply` | push to `main` | `terraform apply` per env (platform + regional matrix) |
| `infra-ops` | `workflow_dispatch` | `bootstrap` / `destroy-region` / `destroy-platform` (the DR drill) |

`main` branch protection (required status checks + linear history + no
force-push) is provisioned by `github_branch_protection`, gated on
`var.enable_branch_protection` — GitHub requires Pro for branch protection on a
private repo, so it is off by default until the repo is public or on Pro (see
`docs/tradeoffs.md`). Two OIDC roles split trust — a read-only role for PR
plans, an apply role whose trust is pinned to `refs/heads/main`. Until the
`BOOTSTRAP_COMPLETE` repo variable is set, the plan/apply jobs skip cleanly (the
AWS foundation does not exist yet) and the pipeline stays green.

## License

MIT — see [`LICENSE`](LICENSE).
