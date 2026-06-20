# WS3 PROD dual-region cold-start — execution plan

> **Status:** DRAFT — authored 2026-06-18. Not yet executed. All five staging
> functions live-verified on 2026-06-18; staging is torn down to $0. This plan
> drives the first PROD cold start: dual-region apply (`eu-central-1` +
> `eu-west-1`) to validate the full IaC path from scratch.
> Tags: **[YOU]** = manual operator step · **[AUTO]** = CI / Terraform does it.

> **中文摘要**:本文是 WS3 PROD dual-region cold-start 的完整執行計劃。前提:
> staging 2026-06-18 五項功能全驗完、已拆除。步驟順序:
> (1) 合併 PR #103(stale-lock 自癒,不觸發 staging apply)→
> (2) 合併 PR #104(per-region model bucket + Route53/DR doc fix,**會觸發 staging apply**,
>     但 staging `bootstrap_complete=true` 且叢集已拆,只 plan-not-apply? 不—apply 會跑,但無叢集可破壞,驗收完需確認 staging TTL-reaper 再清掉)→
> (3) 合併 aegis-core-deploy PR #20(純 docs,無觸發)→
> (4) 確認 prod bootstrap 已完成(本機 tfstate 顯示 prod 帳號 506221082337,但
>     `accounts.json` `bootstrap_complete=false`;需驗 prod 帳號角色是否實際存在)→
> (5) 更新 `REGISTRIES_JSON` 變數(移除 staging model-read ARN,加入 prod 帳號版本)→
> (6) Prod 升版 PR:region flip + `bootstrap_complete=true` + release tag pin(此 PR 合併觸發有審核的 prod apply)→
> (7) 逐區審核、監控、驗證 → (8) 拆除。
> **關鍵 blocker:確認 prod 帳號 CI role 是否真的存在(`gh-tf-apply-platform` in
> 506221082337)** — 本機 bootstrap tfstate 顯示 prod,但需 AWS 端確認。

---

## Prerequisites and known state (2026-06-18)

| Item | Verified state |
|---|---|
| Staging e2e | Torn down to $0. Five functions live-verified on 2026-06-18. |
| `accounts.prod.bootstrap_complete` | `false` (current `accounts.json`) |
| `accounts.prod.pin` | `v0.0.0-PLACEHOLDER` |
| `accounts.prod.enabled_regions` | `["eu-central-1"]` (single region only) |
| `regions.auto.tfvars.json` `eu-west-1.enabled` | `false` |
| Prod local bootstrap state | `terraform/envs/bootstrap/terraform.tfstate` tracks prod account `506221082337` (file mtime 2026-06-17 17:55) — **prod was bootstrapped locally on 2026-06-17; see §1 to verify AWS-side role existence before proceeding** |
| Staging bootstrap state | `terraform/envs/bootstrap/terraform.tfstate.staging` tracks staging `251774439261` |
| `REGISTRIES_JSON` (GitHub repo variable) | Contains `policy_arns: ["arn:aws:iam::251774439261:policy/aegis-core-model-read"]` — the **staging** account ARN. Must be updated to the prod account ARN (§2) before the prod apply, or the prod WorkloadIdentity receives a dangling cross-account policy ARN. |
| PR #103 | Open, not draft. Changes: `.github/workflows/infra-apply-account.yml` + `infra-ops.yml` (stale-lock auto-unlock before every mutate). |
| PR #104 | Open, **draft**. Changes: `terraform/modules/regional-stack/model-store.tf` (moved from platform env), `argocd.tf`, `regional/main.tf`, `regional/variables.tf`, docs. |
| aegis-core-deploy PR #20 | Open, **draft**. Changes: comment-only on `gateway-ingress.yaml`. |

---

## Step 0 — ordered execution checklist

```
[  ] §1   Verify prod bootstrap (AWS role exists)
[  ] §2   Update REGISTRIES_JSON GitHub repo variable for prod
[  ] §3   Merge PR #103 (stale-lock self-heal) — no staging trigger
[  ] §4   Mark PR #104 ready → merge — TRIGGERS staging apply (safe: no cluster)
[  ] §5   Mark aegis-core-deploy PR #20 ready → merge (docs only, no trigger)
[  ] §6   Monitor post-#104 staging apply run: confirm it skips (no cluster) or succeeds cleanly
[  ] §7   Prod promotion PR: region flips + bootstrap_complete=true + release tag pin
[  ] §8   Cloudflare PROD DNS delegation (if not already done)
[  ] §9   Approve prod-apply-gated per region (attend live)
[  ] §10  Populate per-region model buckets
[  ] §11  Run verification (ws3-prod-dual-region-verification.md)
[  ] §12  Teardown (post-verification, or after DR drill)
```

---

## §1 — Verify prod bootstrap status (BLOCKER)

**Why:** `accounts.json` `accounts.prod.bootstrap_complete = false`, but the local
bootstrap Terraform state (`terraform/envs/bootstrap/terraform.tfstate`) tracked
the prod account (`506221082337`) as of 2026-06-17 17:55. The prod CI roles may
already exist in AWS — or may have been torn down. Proceeding with the promotion
PR while `bootstrap_complete = false` causes the CI engine to **skip all apply
jobs** (the `bootstrap_complete` gate in `infra-apply-account.yml`, line 60:
`if: ${{ inputs.bootstrap_complete }}`).

**[YOU]** Verify the prod `gh-tf-apply-platform` role exists:

```bash
# Assumes an SSO profile for the prod account (506221082337)
aws iam get-role --role-name gh-tf-apply-platform \
  --profile aegis-prod-admin --query 'Role.Arn' --output text
```

**Outcome A — role exists (`arn:aws:iam::506221082337:role/gh-tf-apply-platform`):**
Prod is already bootstrapped from the 2026-06-17 run. Skip re-bootstrapping.
Proceed to §2. Set `bootstrap_complete = true` in the promotion PR (§7).

**Outcome B — role does not exist (NoSuchEntityException):**
Run prod bootstrap from break-glass (`AWSControlTowerExecution` assumed from the
management account, as in `ws3-bring-up.md` Phase 1 — substitute account
`506221082337`):

```bash
creds=$(aws sts assume-role \
  --role-arn arn:aws:iam::506221082337:role/AWSControlTowerExecution \
  --role-session-name bootstrap-prod \
  --profile aegis-management-admin \
  --query Credentials --output json)
export AWS_ACCESS_KEY_ID=$(echo "$creds" | jq -r .AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(echo "$creds" | jq -r .SecretAccessKey)
export AWS_SESSION_TOKEN=$(echo "$creds" | jq -r .SessionToken)
aws sts get-caller-identity --query Arn --output text   # confirm 506221082337
cd /Users/bin.hsu/Documents/aegis-platform-aws
make bootstrap ENV=prod    # per-account workspace (issue #90): state under terraform.tfstate.d/prod/
make regenerate-backend ENV=prod
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
```

After bootstrap (either outcome), confirm:

```bash
aws iam get-role --role-name gh-tf-apply-platform \
  --profile aegis-prod-admin --query 'Role.Arn' --output text
aws s3 ls s3://aegis-platform-aws-tfstate-506221082337 \
  --profile aegis-prod-admin
```

Also verify the GitHub OIDC provider exists in the prod account:

```bash
aws iam list-open-id-connect-providers \
  --profile aegis-prod-admin \
  --query 'OpenIDConnectProviderList[*].Arn'
```

If the OIDC provider is missing, create it before the prod apply:

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 \
  --profile aegis-prod-admin
```

---

## §2 — Update REGISTRIES_JSON for prod (operator pre-flight)

**Why:** The current `REGISTRIES_JSON` GitHub repo variable contains:

```json
"policy_arns": ["arn:aws:iam::251774439261:policy/aegis-core-model-read"]
```

This is the **staging** account ARN (`251774439261`). After PR #104 merges, the
regional module auto-appends `aws_iam_policy.model_read.arn` (the
account-correct per-region policy) via `concat(cfg.engine_irsa.policy_arns,
[aws_iam_policy.model_read.arn])`. With the staging ARN still in `policy_arns`,
the prod WorkloadIdentity receives two policy ARNs: a valid prod-account one
(auto-appended) and a dangling cross-account one (the staging entry) — the
IAM role attachment will fail or silently attach a policy from the wrong account.

**[YOU]** Update the repo variable before the promotion PR merge:

```bash
gh variable set REGISTRIES_JSON \
  --repo BinHsu/aegis-platform-aws \
  --body '{
  "workload_registries": {
    "aegis-greeter-deploy": {
      "ecr_account_id": "162975888022",
      "ecr_region": "eu-central-1"
    },
    "aegis-core-deploy": {
      "ecr_account_id": "162975888022",
      "ecr_region": "eu-central-1",
      "engine_irsa": {
        "service_account": "aegis-core-engine",
        "role_name": "aegis-workload/aegis-core-engine",
        "policy_arns": []
      },
      "ingress_cert": {
        "ingress_name": "aegis-core-gateway"
      }
    }
  }
}'
```

Key change: `policy_arns` is an **empty array** `[]`. The per-region
`aws_iam_policy.model_read` is auto-appended by the module for each region —
no hand-wiring needed. Removing the staging-account ARN eliminates the
dangling-ARN risk entirely.

> **After teardown** (§12): restore the staging ARN if staging is
> re-bootstrapped later, or leave `[]` (the module auto-appends the
> account-correct policy either way).

---

## §3 — Merge PR #103 (stale-lock self-heal) — merge first

**Rationale:** PR #103 adds a guarded auto-unlock step before every Terraform
mutate (apply-platform, apply-regional, destroy-region, destroy-platform) in
`infra-apply-account.yml` and `infra-ops.yml`. The stale-lock wedge was hit
during the 2026-06-18 staging teardown. Merging this first means the prod
cold-start has the self-heal in place.

**Trigger analysis:** PR #103 touches only `.github/workflows/`. The
`infra-staging.yml` trigger covers `terraform/**`, `regions.auto.tfvars.json`,
and `accounts.json` — NOT `.github/workflows/`. Merging PR #103 does **not**
trigger `infra-staging`. Safe to merge independently.

**[YOU]** Mark ready (not draft — already not draft), review the diff, merge.

```bash
gh pr merge 103 --repo BinHsu/aegis-platform-aws --squash
```

Confirm CI passes on the merge commit (infra-plan runs on the PR; the merge
itself has no infra run):

```bash
gh run list --repo BinHsu/aegis-platform-aws --limit 5
```

---

## §4 — Merge PR #104 (dual-region IaC capability) — merge second

**Rationale:** PR #104 closes the three gaps that block a real dual-region prod:

- **Gap A** — per-region model bucket: moves `model-store.tf` into the regional
  module so `eu-west-1` has its own `aegis-core-models-506221082337-eu-west-1`
  bucket and its own `aegis-core-model-read-eu-west-1` policy. The module
  auto-appends the per-region policy ARN via `concat()` in `argocd.tf`.
- **Gap B** — Route 53 latency routing: doc fix only (the routing annotations
  already landed in `aegis-core-deploy` PR #14; the stale doc claimed they were
  "not yet implemented").
- **Gap C** — DR docs: `ADR-05` and `dr-plan.md` now read as a built capability
  armed by an enable-flip, not a live deployed state.

**Trigger analysis:** PR #104 touches `terraform/modules/regional-stack/` and
`terraform/envs/regional/` — both match the `terraform/**` path in
`infra-staging.yml`. Merging PR #104 to `main` **will trigger `infra-staging`**.

The staging account (`accounts.staging.bootstrap_complete = true`) has no live
cluster (torn down 2026-06-18). The staging apply will run (`apply-platform`
then `apply-regional` matrix over `["eu-central-1"]`). This is safe — the IaC
is idempotent; the apply creates the staging cluster. However, this means a new
**staging cluster will spin up** (billable) unless you act.

**Options:**

1. **Accept the staging re-apply** — let it run, verify it green (proves PR
   #104 applies cleanly on staging), then immediately dispatch `infra-ops`
   `destroy-region` + `destroy-platform` for staging. Poll at 1-min cadence
   per the cost-monitoring rule.
2. **Temporarily flip staging `bootstrap_complete = false`** before merging
   #104, then flip it back after verifying prod. This prevents the staging
   trigger from applying. Introduces a small window where staging infra-plan CI
   would skip.

**Recommended: option 1** — the staging re-apply is a free proof of PR #104's
correctness before it hits prod. Attend the run, destroy staging immediately
after it confirms green.

**[YOU]** Mark PR #104 ready for review, then merge:

```bash
gh pr ready 104 --repo BinHsu/aegis-platform-aws
gh pr merge 104 --repo BinHsu/aegis-platform-aws --squash
```

Monitor the triggered staging apply (§6).

---

## §5 — Merge aegis-core-deploy PR #20 (docs only) — any time

PR #20 is a comment-only change to `components/aws-binding/gateway-ingress.yaml`
pinning the verified Route 53 latency-routing annotation rationale. No functional
change, no Terraform, no K8s mutation — no trigger in any workflow. Merge
independently; order relative to #103/#104 does not matter.

```bash
gh pr ready 20 --repo BinHsu/aegis-core-deploy
gh pr merge 20 --repo BinHsu/aegis-core-deploy --squash
```

---

## §6 — Monitor post-#104 staging apply

After PR #104 merges, `infra-staging` fires. Watch it green:

```bash
gh run watch --repo BinHsu/aegis-platform-aws
```

Poll at ~1-minute cadence (the run creates two EKS nodes and an ALB). If the
apply fails, it self-reaps (unless `ALLOW_PARTIAL_APPLY=true` — that var was set
`true` during the 2026-06-18 session; **confirm it is back to `false`** before
this run):

```bash
gh variable get ALLOW_PARTIAL_APPLY --repo BinHsu/aegis-platform-aws
```

If it is still `true`, set it to `false` first:

```bash
gh variable set ALLOW_PARTIAL_APPLY --repo BinHsu/aegis-platform-aws --body "false"
```

Once the staging apply is green, immediately tear down staging (do not leave it
running — it bills):

```bash
# Dispatch destroy-region then destroy-platform via infra-ops
gh workflow run infra-ops.yml --repo BinHsu/aegis-platform-aws \
  -f operation=destroy-region -f account_id=251774439261 -f region=eu-central-1
# After destroy-region completes:
gh workflow run infra-ops.yml --repo BinHsu/aegis-platform-aws \
  -f operation=destroy-platform -f account_id=251774439261
```

Poll both destroy runs at 1-minute cadence. If destroy fails, the resources are
still billing — escalate immediately, do not wait for the TTL reaper.

---

## §7 — Cloudflare PROD DNS delegation (if not yet done)

**[YOU]** The prod zone `prod.aws.binhsu.org` must be pre-created and delegated
before the regional apply — ACM DNS-01 validation will block until the NS record
resolves. This step is a **pre-apply pre-requisite** if the prod zone NS is not
already in Cloudflare.

```bash
# Targeted-apply JUST the prod zone (break-glass or gh-tf-apply-platform creds)
export AWS_PROFILE=aegis-prod-admin
terraform -chdir=/Users/bin.hsu/Documents/aegis-platform-aws/terraform/envs/platform \
  apply -target=aws_route53_zone.main \
  -var-file=/Users/bin.hsu/Documents/aegis-platform-aws/regions.auto.tfvars.json
terraform -chdir=/Users/bin.hsu/Documents/aegis-platform-aws/terraform/envs/platform \
  output zone_name_servers
```

In Cloudflare (the `binhsu.org` zone), add an NS record:
- Name: `prod.aws`
- Value: the four NS returned above

Confirm delegation:

```bash
dig NS prod.aws.binhsu.org +short   # must return the AWS NS servers
```

---

## §8 — PROD promotion PR (the enable-flip)

This is the commit that triggers the gated prod apply. Keep capability PRs
(#103, #104) and this enable-flip **separate** — the separation is deliberate
per the PR #104 description.

All three changes go into ONE promotion PR and are tagged together:

### Exact diffs

**(1) `regions.auto.tfvars.json`** — enable `eu-west-1` globally:

```diff
   "eu-west-1": {
-    "enabled": false,
+    "enabled": true,
     "cidr": "10.20.0.0/16",
     "node_instance": "t3.large",
     "node_min": 3,
     "node_max": 4
   }
```

This flag drives ECR replication (`ecr.tf`
`active_regions = { for r, v in var.regions : r => v if v.enabled }`). Without
it, `eu-west-1` gets no ECR replica even if it is in `enabled_regions`.

**(2) `accounts.json`** — flip prod to ready and add `eu-west-1`:

```diff
   "prod": {
     "account_id": "506221082337",
     "environment": "prod",
-    "pin": "v0.0.0-PLACEHOLDER",
+    "pin": "v0.1.0",       ← the release tag you cut (see below)
     "enabled_regions": [
-      "eu-central-1"
+      "eu-central-1",
+      "eu-west-1"
     ],
-    "bootstrap_complete": false,
+    "bootstrap_complete": true,
     "operator_principal_arn": "arn:aws:iam::506221082337:role/aws-reserved/sso.amazonaws.com/eu-central-1/AWSReservedSSO_PlatformAdmin_ce1bee9d4ea54a0a"
   }
```

**Source-of-truth note** (from `accounts.json` `_comment`): `accounts.json`
topology + pins are read from **HEAD** by the `detect` job. The tf tree and
`regions.auto.tfvars.json` scalars come from the **pinned ref** (the release
tag). Both files must therefore be on the release tag commit AND on HEAD. The
safest approach: cut the tag from the same commit that merges the promotion PR.

### How to cut the release tag and merge

1. **[YOU]** Open the promotion PR with the two diff above. Get CI green
   (infra-plan runs against the tag's tree).
2. **[YOU]** Merge the PR to `main`.
3. **[YOU]** Tag that merge commit:

```bash
git tag v0.1.0 HEAD
git push origin v0.1.0
```

4. **[AUTO]** `infra-prod.yml` `detect` job fires on the `accounts.json` push.
   It reads `accounts.prod.pin = "v0.1.0"`, confirms it changed from
   `v0.0.0-PLACEHOLDER`, and sets `pin_changed=true`. It calls
   `infra-apply-account.yml` at ref `v0.1.0`.

### What triggers what

- The promotion PR changes `accounts.json` → `infra-prod.yml` fires (pin
  changed from placeholder to a real tag).
- The promotion PR also changes `regions.auto.tfvars.json` → `infra-staging.yml`
  also fires. Staging's apply will see `eu-west-1.enabled=true` but staging's
  `enabled_regions` is still `["eu-central-1"]` — the matrix only fans over the
  account's `enabled_regions`, so staging does **not** create a `eu-west-1`
  cluster. The `eu-west-1.enabled=true` does add `eu-west-1` as an ECR
  replication destination in staging — negligible cost, harmless.

---

## §9 — Prod apply gate (attend live, 1-minute poll cadence)

`apply-regional` runs in the **`prod-apply-gated`** GitHub environment (requires
reviewer approval). The `detect` job sets `regions_json=["eu-central-1","eu-west-1"]`,
so `apply-regional` fans into **two matrix jobs**, one per region. Each matrix job
runs in `prod-apply-gated` and waits for your approval independently.

**[YOU]** Watch for the pending approval:

```bash
gh run list --repo BinHsu/aegis-platform-aws --workflow infra-prod.yml --limit 5
gh run view <run-id>   # shows the environment approval gate
```

**Before approving each region**, confirm:

- `apply-platform` is green (Cognito pool, model bucket policy, Route 53 PROD zone, ECR + replication configured).
- The Cloudflare NS delegation for `prod.aws.binhsu.org` resolves (§7).
- `REGISTRIES_JSON` has been updated (§2, empty `policy_arns`).
- `ALLOW_PARTIAL_APPLY` is `false` — self-reap is live.

**[YOU] APPROVE** the `prod-apply-gated` gate for each region:

```bash
# Approval is via the GitHub UI (Settings → Environments → prod-apply-gated),
# or via the gh CLI run review command:
gh run approve <run-id>  # if supported in your gh version; else use the UI
```

**Billing starts the moment you approve.** From the approval forward, poll at
exactly 1-minute cadence until both regions report green:

```bash
# One-liner to watch and alert on completion or failure:
gh run watch <run-id> --repo BinHsu/aegis-platform-aws --exit-status
```

Estimated wall time per region: ~30–45 minutes (EKS control-plane provisioning
dominates). The two regions run **in parallel** (the matrix uses `fail-fast:
false`), so the total wall time is the slower region's time, not 2x.

**If a region apply fails:**

- With `ALLOW_PARTIAL_APPLY=false`: the self-reap destroys the partial stack.
  Poll the destroy leg of the same run to confirm it completes.
- If self-reap also fails: dispatch `infra-ops` `destroy-region` for that
  account + region immediately. Do not leave a half-applied stack running.

---

## §10 — Populate per-region model buckets (pre-ArgoCD-sync, post-apply)

**Why:** PR #104 makes the model bucket **per-region**. Each region's engine
init-container runs `aws s3 sync s3://aegis-core-models-<acct>-<region> /models`.
An empty bucket fails loud at engine startup (`model-fetch` init-container exits
non-zero → engine pod stuck in Init state). Populate both buckets before the
ArgoCD sync reaches the engine Rollout.

Bucket names (deterministic):

- `eu-central-1`: `aegis-core-models-506221082337-eu-central-1`
- `eu-west-1`: `aegis-core-models-506221082337-eu-west-1`

```bash
# Assuming model artifacts are in a local path or the staging source bucket
# (replace SOURCE with wherever you staged the model files during staging):

for REGION in eu-central-1 eu-west-1; do
  BUCKET="aegis-core-models-506221082337-${REGION}"
  echo "Populating ${BUCKET}..."
  aws s3 sync /path/to/model/artifacts "s3://${BUCKET}" \
    --profile aegis-prod-admin
done
```

Confirm both buckets are non-empty before ArgoCD reaches the engine:

```bash
for REGION in eu-central-1 eu-west-1; do
  BUCKET="aegis-core-models-506221082337-${REGION}"
  COUNT=$(aws s3 ls "s3://${BUCKET}" --recursive --summarize \
    --profile aegis-prod-admin | tail -1)
  echo "${BUCKET}: ${COUNT}"
done
```

---

## §11 — Verification

See the sibling runbook:
`docs/runbooks/ws3-prod-dual-region-verification.md`

That document is the authoritative verification matrix. Summary of what it
covers:

- **Per-region (§1, run twice — once per region):** gateway HTTPS healthz;
  engine IRSA→model-pull; OIDC auth BVA (no-token / bad-token / tampered /
  valid); PKCE flow → id_token with `custom:tenant_id`; real transcription.
- **Dual-region specific (§2):** two matrix `apply-regional` jobs green; two
  EKS clusters with non-overlapping CIDRs; ACM certs `ISSUED` per region; ECR
  cross-region replication confirmed; Route 53 latency records (two records with
  distinct `set-identifier`s); DR failover drill (kill one region, confirm
  survivor serves within the health-check + DNS-TTL window).

The same PROD Cognito pool (platform region `eu-central-1`) issues tokens for
both regions. One PKCE id_token is valid in both gateways — confirm by passing
the same `ID_TOKEN` to the OIDC BVA in each region's cluster.

---

## §12 — Teardown (stop billing)

Prod dual-region runs two EKS control planes, two NAT gateways, and two ALBs
(approximately $0.40/hr). After verification (or after a DR drill), tear down
in order:

```bash
# Destroy eu-west-1 first (non-platform region)
gh workflow run infra-ops.yml --repo BinHsu/aegis-platform-aws \
  -f operation=destroy-region -f account_id=506221082337 -f region=eu-west-1

# After eu-west-1 destroy confirms green, destroy eu-central-1
gh workflow run infra-ops.yml --repo BinHsu/aegis-platform-aws \
  -f operation=destroy-region -f account_id=506221082337 -f region=eu-central-1

# After both regions destroyed, destroy the platform tier
gh workflow run infra-ops.yml --repo BinHsu/aegis-platform-aws \
  -f operation=destroy-platform -f account_id=506221082337
```

Poll each at 1-minute cadence. A failed destroy still bills until it completes.
The known `VPC DependencyViolation` from orphaned ALB security groups is handled
by the two-phase sweep / background SG reaper in `infra-apply-account.yml`
(merged with #103's stale-lock fix).

> **Known orphan — the engine IRSA role (until Pod Identity lands).** The engine's
> IAM role is composed IN-CLUSTER by Crossplane (the `aegis-xrds` WorkloadIdentity
> Composition), so its lifecycle is the controller's reconcile loop, NOT the
> Terraform stack. Tearing down the cluster before the `WorkloadIdentity` claim is
> reconcile-deleted ORPHANS the role at IAM path `/aegis-workload/aegis-core-engine`
> (created the moment ArgoCD syncs the engine). It is **free** (IAM), so it does not
> block `$0`, BUT it will collide on the next bring-up (`aegis-core-model-read-<region>`
> duplicate-name on re-apply). Two reasons it survives a normal cleanup: Terraform
> doesn't manage it, and an SCP blocks `PlatformAdmin` from deleting `/aegis-workload/`.
> **Clean it before the next eu-west-1 apply** by assuming the SCP-exempt break-glass
> role (2026-06-18 observed; 2026-06-19 cleaned this way):
>
> ```bash
> creds=$(aws sts assume-role --role-arn arn:aws:iam::<acct>:role/aegis-emergency-break-glass \
>   --role-session-name orphan-cleanup --profile aegis-prod-admin --query Credentials --output json)
> # export the creds, then:
> aws iam detach-role-policy --role-name aegis-core-engine --policy-arn arn:aws:iam::<acct>:policy/aegis-core-model-read-<region>
> aws iam delete-policy --policy-arn arn:aws:iam::<acct>:policy/aegis-core-model-read-<region>
> aws iam delete-role  --role-name aegis-core-engine
> ```
>
> **Permanent fix:** the EKS Pod Identity migration (ADR-21 §A) makes the engine role
> Terraform-managed → destroyed cleanly with the stack → no orphan, no break-glass.
> Once that lands, delete this note.

**After teardown:**

1. Flip `accounts.prod.bootstrap_complete` back to `false` in `accounts.json`
   and reset `pin` to `v0.0.0-PLACEHOLDER`. Otherwise the next infra-plan reads
   a deleted role ARN and fails.
2. Reset `regions.auto.tfvars.json` `eu-west-1.enabled` to `false` if you want
   to park the second region after verification (or leave it `true` if you intend
   to keep dual-region permanently).
3. Confirm `$0` in Cost Explorer (1–2 hours after all resources delete).

---

## Safety callout — prod apply is NOT a background job

The gated prod apply must have **live operator attendance** from the moment you
approve `prod-apply-gated` to the moment both regions confirm green (or
self-reap) and billing starts winding down. Specifically:

- Poll at **~1-minute** cadence (not 5-minute, not "check back later").
- A failed `apply-regional` that self-reaps still bills during the reap — watch
  the reap leg, not just the apply leg.
- A stale lock will now self-heal (PR #103), but if the lock-clear itself fails
  (e.g. the IAM role cannot `s3:DeleteObject` the `.tflock`), the run wedges
  silently — 1-minute polling catches this within one minute.
- The `prod-apply-gated` environment has no timeout beyond the GitHub 6-hour
  workflow timeout. Do not approve and walk away.

---

## Blockers and unknowns (as of 2026-06-18)

| # | Item | Impact | Resolution |
|---|---|---|---|
| **B1** | Prod CI role existence unconfirmed in AWS | If roles do not exist, `infra-prod.yml` apply-platform fails immediately (cannot assume `gh-tf-apply-platform`) | Run `aws iam get-role` in §1; re-bootstrap if missing |
| **B2** | Cloudflare PROD zone delegation status unknown | ACM DNS-01 validation blocks `apply-regional` if NS is not delegated | Confirm `dig NS prod.aws.binhsu.org +short` before approving the gate (§7) |
| **B3** | `REGISTRIES_JSON` staging ARN still present | Prod WorkloadIdentity gets dangling cross-account policy ARN; IAM role-policy attachment fails | Update the variable before the promotion PR merge (§2) |
| **B4** | PR #104 is draft | Cannot merge a draft PR | Mark ready before merge (§4) |
| **B5** | PR #20 (aegis-core-deploy) is draft | Cannot merge | Mark ready before merge (§5) |
| **U1** | Whether the staging re-apply from PR #104 merge creates a cluster and how long it runs | Billable until explicitly destroyed | Monitor post-#104 run; destroy immediately after green (§6) |
| **U2** | ECR `RepositoryNotEmptyException` on platform destroy | Blocks `destroy-platform` if images are in the shared ECR | Ensure `force_delete = true` is set in `deployment-ecr.tf` (check before first apply) |

---

## Execution log — 2026-06-18 (prod-first run)

**Operator decision (Bin, 2026-06-18 ~19:30 CEST):** skip the §4 staging re-apply
proof; go straight to the prod cold-start. Both staging AND prod must be at **$0**
(no billable resources) by end of night — this is a verify-then-teardown run, not a
durable deployment. Teardown (§12) is mandatory tonight.

**§1 prod bootstrap — verified (Outcome A, no re-bootstrap):**

- `aws sts get-caller-identity --profile aegis-prod-admin` → `506221082337` PlatformAdmin.
- `gh-tf-apply-platform` role exists; GitHub OIDC provider exists; tfstate bucket
  `aegis-platform-aws-tfstate-506221082337` exists.
- Both state objects (`platform/`, `regional/eu-central-1/`) hold **0 resources**
  (serial-only, lineage from prior apply+destroy cycles). No EKS / NAT GW / ALB in
  either region. The two non-default VPCs are `aws-controltower-VPC` (172.31.0.0/16),
  Control Tower baseline — not ours, not billable. **Prod is a clean cold start at $0.**

**Deviation — staging skipped (instead of runbook §4 option 1):**

- Mechanism: `accounts.staging.bootstrap_complete` flipped to `false` (same commit as
  this log). Merging PR #104 still fires `infra-staging`, but the apply jobs **skip**
  on the false gate — no staging cluster, no staging spend. Restore to `true` after
  the prod run (staging IS bootstrapped; the flag is a CI apply gate, not ground truth).
- `deployment_account_id` is **left on staging** (not migrated to prod). The shared ECR
  in `162975888022` already exists with the `aegis-core` (gateway `staging-<sha>` +
  `engine-staging-<sha>`) and `aegis-greeter` images. Migrating ownership to prod would
  make `deployment-ecr.tf` try to **create** repos that already exist → conflict. Leaving
  it on staging keeps the existing repos usable; no apply touches them this cycle.

**Cross-account ECR — verified usable from prod:**

- `aegis-core` + `aegis-greeter` repository policy (`AllowClusterAccountsPull`) already
  grants `arn:aws:iam::506221082337:root` (prod) the pull verbs. **Prod nodes can pull.**
- Registry replication config is `rules: []` — **no eu-west-1 ECR replica**. Because the
  deployment-account platform apply is skipped this cycle, replication is not configured.
  **eu-west-1 engine/gateway pull images cross-region from the eu-central-1 ECR** (a
  one-time pull at pod start; cross-region data-transfer cost is negligible). The §11
  "ECR cross-region replication confirmed" check is therefore **N/A for this run** —
  documented limitation, not a functional blocker. The per-region **model bucket** (the
  actual hot path) remains in-region per ADR-05.

**Baseline at start (2026-06-18 ~19:30):** staging $0 (both regions empty), prod $0.
