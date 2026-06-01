# PROD Joint-Strike Runbook — aegis Pattern-B Vertical (account 506221082337)

> **Audience: the 3am operator.** Result-first. This is a *design artifact* — a planned apply→prove→destroy of one greeter pod into prod. Nothing here has run against 506221082337. Every layer flags its prod-specific gap. Read §5 (prerequisites) before you touch anything.

---

## 1. Goal + success criterion

**Goal:** stand up **one greeter pod** in the prod EKS cluster, discovered by GitHub topic and reconciled by the platform's ArgoCD, **reachable over HTTP** through the platform-provisioned ALB — then tear the billable layer back down in the same session.

**Success signal (single line):**
```
curl -s -o /dev/null -w '%{http_code}' http://<alb-hostname>/healthz   →  200
```
where `<alb-hostname>` = `kubectl -n aegis-greeter get ingress aegis-greeter -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'`. The greeting body reflects the injected region tag. A real DNS name is **not** part of the criterion for prod (see §7 — the Ingress host is a `.test` placeholder; expect the raw `*.elb.amazonaws.com` endpoint, HTTP-only).

**Cost-window posture: apply → prove → destroy, one session.** The only real cost is the regional EKS stack. Stand it up, run the 9-step prove chain, destroy-regional same session. A 3-hour window ≈ **$1–2**. The foundation (IAM/OIDC, state buckets, ECR) is ~$0/hr and **stays** — it is non-ephemeral by design (§5, §6).

---

## 2. Ordered dependency DAG

The strike is a strict gated chain. Each arrow carries the **handoff artifact** that must exist before the next stage can start. No stage is parallelizable with its predecessor.

```
[Stage 0]  LZ prod-foundation (aegis-landing-zone-aws / prod/bootstrap)
   │   PRODUCES: GitHub OIDC provider in 506221082337
   │             + gh-tf-apply-baseline, gh-tf-plan, aegis-emergency-break-glass
   │             + gh-tf-apply-platform (the platform deploy role)
   ▼
[Stage 1]  platform-aws BOOTSTRAP (envs/bootstrap)
   │   PRODUCES: S3 state bucket tfstate-506221082337 + backend.hcl
   │             (consumed as TFSTATE_BUCKET / TFSTATE_REGION)
   ▼
[Stage 2]  platform-aws PLATFORM (envs/platform)
   │   PRODUCES: ECR repo aegis-greeter, aegis-greeter-ci role,
   │             Route53 zone, SSM Grafana params, BOOTSTRAP_COMPLETE=true
   │   (ECR url + greeter_ci_role_arn → greeter repo vars)
   ▼
[Stage 3]  platform-aws REGIONAL (regional-stack module, per region)  ◄── THE COST
   │   PRODUCES: EKS cluster + ArgoCD + the `aegis-workloads` ApplicationSet
   │             (the topic-discovery engine — the deploy handoff)
   ▼
[Stage 4]  greeter (aegis-greeter / publish.yml)
   │   PRODUCES: image aegis-greeter:<sha7> in prod ECR
   │             + a tag-bump commit on aegis-greeter-deploy:k8s/overlays/prod
   ▼
[Stage 5]  greeter-deploy (aegis-greeter-deploy — GitOps, no CI)
       discover (topic `aegis-workload` + argocd/application.yaml marker)
         → ArgoCD renders Application → sync → POD Running → ALB → HTTP 200
```

**Gating rule:** Stage N's "PRODUCES" line is Stage N+1's hard precondition. The CI workflows are built to stay **green-but-skipped** until the handoff artifact is wired — a missing handoff is a silent skip, not a failure (this is the safety property, and the trap).

---

## 3. Per-stage runbook

Executor legend: **[CI]** = `gh workflow run` / push-triggered Actions · **[local]** = operator laptop (make / terraform / kubectl) · **[BG]** = break-glass / manual out-of-band.

### Stage 0 — LZ prod-foundation (aegis-landing-zone-aws)

| Precondition | Command / CI workflow (exact) | Verify (exact) | On-failure | Teardown |
|---|---|---|---|---|
| Staging bootstrap `.tf` exists to port; prod is a stub (alias + caller only) | **[local]** Port `oidc-github.tf`, `oidc-github-plan-role.tf`, `oidc-github-baseline-role.tf`, `aegis-emergency-role.tf` into `terraform/environments/prod/bootstrap/`; add a `gh-tf-apply-platform` role `.tf`; extend `outputs.tf` | `terraform -chdir=terraform/environments/prod/bootstrap validate && fmt -check` | Fix HCL; `check "config_account_id_not_empty"` asserts non-empty acct | NON-EPHEMERAL — do not routinely destroy |
| HCL valid; matrices exclude prod | **[local→CI]** Add `{ env: prod/bootstrap, account_id: "506221082337" }` to `terraform-apply-baseline.yml` matrix `include` AND `terraform-plan.yml` matrix | **[CI]** Open PR; `Plan prod/bootstrap` row runs green via `gh-tf-plan`… (will fail until Stage-0 seed exists) | Matrix YAML typo, or role absent → expected pre-seed | n/a |
| **First IAM seed — bootstrap cycle, CI cannot create the role CI assumes** | **[BG]** `export AWS_PROFILE=aegis-prod-admin; aws sso login --sso-session aegis; terraform -chdir=…/prod/bootstrap init -input=false && plan && apply -input=false` | **[local]** `aws iam list-open-id-connect-providers` shows `token.actions.githubusercontent.com`; `aws iam list-roles --query "Roles[?starts_with(RoleName,'gh-tf')]"` shows `gh-tf-plan`, `gh-tf-apply-baseline`, `gh-tf-apply-platform` | If half-applied, re-`apply` (idempotent) — never leave a half-created OIDC provider; if SCP denies CreateRole, confirm role name matches `gh-tf-*` allow-glob; log incident | `terraform … prod/bootstrap destroy` (BG) — only if removing the whole vertical, AFTER all consumers |
| Role now exists | **[CI]** `gh workflow run "Terraform Apply (Baseline)"` (workflow_dispatch) — confirm self-managing | **[CI]** `gh run list --workflow=terraform-apply-baseline.yml` → prod row green; no further BG needed | Re-run failed; IAM propagation race is known | n/a |

> **Why BG here:** `iam:CreateOpenIDConnectProvider` + `iam:CreateRole` on `gh-tf-*` are SCP-gated; the CI role cannot create the CI role. This is the one sanctioned break-glass in the whole strike. PlatformAdmin SSO creating the `gh-tf-*` / `aegis-emergency-*` prefixed roles is the allow-listed path.

### Stage 1 — platform bootstrap (S3 state bucket)

| Precondition | Command / CI (exact) | Verify (exact) | On-failure | Teardown |
|---|---|---|---|---|
| Stage 0 done; `regions.auto.tfvars.json` present | **[local] preferred:** `make bootstrap` then `make regenerate-backend`. (CI `infra-ops.yml` op=bootstrap exists but needs the apply role + uses ephemeral-runner LOCAL state → prefer local for durability) | `terraform -chdir=terraform/envs/bootstrap output -raw bucket_name` = `tfstate-506221082337`; `aws s3api head-bucket --bucket tfstate-506221082337` | Bucket-name collision / KMS denied → re-check acct+region; `prevent_destroy` means a half-apply leaves only the bucket (re-apply idempotent) | **NON-EPHEMERAL** — `prevent_destroy=true`; must hand-edit the block for a true full destroy |

### Stage 2 — platform apply (ECR, OIDC roles, Route53, SSM)

| Precondition | Command / CI (exact) | Verify (exact) | On-failure | Teardown |
|---|---|---|---|---|
| Stage 1 outputs captured; **PR #15 merged** so prod OIDC is a data-source (not TF-managed); `gh-tf-apply-platform` seeded; **~11 secrets/vars set incl. `BOOTSTRAP_COMPLETE=true`** (§5) | **[CI] canonical:** push to `main` touching `terraform/**` → `infra-apply.yml` job `apply-platform` (assumes `AWS_INFRA_APPLY_ROLE_ARN`, `init -reconfigure -backend-config=…` then `apply -auto-approve -var-file=regions.auto.tfvars.json`). **[local] override:** `make platform` | **[CI]** `apply-platform` green; **[local]** `aws iam get-role --role-name aegis-greeter-ci`; `terraform -chdir=terraform/envs/platform output -raw ecr_repository_url` | Grafana provider auth (missing `GRAFANA_*`) or OIDC data-source not found (Stage 0 missing) → fix handoff input, re-push. Until `BOOTSTRAP_COMPLETE=true`, job **skips silently** (green no-op) | **[CI]** `infra-ops.yml` op=destroy-platform / **[local]** `make destroy-platform` — post-cycle only; ECR + Route53 zone are otherwise kept |

### Stage 3 — regional EKS apply (THE COST)

| Precondition | Command / CI (exact) | Verify (exact) | On-failure | Teardown |
|---|---|---|---|---|
| Stage 2 done; `OPERATOR_PRINCIPAL_ARN` = prod operator (EKS ClusterAdmin entry); `GH_DEPLOY_KEY_PAT` set (ArgoCD SCM token); region pin (`platform_region=eu-central-1`) confirmed | **[CI] canonical:** same push → `infra-apply.yml` matrix job `apply-regional` (per enabled region, `fail-fast:false`, `needs:[setup, apply-platform]`). **[local] override:** `make regional` / `make regional-one REGION=eu-central-1` | **[CI]** matrix jobs green; **[local]** `aws eks update-kubeconfig --name <cluster> --region eu-central-1`; `kubectl get nodes` (2 SPOT Ready); `kubectl -n argocd get applicationset aegis-workloads` | **Partial EKS = billable orphans + state-lock risk.** Dispatch `infra-ops.yml` op=destroy-region BEFORE retry. IRSA create denied → confirm Stage-0 role name is `gh-tf-*`. Per-region failure does not abort siblings | **[CI]** `infra-ops.yml` op=destroy-region region=<r> / **[local]** `make destroy-region REGION=<r>` — both run `scripts/dr/pre-destroy.sh` first to delete the greeter Ingress so the ALB controller removes its (non-TF-state) ALB; else ENIs orphan → `DependencyViolation` stalls VPC destroy |

> **This is the 1-minute-poll cost step (§6).** A blind coarse `gh run watch` is too slack for a billable apply that can leave partial EKS/NAT.

### Stage 4 — greeter image build + push

| Precondition | Command / CI (exact) | Verify (exact) | On-failure | Teardown |
|---|---|---|---|---|
| Stage 2 done; greeter repo vars re-pointed at **506221082337** (`ECR_REPO_URL`, `ECR_REGISTRY`, `AWS_REGION`, `OIDC_ROLE_ARN`) + secret `INFRA_REPO_PAT`; deploy repo has `images[].newName=aegis-greeter` placeholder | **[local one-time]** `gh variable set …` from platform outputs. **[CI]** push to `main` on `aegis-greeter` → `publish.yml`: `make vet test`, OIDC assume `aegis-greeter-ci`, buildx `linux/amd64` tag `${GITHUB_SHA::7}`, Trivy HIGH/CRITICAL gate, `docker push`, `yq -i` bump deploy-repo, push | **[local]** `aws ecr describe-images --repository-name aegis-greeter --image-ids imageTag=<sha7>`; `gh api repos/BinHsu/aegis-greeter-deploy/commits --jq '.[0].commit.message'` shows "Bump aegis-greeter image to <sha7>" | Trivy finding → red, no push (rebuild on patched base); re-push of existing SHA → `ImmutableTagViolation` (ECR is IMMUTABLE); wrong-account var → ECR push 403 / `sts:AssumeRoleWithWebIdentity` denied | No TF, no billable resource. Revert deploy-repo kustomization; optionally `gh variable delete` to re-inert |

> **No `workflow_dispatch`** on `publish.yml` today — to re-publish a SHA you push an empty commit (§7 gap).

### Stage 5 — greeter-deploy GitOps → running pod (THE PROVE)

| Precondition | Command / mechanism (exact) | Verify (exact) | On-failure | Teardown |
|---|---|---|---|---|
| Stage 3 cluster up (ArgoCD + `aegis-workloads` ApplicationSet + AppProject + ALB controller + external-dns + Kyverno default-deny); Stage 4 image + tag-bump landed | **[local one-time]** `gh repo edit BinHsu/aegis-greeter-deploy --add-topic aegis-workload` (already present today). **Discovery is passive** — ApplicationSet polls SCM. Force: **[local]** `kubectl -n argocd annotate applicationset aegis-workloads argocd.argoproj.io/refresh=hard --overwrite` | **[local] read-only chain:** `kubectl get application aegis-greeter -n argocd` exists → `… -o jsonpath='{.status.sync.status} {.status.health.status}'` = `Synced Healthy` → `kubectl -n aegis-greeter get pods` 2× Running 1/1 → `kubectl -n aegis-greeter get ingress aegis-greeter -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'` returns `*.elb.amazonaws.com` → **`curl … http://<alb>/healthz` = 200** | No Application → check SCM token + topic + marker (`logs deploy/aegis-apps-applicationset-controller`); `ImagePullBackOff` → tag not in ECR / wrong-account rewrite; empty Ingress `.status` → ALB-controller IRSA/subnet-tag; non-200 → allow-NetworkPolicy :8080 + readiness | Remove topic → ApplicationSet prunes Application (`prune:true`) → ArgoCD deletes ns/ALB/Route53 record. Or destroy-region takes it all; **git manifests survive** |

---

## 4. The orchestration answer — "script or GitHub Actions?"

**Direct answer: both, and the split is structural, not stylistic. CI runs the engines; humans connect the pipes; a thin driver script sequences them and STOPs at every seam.**

**The operator's hypothesis is validated for the apply mechanics.** The three actual provisioning/build engines are all `gh workflow run` + poll:

- **Stage 0 self-maintenance** — `terraform-apply-baseline.yml` (push / dispatch)
- **Stages 2+3** — `infra-apply.yml` (`apply-platform` → matrix `apply-regional`)
- **Stage 4** — `publish.yml` (build + push + tag-bump)

These are stateless-or-OIDC, idempotent, and belong in CI.

**The hypothesis is wrong for the seams.** The irreducible manual/break-glass set:

1. **[BG] Stage-0 IAM seed** — SCP-gated `iam:CreateOIDCProvider`/`CreateRole`; needs an interactive assumed-role session. The CI role cannot create the CI role.
2. **[manual] cross-repo secret/var wiring** — `gh secret set` / `gh variable set` move credentials across trust boundaries (`TFSTATE_*`, `AWS_INFRA_APPLY_ROLE_ARN`, `OPERATOR_PRINCIPAL_ARN`, Grafana set, `BOOTSTRAP_COMPLETE=true`; then `ECR_*`/`OIDC_ROLE_ARN`/`AWS_REGION` + `INFRA_REPO_PAT`). No workflow can read another layer's `terraform output` and write its own repo secrets — a human eyeballs each.
3. **[manual] GitHub topic** — `gh repo edit --add-topic aegis-workload` is repo metadata, the opt-in discovery gate; not in any workflow's scope.
4. **[local] EKS-API verifies** — `kubectl` / `argocd` / `curl` need network into the cluster; a GitHub-hosted runner has none. Acceptance is structurally operator-local.

So: **CI runs the engines; humans connect the pipes.** The driver script is a sequencer over that boundary — it dispatches CI, polls green, runs read-only verifies, and STOPs at every human seam.

### DRIVER-SCRIPT skeleton (`scripts/prod-e2e.sh`)

```bash
#!/usr/bin/env bash
set -euo pipefail
PROD=506221082337
LZ=BinHsu/aegis-landing-zone-aws
PLAT=BinHsu/aegis-platform-aws
GREET=BinHsu/aegis-greeter
DEPLOY=BinHsu/aegis-greeter-deploy
REGION=eu-central-1

stop() { echo; echo ">>> STOP (manual): $1"; read -rp "Press enter once done... "; }
wait_green() {  # $1=repo $2=workflow — dispatch + block until done, nonzero on fail
  gh workflow run "$2" --repo "$1"; sleep 5
  id=$(gh run list --repo "$1" --workflow "$2" -L1 --json databaseId -q '.[0].databaseId')
  gh run watch "$id" --repo "$1" --exit-status
}

# 0. BREAK-GLASS — NEVER automate (SCP-gated IAM seed of prod gh-tf-* roles + OIDC provider)
stop "assume aegis-emergency-break-glass; terraform apply prod/bootstrap (OIDC provider + gh-tf-apply-baseline + gh-tf-apply-platform); add prod row to terraform-apply-baseline.yml matrix"

# 1. LZ baseline self-maintenance (CI)
wait_green "$LZ" terraform-apply-baseline.yml
aws iam list-open-id-connect-providers --profile aegis-prod-admin   # read-only verify

# 2. Platform bootstrap — recommend LOCAL (ephemeral-runner loses LOCAL state on failure)
stop "run 'make bootstrap' + 'make regenerate-backend' locally in aegis-platform-aws; capture bucket_name + region"

# 3. SEAM — NEVER automate (output->secret wiring + the BOOTSTRAP_COMPLETE gate)
stop "gh secret set TFSTATE_BUCKET/TFSTATE_REGION/AWS_INFRA_APPLY_ROLE_ARN/OPERATOR_PRINCIPAL_ARN/GH_DEPLOY_KEY_PAT + GRAFANA_* ; gh variable set BOOTSTRAP_COMPLETE=true (aegis-platform-aws)"

# 4. Platform + regional EKS apply (CI) — COST STEP: operator drives the 1-min poll, NOT this watcher
echo ">>> push to aegis-platform-aws main (terraform/**), then 'gh run watch <id>' AND re-check 'kubectl get nodes' every ~60s"
stop "EKS apply is BILLABLE — 1-min cost poll; on failure dispatch infra-ops.yml destroy-region BEFORE retry"

# 5. SEAM — NEVER automate (re-point greeter vars at PROD 506221082337)
stop "terraform output (platform) -> gh variable set ECR_REPO_URL/ECR_REGISTRY/OIDC_ROLE_ARN/AWS_REGION; gh secret set INFRA_REPO_PAT (aegis-greeter)"

# 6. Build + push image + bump deploy repo (CI)
wait_green "$GREET" publish.yml
aws ecr describe-images --repository-name aegis-greeter --region "$REGION"   # read-only verify

# 7. SEAM — NEVER automate (topic = opt-in discovery gate)
stop "gh repo edit $DEPLOY --add-topic aegis-workload  (already present today — confirm)"

# 8. ArgoCD reconcile — PROVE, local EKS API only
argocd app get aegis-greeter
kubectl -n aegis-greeter get pods
ALB=$(kubectl -n aegis-greeter get ingress aegis-greeter -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s -o /dev/null -w '%{http_code}\n' "http://$ALB/healthz"   # expect 200

# 9. DESTROY (regional only — foundation stays)
stop "confirm destroy-regional (keeps LZ foundation + state bucket + ECR)"
gh workflow run infra-ops.yml --repo "$PLAT" -f operation=destroy-region -f region="$REGION"
```

**What the script must NOT automate:** (a) the **break-glass IAM seed** (step 0) — interactive assumed-role, SCP-gated; (b) any **`gh secret set` / `gh variable set` / `--add-topic`** (steps 3, 5, 7) — these cross trust boundaries and a human must verify them; (c) the **1-minute cost poll** on the EKS apply (step 4) — a blind `gh run watch` is too coarse for a billable apply that can leave partial EKS/NAT; the operator watches at ~60s and destroys-then-retries on failure.

---

## 5. PROD-specific prerequisites / gaps (the foundation work prod needs first)

Prod is a **greenfield foundation** relative to staging. The deltas, in dependency order:

| # | Gap (verified live) | Fix | Stage |
|---|---|---|---|
| 1 | **No LZ GitHub OIDC provider in 506221082337** — `list-open-id-connect-providers` = `[]`. `prod/bootstrap` is a stub (alias + caller only). **Until fixed, zero CI can authenticate to prod.** | Port staging's 4 `.tf` + BG seed | 0 |
| 2 | **No `gh-tf-*` / `aegis-emergency-*` roles** — `[]`. Includes `gh-tf-apply-platform`, which **exists in no account** (chicken-and-egg). | BG seed; name must match `gh-tf-*` SCP glob | 0 |
| 3 | **CI matrices silently exclude prod** — `terraform-apply-baseline.yml` has `prod/bootstrap/**` in `paths:` but no matrix row; `terraform-plan.yml` omits prod entirely. A push looks wired but applies nothing. | Add `{ env: prod/bootstrap, account_id: "506221082337" }` to both | 0 |
| 4 | **PR #15 open, not merged** — on `main`, prod platform OIDC is still TF-managed (resource, not data-source). Deploying as-is would try to *create* the provider, and a destroy could delete it out from under other repos. | Merge #15 before the prod cycle | pre-2 |
| 5 | **Platform never bootstrapped in prod** — no `tfstate-506221082337` bucket. | `make bootstrap` (local) | 1 |
| 6 | **Repo has zero secrets/vars** — `gh secret list`/`gh variable list` = `[]`. **~11 must be set**: `TFSTATE_BUCKET`, `TFSTATE_REGION`, `AWS_INFRA_APPLY_ROLE_ARN`, `AWS_INFRA_CI_ROLE_ARN`, `OPERATOR_PRINCIPAL_ARN`, `GH_DEPLOY_KEY_PAT`, `BUDGET_ALERT_EMAIL`, the `GRAFANA_*` family, plus var `BOOTSTRAP_COMPLETE=true`. Until set, all apply/plan jobs **skip by design** (green-but-no-op). | `gh secret/variable set` | 2/3 |
| 7 | **`registries.auto.tfvars.json` points at non-prod ECR** (`ecr_account_id: 677078406165`). Greeter repo vars also live-wired to the dev account. Discovery would inject a cross-account image the prod cluster can't pull. | Re-point to 506221082337 | 2/4 |
| 8 | **ACK SCP carve-out forward-declared, prefix-mismatch risk** — SCP comment says `aegis-platform-aws-ack-iam-*`, live ArnNotLike entry is `aegis-platform-ack-iam-*`. Confirm the ACK controller role name platform-aws actually creates matches, or ACK `iam:CreateRole` is denied. **E2E pending in prod.** | Verify name vs glob pre-Stage-3 | 0/3 |
| 9 | **ArgoCD topic-discovery + AppProject isolation E2E-unverified** (issue #6). Prod 506221082337 would be the **first real run** of discovery, default-deny enforcement, and cross-namespace block. | Budget verify time | 3/5 |

**Non-ephemeral (stays after teardown):**
- LZ prod foundation — OIDC provider + `gh-tf-*` + `aegis-emergency-*` roles + account alias (~$0/hr; destroying breaks all CI).
- Platform bootstrap S3 state bucket `tfstate-506221082337` (`prevent_destroy=true`).
- Platform env — ECR repo + images, Route53 hosted zone, Grafana SSM wiring, ALB-logs bucket.
- Shared-account state bucket + KMS CMK (`prevent_destroy=true`) — belongs to the shared layer, not this vertical.
- Deploy repo + its `aegis-workload` topic; the git manifests (source of truth — a DR drill rebuilds the workload from git).

---

## 6. Cost

| Layer | Cost | Note |
|---|---|---|
| Stage 0 LZ foundation | **~$0/hr** | IAM/OIDC/alias only — nothing billable |
| Stage 1 bootstrap | **~$0/hr** | S3 state bucket, pennies/mo |
| Stage 2 platform | **~$0/hr idle** | ECR storage pennies; Route53 zone ~$0.50/mo ≈ $0.0007/hr |
| **Stage 3 regional EKS** | **~$0.19–0.21/hr per region** | **the dominant cost** |
| Stage 4 greeter image | **~$0/hr** | GH Actions minutes (public-repo free) + ECR storage pennies |
| Stage 5 greeter-deploy | **+~$0.02–0.05/hr** (the ALB) | no own resources; ALB is from the Ingress, runs on existing SPOT nodes |

**Stage-3 breakdown (per region):** EKS control plane $0.10/hr (flat) + 2× t3.medium SPOT ~$0.025–0.03 + 1× NAT GW ~$0.045 + 1× ALB ~$0.0225 → **~$0.19–0.21/hr**. Both `eu-central-1` + `eu-west-1` ≈ **$0.40/hr**. A 3-hour apply→prove→destroy window ≈ **$1–2** (single region) / **~$2** (two).

**Discipline:**
- **1-minute polling on the regional apply** (`infra-apply.yml apply-regional`). A failed apply leaves partial EKS/NAT (billable orphans) and can hold the state lock — a 4-min gap compounds both cost and blast radius. Catch fast → destroy-region → retry.
- **Destroy regional, keep foundation.** `infra-ops.yml op=destroy-region` tears EKS/VPC (per-region state key isolates blast radius); the pre-destroy hook removes the greeter Ingress/ALB first to avoid ENI orphans. Keep LZ foundation + bootstrap bucket + platform env. Full platform teardown (`op=destroy-platform`) is post-cycle only.

---

## 7. Open decisions

1. **Disposition of the 1st-gen `aegis-stateless` — RESOLVED (operator, 2026-06-01).** `aegis-stateless` is **kept as a standalone, independently-shippable deliverable** — same positioning as `aegis-enclave` (a self-contained reference, not a thing this campaign decommissions). It is NOT archived; gen-1 (self-contained) and gen-2 (this Pattern-B vertical) coexist as distinct portfolio pieces. *Separate, still-open detail:* the gen-2 deploy repo `aegis-greeter-deploy` carries a **leaked Ingress host** `greeter.aegis-stateless.test` (a `.test` placeholder inherited from the gen-1 monolith). It is outside external-dns `domainFilters`, so on prod external-dns silently ignores it and the only endpoint is the raw `*.elb.amazonaws.com` ALB hostname (HTTP-only). **Recommendation:** for the proof, accept the raw ALB hostname HTTP-200 as the success criterion (per §1); rewriting the host to a real prod-zone subdomain (+ ACM cert via the platform `ingress_cert` injection) for a real DNS name / HTTPS is a follow-up, not on the critical path to "one running pod reachable."

2. **Single-region vs 2-region for the proof.** Current tfvars enable both `eu-central-1` + `eu-west-1`. For a *proof* of one running pod, two regions doubles the dominant cost (~$0.40 vs ~$0.20/hr) and doubles the first-ever ArgoCD-discovery verify surface for no extra proof value. **Recommendation:** **single region (`eu-central-1`) for the strike** — trim `regions.auto.tfvars.json` to one enabled region; keep the 2-region path for a later DR-acceptance cycle.

3. **LZ prod-foundation as its own pre-campaign.** Stage 0 is break-glass IAM, SCP-sensitive, E2E-untested in prod, and a one-time non-ephemeral act with the ACK-prefix mismatch (gap #8) still unconfirmed. Bundling it into the same session as the billable EKS strike couples a slow, careful, human-gated bootstrap to a cost-windowed apply. **Recommendation:** **run Stage 0 (+ PR #15 merge + matrix rows + the secret/var wiring of §5) as a standalone pre-campaign**, verify the foundation self-manages via one no-op CI apply, *then* open the cost window for Stages 1–5 in a separate session. The foundation is $0/hr and stays — there is no cost reason to couple them, and good reason (blast radius, focus) to separate them.