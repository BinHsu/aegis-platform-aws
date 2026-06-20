# Dual-Region Full Verification Plan — 2026-06-20

Verify the aegis-core platform + application **completely** across both the
**architectural** and **functional** axes, dual-region, in **staging then prod**.
Staging absorbs all friction; prod is a rehearsed, painless run. Every historical
root cause is structurally eliminated before prod.

Every claim below carries a reference (`file:line`, ADR §, PR#, workflow) so this
plan is self-contained and does not require re-crawling the repos.

---

## 1. Scope

**In scope today — current functional matrix, both axes, both regions, both envs:**
real-time transcription, OIDC 5-face BVA, PKCE, tenant claim, RAG retrieval path,
model populator, plus the full architectural surface (A1–A16 below).

**Explicitly deferred — on-prem-first, NOT bundled into this cloud burn**
(see memory `project_aegis_core_deferred_features_onprem_first`): RAG LLM
generation (ADR-0019 §Decision.6), speaker diarization (ADR-0012), question
detection (`is_question`, `session.cc:93`), interim segments (`is_final`,
`session.cc:92`), and mTLS gateway↔engine (no cert-manager in platform — net-new
infra). These are app/security logic verifiable on local Talos/apple-container;
verify on-prem before cloud.

**Residual root causes — all eliminated TODAY** (§5): #13 ALLOW_PARTIAL_APPLY
rename, #15 break-glass survivor import, #16 ordered-teardown hardening, #18
bootstrap per-account state.

---

## 2. Design principles

1. **Staging absorbs friction; prod is painless.** Staging re-proves the shared
   IaC path and rehearses everything prod will do, including the image-release path.
2. **Root-cause closure gate (§5).** Prod apply does not start until every
   historical root cause is structurally eliminated and verified present in `main`.
3. **Prod-only surprises are pre-handled (§9).** The only things staging cannot
   rehearse — prod image release, prod-account orphan/break-glass survivors, fresh
   account state — get a dedicated de-risk pass before prod apply.
4. **Hands-off verification (§7).** Three tiers (CI-static / aws-API / in-cluster
   Job) eliminate the `pkill`+port-forward hackery. Only SSO, Cloudflare NS, and
   approval gates remain human (§12).
5. **Cost discipline.** Any billable run is polled at ~1-min cadence; a failed
   apply/destroy leaves billable resources → destroy the partial stack before
   iterating (global rules (m)(n), memory `feedback_destroy_poll_watch_vpc_stuck`).
6. **Apply/destroy pre-authorized** (Bin 2026-06-20, memory
   `feedback_destroy_apply_preauthorized_2026_06_20`) — including GitHub
   environment approval gates via `gh api`. Cost discipline unchanged.
7. **Interactive-step look-ahead (§12).** Any human-in-the-loop step is flagged
   before the operator could step away.

---

## 3. Account & SSO reference

| Env | Account ID | Profile | Regions |
|---|---|---|---|
| staging | 251774439261 | `aegis-staging-admin` | eu-central-1 (primary), eu-west-1 |
| prod | 506221082337 | `aegis-prod-admin` | eu-central-1 (primary), eu-west-1 |
| deployment (shared ECR) | 162975888022 | `aegis-deployments-admin` | eu-central-1 source |
| management | 186052668286 | `aegis-management-admin` | — |
| shared | 345895787808 | `aegis-shared-admin` | — |

**SSO (one login covers all profiles):** `aws sso login --sso-session aegis`
(start URL `https://d-9967469f80.awsapps.com/start`, source `~/.aws/config`).

`platform_region = eu-central-1`. Cross-region ECR pull uses `var.platform_region`
for all regions (`terraform/envs/regional/main.tf:22-38`).

---

## 4. Phase 0 — cluster-free foundation (no spend)

### 4.1 Align repos
`git fetch` all four; confirm HEAD = origin/main (stale tree → phantom findings,
memory `feedback_verify_sibling_repo_current_before_audit`).

### 4.2 Fix the keystone — #141 digest extraction (root cause, not workaround)
aegis-core `release-staging-image.yml:213` and `:277` grep the oci_push log for the
digest (`grep -oE 'sha256:[a-f0-9]{64}' /tmp/{gateway,engine}-push.log`). Port the
registry-authoritative pattern from aegis-greeter `publish.yml:134-138`
(`aws ecr describe-images --image-ids imageTag=<tag> --query imageDetails[0].imageDigest`).
This is the single weakest joint of "smooth iteration" — wrong digest → prod pulls
the wrong image (the WS3 half-verify遠因). Open PR, CI green.
Confirm #144 ECR push role path: `release-staging-image.yml:165`
(`role-to-assume: ${{ env.ECR_ROLE_ARN }}` ← `vars.ECR_PUSH_ROLE_ARN`).

### 4.3 Merge prerequisite PRs (dependency order, CI green between each)
1. **ldz #274** (`terraform/environments/deployment/bootstrap/oidc-github-apply-deployment-role.tf`,
   new) + **platform #136** (`terraform/envs/platform/deployment-ecr.tf:58`) — cross-account destroy trust:
   `gh-tf-apply-deployment` now trusts BOTH `gh-tf-apply-platform` and
   `gh-tf-destroy-platform` (was apply-only → destroy got AssumeRole AccessDenied).
   ⚠️ This role is a break-glass survivor → first apply likely `EntityAlreadyExists`
   → `terraform import` (same action as root cause #15, §5). Trust list is
   staging-only by design (deployment account owned by staging CI).
2. **platform #132** + **core-deploy #29** — durable model populator (Pod Identity
   write-role + in-cluster Job; `model-populate-job.yaml:31-153`).
3. **core-deploy #28** — staging digest pin.

### 4.4 Eliminate 4 residual root causes (§5)
Author all four as cluster-free PRs, merged + CI-green before any cluster.

### 4.5 Build the hands-off 3-tier harness (§7)
Cover the gaps in §6 (architectural A1–A16 + functional F1/F6/F7/F8 are NOT in the
current harness). Eliminate `pkill`/port-forward.

### 4.6 Ground-truth the runbook command specifics
Confirm workflow names, `accounts.json` schema, environment-variable locations
against real CI before any cluster.

### 4.7 Walk the root-cause closure matrix (§5) — confirm each fix present in `main`.

---

## 5. Root-cause closure matrix

Structural fixes already in `main` (✅) and the four eliminated today (🔧).

| # | Lesson | Root cause | Structural fix | Reference |
|---|---|---|---|---|
| 1 | WS3 prod image `sha256:0000` | no prod release tag→digest | release job + describe-images pin | ADR-21 §C; §4.2 |
| 2 | #141 wrong digest | grep log not registry | `describe-images` | `release-staging-image.yml:213,277` vs greeter `publish.yml:134-138` |
| 3 | eu-west-1 ECR no replica | no cross-region path | `ecr_region = var.platform_region` (direct pull) | `regional/main.tf:22-38` |
| 4 | IAM global-name collision | region-agnostic policy names | `-${region}` suffix | `pod-identity-engine.tf:60`, `model-store.tf:88-92` |
| 5 | DRC adoption race | Crossplane auto `default` DRC | staged install + populated DRC | `crossplane.tf:53-108` |
| 6 | Crossplane orphan IRSA role | composed-IRSA lifecycle | **EKS Pod Identity** | `pod-identity-engine.tf:42-92` (trust `pods.eks.amazonaws.com`) |
| 7 | EKS access-entry race | Create ≠ authorizer effective | `time_sleep` 30s gate (#130) | regional-stack access-entry |
| 8 | IAM description em-dash | U+2014 invalid | ASCII-only (#130) | regional-stack IAM |
| 9 | Crossplane v2 install order | CRDs not established | staged install + 300s wait (#131) | `crossplane.tf:53-108` |
| 10 | version-gate try() gaps | bare remote_state hard-fail | `try()` wrap (#106) | platform version-gate |
| 11 | zone placeholders `""` | empty fallback breaks ACM/route53 | valid dummy domains | `acm.tf` |
| 12 | stale-lock killed gate | gate outside self-heal | #103 self-heal + #109 `-lock=false` | infra-apply |
| 14 | cross-account destroy fail | apply-deployment trusts apply only | trust both apply+destroy | ldz #274; §4.3 |
| 17 | AWS model bucket no populator | no bootstrap-job on AWS | durable populator Job + write-role | platform #132 / deploy #29 |
| **13** 🔧 | `ALLOW_PARTIAL_APPLY` inverted footgun | confusing inverted flag (false=reap ON) | rename/invert to intuitive semantics | `infra-apply.yml:231-240`, `infra-apply-account.yml:295-388` (PR #108) |
| **15** 🔧 | break-glass survivor `EntityAlreadyExists` | seeded roles outside TF state | enumerate + `terraform import` | `bootstrap/iam-seed.tf:242-250` (apply), `:299-307` (destroy); ldz #274 role |
| **16** 🔧 | destroy VPC-stuck (orphan ALB SG) | ALB SG not cleaned before VPC delete | harden existing ordered pre-destroy cleanup | `infra-ops.yml:236-291` (pre-destroy.sh + ALB backstop) |
| **18** 🔧 | bootstrap single local state | `bootstrap/terraform.tfstate` local | per-account terraform workspaces (Option 1) + break-glass S3 grant → `*-tfstate-*` | issue #90; `bootstrap/versions.tf:9-16`; cf. `regional/backend.tf:2-8` (already S3) |

> Note: regional + platform state are **already per-account S3** (`regional/backend.tf:2-8`,
> bucket `aegis-platform-aws-tfstate-<account_id>`, key `regional/<region>/...`).
> #18 is **bootstrap-only** — much narrower than a full state migration.

---

## 6. Complete verification matrix (both axes, dual-region)

Scope multiplier: every row runs in **{staging, prod} × {eu-central-1, eu-west-1}**
unless marked cross-region. Each cluster runs its own ArgoCD (`argocd.tf:1`).
"Harness?" = covered by current `scripts/verify/`.

### A. Architectural axis

| # | Invariant | Source | Static check | Live check | Region | Harness? |
|---|---|---|---|---|---|---|
| A1 | VPC CIDR IPAM-allocated /16 (not hardcoded) | `regional-stack/vpc-ipam.tf:19-67` | `terraform plan` shows allocation resource | `ec2 get-ipam-pool-allocations`; two regions non-overlap | ×2 | N |
| A2 | Workload identity = **Pod Identity, not IRSA** | `pod-identity-engine.tf:42-92` | plan shows assoc, role path `/`, no OIDC trust | `eks list-pod-identity-associations`; SA has no role-arn annotation | ×2 | partial |
| A3 | Pod Identity → S3 model fetch | `model-store.tf:73-97` | read-only policy (no write) | model-fetch init Completed; engine Ready | ×2 (in-region bucket) | Y (implied) |
| A4 | **Cross-region ECR direct pull** | `regional/main.tf:22-38` | plan: `ecrRegion`=platform_region | eu-west-1 pod image host = platform-region ECR, no ImagePullBackOff | cross-region | N |
| A5 | Crossplane v2 core + provider-aws-s3 Healthy | `crossplane.tf:53-108` | `crossplane render`+`beta validate` | `kubectl get providers` HEALTHY | ×2 | N |
| A6 | **XBucket reconcile + clean delete (zero orphan)** | XRD `xrd-bucket.yaml:40`, `composition-bucket.yaml` | `crossplane render examples/xbucket.yaml` | apply→bucket exists→delete→bucket gone→zero orphan IAM (the v1 regression test) | ×2 | N (headline gap) |
| A7 | ArgoCD Apps Synced/Healthy | `argocd.tf:169-359` | `kustomize build overlays/*` | `kubectl get applications` SYNCED+HEALTHY | ×2 | N |
| A8 | Canary Rollout actually canaries | gateway `rollout.yaml:48-58`, engine `:46-55` | `kustomize build` → `kind: Rollout` | `kubectl argo rollouts get` paused at weight 50 (BVA 0/50/100). Note: ReplicaSet split, no ALB trafficRouting (`rollout.yaml:31-36`) | ×2 | N |
| A9 | Node autoscaling (managed SPOT node group; **no Karpenter**) | `eks.tf:51-61` | plan shows SPOT MNG | `kubectl get nodes` Ready ≥ min; scale past capacity adds node | ×2 | N |
| A10 | ALB/Ingress reachable + ACM ISSUED | `aws-binding/gateway-ingress.yaml:13-27`, `acm.tf:22-64` | `kustomize build` renders ALB annotations | `acm describe-certificate` ISSUED both regions; `curl https://…/healthz` 200 w/ valid TLS | ×2 (region-bound cert) | partial |
| A11 | **Route53 dual-region latency + failover** | `gateway-ingress.yaml:51-53`, `overlays/prod/kustomization.yaml:51-66`, `external-dns.tf:11-70` | `kustomize build overlays/prod` shows set-identifier/aws-region; NO `aws-routing-policy` | `route53 list-resource-record-sets`: 2 records, distinct SetIdentifier+Region, alias EvaluateTargetHealth; `dig`/`test-dns-answer`; disable a health-check → fails over | cross-region | N (**highest-priority unproven**) |
| A12 | Kyverno ClusterPolicies enforce | `kyverno.tf:28-207`, `charts/aegis-policies/` | `kyverno test` w/ violating fixtures | foreign-ns IAM trust REJECTED; default-deny netpol generated. (require-digest = Audit, `kyverno.tf:191-199` — verify, don't assume Enforce) | ×2 | N |
| A13 | SCP / IAM boundaries deny | ldz `scps/main.tf:36,78,116,197` | `terraform validate`; OPA on policy JSON | `iam create-user` from member → AccessDenied | org-global | N |
| A14 | Observability: Alloy → Grafana Cloud Mimir | `alloy.tf:34-148`, `alloy-config.river.tpl:155,286-287` | render River, assert `remote_write.mimir` | query Mimir for `up{cluster="aegis-platform-<region>"}` | ×2 (EMF path N/A in this IaC) | N |
| A15 | Multi-tenancy: Qdrant collection-prefix isolation | proto `aegis.proto:547-562`, `gateway_service.go:561-575` | unit test on prefix filter | tenant A ListCorpora → only `aegis_A_*`; gateway overrides spoofed tenant_id | ×2 | N |
| A16 | Teardown: zero billable + zero orphan IAM | ordered `kyverno.tf:209-228`; roles path `/` region-suffixed; buckets `force_destroy` | `plan -destroy` completeness; no `/aegis-workload/` role | post-destroy: `iam list-roles\|grep aegis` empty; no cluster/VPC/bucket; $0 | ×2 + xacct | N |

### B. Functional axis

| # | Behavior | Verify | Region | Harness? |
|---|---|---|---|---|
| F1 | Gateway `/healthz` 200 | `curl https://…/healthz` (public) or in-cluster `curl svc:8080/healthz` | ×2 | partial |
| F2 | Native gRPC StreamTranscribe → real transcript | harness TEST 1 (`ws4-app-functional-e2e.sh:94-115`) | ×2 | **Y** |
| F3 | OIDC 5-face BVA (4 neg → status 16; valid → ≠16) | harness TEST 2/3 (`:122-179`) | ×2 | **Y** |
| F4 | PKCE Hosted-UI → id_token | `cognito_pkce.py` (`:145-184`) | shared Cognito | **Y** |
| F5 | `custom:tenant_id` claim present | TEST 3 (`:167-172`) | shared | **Y** |
| F6 | RAG retrieval returns hint/citation | bind session to seeded corpus, assert RagCitation (`aegis.proto:359-367`). Staging no-Qdrant → status 14 = reached handler | ×2 | N (harness sends empty rag_id `:89`) |
| F7 | Model populator Job Complete | `kubectl wait job/aegis-core-model-populate`; `s3 ls` non-empty | ×2 | N |
| F8 | Tenant isolation E2E (A≠B) | two users diff tenant_id, ListCorpora no overlap | ×2 | N |

**Findings carried from the matrix audit:**
- A4: active mechanism is **direct cross-region pull**, not replication
  (`aws_ecr_replication_configuration` at `ecr.tf:80` is for the greeter repo;
  per-region aegis-core replicas are a future DR item). Test direct pull.
- A9: **no Karpenter** — managed SPOT node group only.
- A14: **no enclave/CloudWatch-EMF** resource in this IaC → mark N/A.
- **prod gateway digest ≠ staging** (partial-promotion residue) → reconcile before
  any prod functional run (ties to §4.2 / §9).

---

## 7. Hands-off verification design (eliminates pkill/port-forward)

Current harness covers only F2–F5 via laptop port-forwards with `pkill` cleanup
(`ws4-app-functional-e2e.sh:75` scattergun pkill; `:97-120` background PFs + fixed
`sleep`). Replace with three tiers:

- **Tier 0 — CI static** (no cluster, no creds, every PR): `terraform validate`/
  `test`, `crossplane render`/`beta validate`, `kyverno test`, `kustomize build`,
  Alloy `fmt`. Covers A1/A2/A5/A6(render)/A7/A11(annotations)/A12/A13/A16(plan).
- **Tier 1 — aws-API from creds** (no cluster networking): `ecr describe-images`,
  `route53 list-resource-record-sets` + `test-dns-answer`, `eks
  list-pod-identity-associations`, `acm describe-certificate`, `s3api head-bucket`,
  `iam simulate-principal-policy`. Covers A3/A4/A6(bucket)/A10(cert)/A11(records+
  failover)/A13(simulate)/F1(public healthz). Auto-derive all config from
  `terraform output` (cognito_issuer, cognito_app_client_id, cognito_hosted_ui_domain).
- **Tier 2 — in-cluster verifier Job** (`scripts/verify/k8s/verifier-job.yaml` +
  bundled image with grpcurl/python/proto/PCM): runs F2/F3/F6/F7/F8 from inside
  the cluster against `svc/aegis-core-{engine:50051,gateway:8080}` — **no
  port-forward, no pkill, no sleep**. `kubectl wait --for=condition=complete`,
  fetch logs, delete Job. Credentials via Job Pod Identity.

**Route53 (A11) — the highest-priority unproven claim, fully non-interactive:**
declared via external-dns annotations, NOT TF route53 records (grep
`latency_routing`/`set_identifier` in `terraform/` = zero). Verify with
`route53 list-resource-record-sets` (assert 2 records, `Region` set, distinct
`SetIdentifier`) + `route53 update-health-check --disabled` → `test-dns-answer` →
re-enable (reversible failover sim). If records lack `Region`, the check fails
correctly rather than falsely passing.

---

## 8. Phase 1 — Staging cycle (friction allowed)

1. 🙋 **BIN-PRESENT:** SSO + Cloudflare NS delegation for staging zone (§12).
2. Bring up dual-region staging (251774439261). Poll 1-min.
3. **Rehearse the prod image path on staging's cluster:** cut release → push →
   `describe-images` both regions → confirm cross-region pullable. De-risks prod's
   #1 historical failure before prod.
4. Run the **full** matrix: Tier 0 (already in CI) + Tier 1 + Tier 2 → A1–A16 +
   F1–F8, both regions.
5. Any failure → root-cause fix in IaC → re-apply → re-verify. Log each.
6. **Rehearse teardown:** destroy-region ×2 + destroy-platform (proves ldz #274/
   #136 and #16 ordered cleanup). Watch for VPC-stuck (orphan ALB SG
   DependencyViolation, memory `feedback_destroy_poll_watch_vpc_stuck`).
7. Flip `staging.bootstrap_complete=false` after teardown.

Gate: all A1–A16 + F1–F8 PASS both regions; teardown clean to baseline.

---

## 9. Phase 1.5 — Root-cause closure gate (the prod-painless guarantee)

Prod apply does NOT start until ALL true:
- [ ] §5 closure matrix all-green (incl. the 4 residuals merged).
- [ ] Prod image in **both** prod-region ECRs (`describe-images`); prod overlay
      digests are real (reconcile the prod-gateway-digest-mismatch finding §6).
- [ ] Prod orphan Crossplane role `aegis-core-engine` (`/aegis-workload/`) cleared
      via break-glass (🙋 may need MFA, §12).
- [ ] **Prod IAM pre-scan**: enumerate roles TF will create that already exist
      (break-glass survivors incl. `gh-tf-apply-deployment`) → `terraform import`
      commands prepared (root cause #15).
- [ ] `ALLOW_PARTIAL_APPLY` set so a failure KEEPS the prod stack (fix-in-place,
      not auto-reap) — per the renamed/intuitive flag from #13.
- [ ] Prod `accounts.json` pin = real release tag; `enabled_regions` = both.

---

## 10. Phase 2 — Prod cycle (painless)

1. 🙋 **BIN-PRESENT:** SSO + Cloudflare NS for prod zone (§12).
2. Apply dual-region prod (506221082337). Poll 1-min. Expect green.
3. Any surprise = a NEW root cause (not a repeat) → fix in-place / import
   (partial-apply keeps the stack), log it.
4. Run the **full** matrix A1–A16 + F1–F8, both regions (Tier 1 + Tier 2).
5. **Ordered teardown to $0**: delete ArgoCD/Services → ALB+SG reconciled away →
   destroy-region ×2 → destroy-platform. Confirm A16 (zero orphan, $0).

---

## 11. Phase 3 — Close-out

- Close teardown issues #134/#111/#110/#102 (resolved by clean $0 teardown + #274).
- Tag releases (platform / core / core-deploy) to the verified milestone.
- Update memory: new "prod full verification" entry + amend WS4 burn entry.
- File follow-ups if not fully closed: #18 full migration beyond bootstrap,
  ALLOW_PARTIAL_APPLY rename rollout confirmation.

---

## 12. Interactive (BIN-PRESENT) gates — look-ahead

Flagged before the operator could step away (memory
`feedback_remind_before_interactive_sso_ns_steps`). Apply/destroy + GitHub
approval are pre-authorized (auto via `gh api`).

| Gate | When | Why human |
|---|---|---|
| `aws sso login --sso-session aegis` | start of each session | interactive browser auth |
| Cloudflare NS delegation (staging zone) | before Phase 1 apply | external system, no TF provider; blocks ACM DNS-01 |
| Cloudflare NS delegation (prod zone) | before Phase 2 apply | same |
| break-glass assume (clear prod orphan, import survivors) | Phase 1.5 | may require MFA |

Front-load SSO + NS **before** opening billable resources so an apply never hangs
waiting on DNS.

---

## 13. Reference index

- Workflows: `infra-apply.yml`, `infra-apply-account.yml`, `infra-ops.yml`
  (platform); `release-staging-image.yml` (core); `publish.yml` (greeter).
- Terraform: `terraform/modules/regional-stack/*` (vpc-ipam, pod-identity-engine,
  model-store, crossplane, eks, acm, external-dns, alloy, kyverno, argocd);
  `terraform/envs/{bootstrap,platform,regional}`; ldz `terraform/environments/*`.
- Deploy: `k8s/base/aegis-core-{gateway,engine}/rollout.yaml`,
  `k8s/components/aws-binding/*`, `k8s/overlays/{staging,prod}/*`.
- App: `gateway_go/`, `engine_cpp/`, `proto/aegis.proto`.
- ADRs: 09 (XRD), 10 (build-once-promote-by-digest), 21 (prod go-live follow-ups),
  22 (Crossplane v2 boundary); core ADR-0012/0019/0020/0021.
- PRs: ldz #274, platform #136/#132, core-deploy #29/#28, core #141/#144.
- Issues: platform #90/#134/#111/#110/#102.
- Memory: `project_ws4_dualregion_staging_burn_2026_06_19`,
  `project_ws3_prod_golive`, `project_aegis_core_deferred_features_onprem_first`,
  `feedback_destroy_apply_preauthorized_2026_06_20`,
  `feedback_remind_before_interactive_sso_ns_steps`,
  `feedback_destroy_poll_watch_vpc_stuck`.
