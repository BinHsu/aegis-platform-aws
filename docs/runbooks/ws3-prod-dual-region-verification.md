# WS3 PROD dual-region cold-start verification runbook

> **Status:** DRAFT — authored 2026-06-18, not yet exercised. PROD has never been
> applied (`accounts.prod.bootstrap_complete = false`, `accounts.prod.pin =
> v0.0.0-PLACEHOLDER`). This runbook covers the **first PROD cold start**, run as
> a dual-region apply (`eu-central-1` + `eu-west-1`).
> Tags: **[YOU]** = manual operator step · **[AUTO]** = CI/Terraform does it.

> **中文摘要**:本 runbook 驗證 PROD 第一次 cold start,範圍 = staging 2026-06-18
> 已實證的完整功能矩陣(gateway / engine IRSA→model / OIDC 驗章 BVA / PKCE /
> 真實 transcription)**逐區重跑一次**,**外加** staging 單區無法驗的多區/DR 維度
> (跨區 ECR replication、latency/failover Route 53、kill 一區看另一區頂上)。
> 功能正確性已在 staging 收斂,PROD 只證 cold-start + 多區能動,**不重新 debug 功能**。
> ⚠️ 三個 IaC gap 必須先補(見 §0.3),否則「多區/DR」只是部署兩座孤立叢集,
> 沒有 latency routing、沒有 failover、engine 跨區讀 model bucket。先補 IaC,再跑驗證。

---

## How PROD differs from staging — the delta in one paragraph

Staging proved every **function** on a single region (`eu-central-1`): the gateway
serves HTTPS, the engine pulls its model under IRSA, OIDC JWT validation rejects
bad tokens and accepts a real PKCE id_token, and the engine returns a correct
transcript. PROD repeats that **same functional matrix in each enabled region** —
the per-region checks below are run once per region — and adds the dimension a
single region cannot exercise: two regions serving the same hostname behind
Route 53, ECR images replicated to the second region, and a failover drill that
kills one region and confirms the survivor serves. Nothing here re-debugs
functionality; PROD validates **cold start + multi-region**.

---

## 0 — Pre-flight

### 0.1 Accounts and names (from `accounts.json`, `terraform/envs/platform/route53.tf`)

- PROD account `506221082337` · deployment account `162975888022` · platform
  region `eu-central-1` (`accounts.json` `platform_region`).
- Regions for this run: `eu-central-1` + `eu-west-1`.
- PROD zone (`route53.tf` `local.zone_name = "${var.environment}.${var.dns_zone_name}"`):
  `prod.aws.binhsu.org`.
- Hosts: gateway `aegis-api.prod.aws.binhsu.org`; SPA `app.prod.aws.binhsu.org`.
- Deterministic per-account names: state bucket
  `aegis-platform-aws-tfstate-506221082337`; apply role
  `arn:aws:iam::506221082337:role/gh-tf-apply-platform`; model-read policy
  `arn:aws:iam::506221082337:policy/aegis-core-model-read`; model bucket (single,
  platform-region — see §0.3 gap A) `aegis-core-models-506221082337-eu-central-1`.

### 0.2 The exact config flips to enable PROD dual-region

Two files, verified against how the workflows read them:

**(1) `regions.auto.tfvars.json`** — flip `eu-west-1.enabled` to `true`. This is
the **global** region table; `terraform/envs/platform/ecr.tf`
(`active_regions = { for r, v in var.regions : r => v if v.enabled }`) reads it to
decide ECR replication destinations, and the CI extracts each region's
`cidr / node_instance / node_min / node_max` from it via `jq`
(`infra-apply-account.yml`, the "effective per-region scalars" step). A region in
`enabled_regions` (file 2) but with `enabled:false` here would get **no scalars**
and **no ECR replication** — both files must agree.

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

**(2) `accounts.json`** — add `eu-west-1` to **PROD's** `enabled_regions` only.
`infra-prod.yml`'s `detect` job emits `regions_json = .accounts.prod.enabled_regions`,
and `infra-apply-account.yml` fans `apply-regional` out as a matrix over that array
(`matrix.region: ${{ fromJson(needs.setup.outputs.enabled_regions) }}`). Staging
stays single-region — the per-account gate keeps the environments isolated.

```diff
   "prod": {
     "account_id": "506221082337",
     "environment": "prod",
-    "pin": "v0.0.0-PLACEHOLDER",
+    "pin": "v0.0.0-PLACEHOLDER",   ← changed in §0.4, the promotion PR
     "enabled_regions": [
-      "eu-central-1"
+      "eu-central-1",
+      "eu-west-1"
     ],
     "bootstrap_complete": false,   ← flipped to true in §0.4
     "operator_principal_arn": "...AWSReservedSSO_PlatformAdmin_ce1bee9d4ea54a0a"
   }
```

> **Source-of-truth split (from the `accounts.json` `_comment`):** topology +
> pins (`accounts.json`) are read from **HEAD**; the tf tree + scalars
> (`regions.auto.tfvars.json`) come from the **pinned ref**. So both edits must be
> on the release tag you pin in §0.4 *and* on HEAD for the detect job to see them.
> Land both in the same promotion PR and tag that commit.

### 0.3 IaC gaps — fix BEFORE the apply, or "dual-region" is two isolated clusters

These three gaps mean the repo, as it stands on this branch, deploys two
independent regional stacks but does **not** implement the multi-region/DR
posture that ADR-05 and `docs/dr-plan.md` describe as "deployed". Each is a
prerequisite for a meaningful dual-region verification.

| # | Gap | Evidence | Impact if unfixed |
|---|---|---|---|
| **A** | **Single model bucket, cross-region read.** `terraform/envs/platform/model-store.tf` names exactly one bucket `aegis-core-models-<acct>-${var.platform_region}` (platform region only); `terraform/envs/regional/main.tf:42` wires every region's engine to `data.terraform_remote_state.platform.outputs.model_bucket_name` — the same bucket. | `model-store.tf` `local.model_bucket_name`; `argocd.tf` comment "single model bucket cross-region". | `eu-west-1`'s engine `model-fetch` does a **cross-region** `aws s3 sync` from the `eu-central-1` bucket. Works, but adds cross-region data-transfer cost and a hard dependency on the platform region during the second region's cold start. **Decision needed:** accept cross-region read (document it) OR add a per-region bucket + S3 CRR. The user's intent ("model populated per region") implies per-region buckets — that is **not** what the IaC does today. |
| **B** | **No Route 53 latency/failover routing.** `terraform/modules/regional-stack/external-dns.tf` installs external-dns with `policy=sync` and a per-region `txtOwnerId`, but sets **no** `aws-routing-policy` and **no** `set-identifier`. The routing annotations live on the gateway Ingress in the **deploy repo** (`aegis-core-deploy`), not here. | `regional-stack/README.md` lines 30–33: latency routing + `set-identifier: <region>` is "**recommended; not yet implemented** … records are not yet populated". | Two external-dns instances write the **same** `aegis-api.prod.aws.binhsu.org` A record without a set-identifier → they fight over one record via the TXT registry; there is **no** latency steering and **no** health-check failover. ADR-05's "external-dns latency records with evaluate-target-health" and the dr-plan "~1–2 min failover" are **aspirational, not implemented**. **Must wire** `external-dns.alpha.kubernetes.io/aws-routing-policy: latency` (or `failover`), `set-identifier: <region>`, and `alias.target-health` on the gateway Ingress (deploy repo) **before** any failover claim is true. |
| **C** | **DR docs overstate current state.** `docs/ADR/05-disaster-recovery.md` and `docs/dr-plan.md` both narrate "Two regions are deployed (`eu-central-1` + `eu-west-1`)" and latency/failover as live. Neither is true: `regions.auto.tfvars.json` has `eu-west-1.enabled=false`, `accounts.json` PROD is single-region, and gap B is open. | The two files vs. the two config files. | Operator reading the DR docs would assume failover works. After fixing A/B and running this runbook, **update ADR-05 + dr-plan.md** to match reality (or mark them as the target state). |

> **ECR cross-region replication is the one multi-region piece that IS wired:**
> `ecr.tf` `aws_ecr_replication_configuration.main` replicates from
> `platform_region` to every other `active_region` — it activates automatically
> once §0.2 flip (1) sets `eu-west-1.enabled=true`. No gap here.

### 0.4 PROD trigger and gate (from `infra-prod.yml` + `infra-apply-account.yml`)

PROD is **promotion-driven**, not dispatch-driven. The sequence:

1. **[YOU]** Bootstrap the PROD account if not already done — break-glass
   `AWSControlTowerExecution`, `make bootstrap` (see `ws3-bring-up.md` Phase 1,
   substituting `506221082337`). Creates the state bucket + the six CI roles.
2. **[YOU]** Pre-create + delegate the PROD zone **before** the full apply, so the
   regional ACM DNS-01 validation does not block: targeted-apply
   `aws_route53_zone.main`, read `zone_name_servers`, add the `prod.aws` NS record
   in Cloudflare (`ws3-bring-up.md` Phase 5). Confirm `dig NS prod.aws.binhsu.org`.
3. **[YOU]** Land the promotion PR: §0.2 region flips **+** `bootstrap_complete=true`
   **+** `pin` = a real release tag (cut at the verified commit). Merge to `main`.
4. **[AUTO]** `infra-prod.yml` `detect` fires only on a real `pin` change (skips the
   placeholder and the no-op). It checks out the **tag** and calls
   `infra-apply-account.yml` with `gate_blocks: true`.
5. **[AUTO]** `version-gate` HARD-FAILS the whole run before any apply if the EKS
   version has aged out of standard support (PROD never gets extended-support cost,
   not even behind approval). Then `apply-platform` (one apply, platform region:
   Cognito pool/client/domain + pre-token Lambda, model bucket + read policy, PROD
   Route 53 zone, ECR + replication config, shared deployment ECR).
6. **[AUTO]** `apply-regional` runs as a **matrix over both regions**, each in the
   **`prod-apply-gated`** environment (`environment: ${{ inputs.gate_blocks &&
   'prod-apply-gated' || 'staging' }}`). Each region waits on its own approval.
7. **[YOU] APPROVE** each `prod-apply-gated` deployment. **Billable from here** —
   two EKS control planes + two NAT + two ALB (~$0.40/hr dual-region).

> **Cost-incurring run discipline:** once approved, poll the run at ~1-minute
> cadence (`gh run watch`). A failed `apply-regional` self-reaps its partial stack
> only when `REAP_ON_APPLY_FAILURE=true` (opt-in; `infra-apply-account.yml`
> self-reap step). The unset/false default KEEPS the partial stack — for an
> unattended run set the var `true`, or dispatch `infra-ops destroy-region` on
> failure. A failed *teardown* still bills until it finishes — watch it too.

---

## 1 — Per-region functional checklist (run once per region)

Repeat **all five** for `eu-central-1` AND `eu-west-1`. These are exactly the
checks staging proved on 2026-06-18; PROD re-runs them per region to prove the
**cold start** produced a working stack, not to re-debug function. Set context per
region:

```bash
REGION=eu-central-1   # then repeat the whole section with REGION=eu-west-1
aws eks update-kubeconfig --name aegis-platform-${REGION} --region ${REGION} --profile aegis-prod-admin
```

### 1.1 Gateway up + HTTPS healthz
- ArgoCD `aegis-core` app **Synced/Healthy** in this region's cluster.
- `aegis-core-gateway` Rollout **1/1** (`kubectl argo rollouts get rollout aegis-core-gateway -n aegis-core`).
- ALB provisioned (the gateway Ingress has an `ADDRESS`).
- `curl -fsS https://aegis-api.prod.aws.binhsu.org/healthz` → **200**.
  - Per-region note: until gap B is fixed there is one shared hostname. To test
    THIS region's ALB directly, `curl` the region's ALB DNS name with a `Host:`
    header, or resolve the hostname while the other region is scaled to zero.

### 1.2 Engine IRSA → model
- Crossplane `provider-aws-iam` **Healthy**; the `WorkloadIdentity` composite
  **Synced/Ready**; AWS role `aegis-workload/aegis-core-engine` exists in PROD.
- Engine init `model-fetch` completes the `aws s3 sync` from the model bucket
  (gap A: that bucket is `aegis-core-models-506221082337-eu-central-1` for **both**
  regions — `eu-west-1` reads it cross-region).
- Engine pod **1/1 Running** (`kubectl get pod -n aegis-core -l app=aegis-core-engine`).
- **Dual-region pre-req:** the model object must be present in whatever bucket the
  region reads. With gap A unfixed that is the single platform-region bucket
  (populate once). If you fix gap A to per-region buckets, **populate each region's
  bucket** before this check.

### 1.3 OIDC auth BVA at the gateway gRPC port (`:9090`, `aegis.v1.Gateway/ListCorpora`)
Port-forward and exercise the boundary with `grpcurl` (the gateway validates the
Cognito **id_token**: `aud=clientId` + `custom:tenant_id` — see `cognito.tf`,
`cognito-lambda.tf`, and the RETRO's auth note):

```bash
kubectl -n aegis-core port-forward svc/aegis-core-gateway 9090:9090 &
# B-1 (no credential): no token
grpcurl -plaintext localhost:9090 aegis.v1.Gateway/ListCorpora                 # → Unauthenticated
# B   (malformed): garbage token
grpcurl -plaintext -H 'authorization: Bearer garbage' localhost:9090 aegis.v1.Gateway/ListCorpora   # → Unauthenticated
# B   (tampered): valid token with last signature byte flipped
grpcurl -plaintext -H "authorization: Bearer ${TAMPERED}" localhost:9090 aegis.v1.Gateway/ListCorpora # → Unauthenticated
# B+1 (valid): real PKCE id_token (from 1.4)
grpcurl -plaintext -H "authorization: Bearer ${ID_TOKEN}" localhost:9090 aegis.v1.Gateway/ListCorpora # → passes auth (reaches engine)
```

### 1.4 PKCE flow → id_token carrying `custom:tenant_id`
- Seed a PROD Cognito user (`aws cognito-idp admin-create-user …` — sign-up is
  admin-only, `cognito.tf` `allow_admin_create_user_only=true`) and assign
  `custom:tenant_id` (admin-only; the SPA client cannot write it).
- Run the Hosted-UI authorization-code + PKCE login → obtain the **id_token**.
- Decode it: it MUST carry `custom:tenant_id` (injected by the pre-token Lambda,
  `cognito-lambda.tf`). Absent it, the gateway rejects with
  `Unauthenticated: missing tenant id claim`.
- **Dual-region note:** there is ONE PROD Cognito pool (platform-region;
  `cognito.tf` issuer `cognito-idp.eu-central-1.amazonaws.com/<pool>`). Both
  regions' gateways validate against the **same** issuer/JWKS — the same id_token
  works in both. The pre-token Lambda is **per-pool**, so it covers both regions.
  Confirm by passing the same `ID_TOKEN` to step 1.3 in **each** region.

### 1.5 Real transcription (`aegis.v1.Engine/StreamTranscribe`, `:50051`)
Generate audio on macOS, strip the WAV header to raw PCM, and stream:

```bash
say -o x.aiff "the quick brown fox jumps over the lazy dog"
afconvert -f WAVE -d LEI16@16000 -c 1 x.aiff x.wav   # 16 kHz / mono / s16le
tail -c +45 x.wav > x.pcm                             # drop the 44-byte WAV header → raw PCM
kubectl -n aegis-core port-forward svc/aegis-core-engine 50051:50051 &
# stream SessionStart(16kHz/1ch/16bit) + PcmChunk(s16le) + ControlEvent(CONTROL_KIND_END_STREAM)
# → expect a TranscriptSegment with the correct text
```

---

## 2 — Dual-region / DR-specific checks (the delta over staging)

Run these **after** both regions pass §1. These are the steps staging's single
region could not exercise.

### 2.1 Both regional stacks exist and are independent
- `apply-regional` matrix shows **two** green jobs (`eu-central-1`, `eu-west-1`).
- Two EKS clusters (`aegis-platform-eu-central-1`, `aegis-platform-eu-west-1`),
  each with its own VPC (non-overlapping CIDRs `10.10.0.0/16` / `10.20.0.0/16`),
  its own ALB, and its own **per-region ACM cert** (`regional-stack/acm.tf`,
  `region = var.region`). Confirm each cert is `ISSUED` in its own region.

### 2.2 ECR cross-region replication
- `aws ecr describe-registry --region eu-central-1` shows a replication rule with
  `eu-west-1` as a destination (from `ecr.tf`
  `aws_ecr_replication_configuration.main`, auto-on once §0.2 flip 1 lands).
- The `aegis-core` engine + gateway images resolve in **both** regions'
  registries (`aws ecr describe-images --region eu-west-1 …`). The `eu-west-1`
  cluster pulls from the replicated copy, not cross-region.

### 2.3 Route 53 latency/failover records (BLOCKED until gap B fixed)
- **Intended:** `aegis-api.prod.aws.binhsu.org` resolves to **two** records, one
  per region, with `aws-routing-policy: latency` (or `failover`) and a distinct
  `set-identifier` per region; `dig aegis-api.prod.aws.binhsu.org` from a EU
  client returns the nearest region's ALB.
- **Current reality:** external-dns writes no routing policy (gap B). This check
  **cannot pass** until the gateway Ingress (deploy repo) carries the routing
  annotations. Treat as a **blocker** for any failover claim. Verify with
  `aws route53 list-resource-record-sets --hosted-zone-id <prod-zone>` — expect
  two A/alias records with distinct `SetIdentifier`s and a `Region`/`Failover`
  routing field. If you see a single record (or two without set-identifiers),
  gap B is unaddressed.

### 2.4 DR failover drill (ADR-05) — kill one region, confirm the other serves
> Requires §2.3 (gap B) fixed, plus Route 53 health checks with
> `evaluate-target-health`. ADR-05 names a ~1–2 min failover RTO.

1. Baseline: `curl https://aegis-api.prod.aws.binhsu.org/healthz` → 200; note
   which region answers (e.g. via a response header or the resolved ALB).
2. Take down one region's gateway path (scale the gateway Rollout to 0, or use
   `scripts/dr/dr-drill.sh <region>` which sequences a full `make destroy-region`
   → `make regional-one` → reconverge and writes a timed report).
3. Within the health-check + DNS-TTL window, `curl` again → **200 from the
   surviving region**. Record the observed failover time.
4. Restore the downed region; confirm the latency record re-populates and traffic
   rebalances.

> The **cold-rebuild** RTO (ADR-05, ~20–30 min target) is a different number:
> region-from-zero via `make regional-one`, dominated by EKS control-plane
> provisioning. `scripts/dr/dr-drill.sh` measures it. Failover (2.4) is the
> smaller number for one region dying while the other is healthy.

---

## 3 — Teardown (stop billing)

PROD dual-region runs two of everything; tear down **both** regions, then the
platform tier. Gotchas carried from the joint-strike (`ws3-bring-up.md` Teardown):

1. `make destroy-region REGION=eu-west-1` then `make destroy-region
   REGION=eu-central-1` (or `infra-ops` destroy-region per region, with approval).
   Known `VPC DependencyViolation` from orphaned ALB SGs is handled by the
   two-phase sweep / background reaper in `infra-apply-account.yml`.
2. `make destroy-platform` (or `infra-ops` destroy-platform, approval-gated).
   `ECR RepositoryNotEmptyException` needs a prior apply cycle for `force_delete`.
3. After `destroy-platform`, flip `accounts.prod.bootstrap_complete` back to
   `false` (and reset `pin` to the placeholder) — else the next plan assumes a
   deleted role and reds.
4. **A failed destroy still bills** — poll teardown at ~1-minute cadence; on a
   failed region destroy, dispatch `infra-ops` destroy-region for that region
   immediately rather than waiting for the ttl-reaper/budget backstops.

---

## What is NEW vs staging — summary

| Dimension | Staging (proven 2026-06-18) | PROD adds |
|---|---|---|
| Regions | 1 (`eu-central-1`) | 2 (`eu-central-1` + `eu-west-1`), matrix apply |
| Functional matrix (§1) | proven once | **re-run per region** (cold-start proof, not re-debug) |
| Trigger | merge to main → `infra-staging.yml`, ungated | `pin` change → `infra-prod.yml`, `prod-apply-gated` approval per region |
| Version gate | warn-only | **hard-fail** before any apply |
| ECR | single region | **cross-region replication** (§2.2) |
| Route 53 | single record | latency/failover records (§2.3 — **needs gap B**) |
| DR | not exercised | **failover drill** (§2.4 — needs gap B + health checks) |
| Model bucket | one, in-region | one, **read cross-region** by `eu-west-1` (gap A) |
| Cognito | one staging pool | one PROD pool, **shared across both regions** (same issuer/JWKS, per-pool Lambda) |
