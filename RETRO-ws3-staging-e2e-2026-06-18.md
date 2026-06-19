# Retrospective — WS3 Staging End-to-End Bring-Up (2026-06-18)

**Status:** working retrospective (committed 2026-06-19 as a durable record). | **Author context:** aegis-platform WS3.
**Scope:** the full-AWS staging end-to-end (e2e) attempt of `aegis-core` (gateway + engine + frontend), preceded by WS0 (greeter on local Talos), WS2 (full on-prem on Talos), and the first cloud bring-ups earlier on 2026-06-18.

---

## 中文摘要 (Chinese Executive Summary)

我們依序走過 **greeter → 本機 on-prem (Talos) → 雲端 staging → 今天的正式 staging e2e**,但今天仍踩到一連串地雷。核心結論不是「前面的階段沒做好」,而是**每個階段驗的是一條不同且更窄的整合縫 (integration seam)**:WS0 驗 injection contract、WS2 驗 SPIRE/MinIO 替身、cloud bring-up 驗 apply 能不能綠。**唯獨「全 AWS e2e」這條縫——跨帳號 ECR、Crossplane/ACK 走 IRSA、OIDC token type、PSA × operator pod、真實外部 chart 依賴——在今天之前從來沒被執行過**,所以它累積的缺陷一次爆出來。

把今天的問題歸成 7 類:(1) 只有在全 e2e 才看得到的整合縫缺陷;(2) 做一半的遷移 / 雙真實來源 (dual source of truth);(3) 跨 repo 設定漂移;(4) 外部依賴的腐化與瞬斷;(5) 平台能力 vs workload 需求不對齊;(6) admission / policy 交互作用;(7) 只有 runtime 才看得到、單元/component 測試抓不到的設定。其中**真正全新縫面**的(跨帳號 ECR、Crossplane PSA、XRD schema、IRSA 鏈)是「可被預防但合理」的;而**OIDC token type 寫錯、frontend 寫死退役的 Cognito pool**這類屬於**可避免的回歸 (avoidable regression)**——前面階段已經碰過 auth,本不該再錯。

好消息:**業界對這幾類問題大多已有成熟答案**——ephemeral/preview 環境 (vcluster)、`crossplane render`/`beta validate`、Kyverno CLI `test`、OCI registry mirror + digest pin、Argo Rollouts analysis 自動 rollback、SLSA digest pinning。**唯一還算「真的難」的是跨 repo 設定契約 (cross-repo config contract)**——Pact 之類只解 API shape,不解「兩個 repo 對某個 account-ID / hostname / token-type 各說各話」。那一塊得靠**單一真實來源 + apply-time 驗證**自己補。

**最該先做的三件事:** (1) 把跨切面設定 (registry account、hostnames、Cognito、token-type) 收斂成單一真實來源 + CI 驗證;(2) 在付費 bring-up 前,把 `crossplane render` + `kyverno test` + kustomize/helm render 做成 PR gate;(3) chart 依賴一律 vendoring/digest-pin + mirror,別再從 GitHub Releases 直接拉。

---

## 1. The Core Question

Bin's framing, answered directly:

> *"We went greeter → staging on-prem → staging on-cloud → today's formal staging e2e. Why are we STILL hitting so many pitfalls? What design/process improvements would prevent this? Does industry already have complete solutions?"*

**Short answer.** The prior phases were real and valuable, but each one exercised a *different and narrower* integration surface. The pitfalls hit today live almost entirely on the **full-AWS-e2e seam** — cross-account ECR, IRSA through the Crossplane/ACK chain, OIDC token-type, Pod Security Admission interacting with operator pods, and real external chart dependencies. That seam had **never been executed before today**, so its accumulated defects all surfaced at once. A subset (OIDC token-type, a hardcoded retired Cognito pool) were avoidable regressions; most were genuinely new surface. Industry has mature answers for most of these classes; the one that stays genuinely hard is cross-repo configuration contracts.

The rest of this document: **(2)** the incident inventory, **(3)** problem classes, **(4)** the "why so many" analysis, **(5)** design improvements, **(6)** process improvements, **(7)** industry-standard solutions with citations, **(8)** prioritized next actions.

---

## 2. Today's Incident Inventory

A pre-apply multi-agent adversarial audit (24 agents, 6 finders × 3 repos) ran *before* spending, caught several real e2e-breakers statically, then the live bring-ups surfaced the runtime-only ones. Two scary "criticals" from the audit were red herrings (the committed `registries.auto.tfvars.json` is greeter-only, but CI materializes the real file from a GH var; and the Route53 delegation was already live). The confirmed incidents:

| # | Incident | Where caught | Root cause | Fix |
|---|----------|--------------|-----------|-----|
| 1 | **Cross-account ECR mismatch** — gateway `ImagePullBackOff` | Live (bring-up #1) | `release-staging-image.yml` built its ECR role ARN from `vars.AWS_ACCOUNT_ID` (= staging 251774…) and pushed to a per-account `aegis-core` repo; the deploy pulls from the **deployment account 162975888022**. A half-completed ADR-10-ph2 "shared ECR in deployment account" migration left per-account repos *and* CI still targeting them. | Repoint CI to deployment-account `aegis-core-ci-push` role; **remove** the per-account ECR repos so a future mispush fails loud. (aegis-core #150 + aegis-platform #98) |
| 2 | **Engine IRSA never provisioned** (deepest) — `sts:AssumeRoleWithWebIdentity` denied; IAM role `aegis-core-engine` `NoSuchEntity` | Live (bring-up #1→#2) | The `WorkloadIdentity → Crossplane composite → ACK Role → IAM Role` chain broke at **two** points: **(a)** the Crossplane `function-patch-and-transform` runtime pod was rejected by **PSA `restricted`** on `crossplane-system` because the `default` `DeploymentRuntimeConfig` was empty (`spec:{}`) → no `securityContext` → function `HEALTHY=False` → composition can't render; **(b)** after fixing (a), a **Crossplane↔XRD schema mismatch**: a cluster-scoped XR composing a namespaced ACK `Role` → `spec.resourceRefs[0].namespace: field not declared in schema`. | (a) live-patched the DRC → function Healthy; must IaC it into `crossplane.tf`. (b) align Crossplane version with the XRD / regen the XRD CRD in `charts/aegis-xrds`. Both are code fixes, not time. |
| 3 | **Frontend OIDC** — 401 on every call; PKCE redirect mismatch | Static (audit) | The SPA sent the Cognito **access** token; the gateway validates `aud=clientId` + `custom:tenant_id`, which are **ID-token** claims → 401. Separately, `release-staging-frontend.yml` hardcoded the **retired ldz** Cognito pool/client/redirect-uri (`eu-central-1_0gdyxKxOB`, `aegis-app.staging.binhsu.org`). | `auth.ts:81` → `id_token`; convert 4 `VITE_AEGIS_COGNITO_*` to GH vars set post-apply from `cognito.tf` outputs. (aegis-core #149) |
| 4 | **`qdrant-credentials` secretKeyRef not `optional:true`** — engine `CreateContainerConfigError` | Static (audit) | The documented app-level soft-fail was *unreachable*: kubelet blocks the pod before the app runs (the ldz `ExternalSecret` that would mint the Secret never landed). | `optional: true` ×4 on rollout + seed-job. (aegis-core-deploy #19) |
| 5 | **Empty model store** | Known-pending | The S3 model bucket is a documented "Phase-4c bootstrap placeholder"; nothing populates it, and the engine init hard-gates on a non-empty `/models`. | Operator manually seeded `whisper-tiny-en` (SHA/size-verified vs manifest, account-scoped bucket → survives teardown). Real CI populator still owed. |
| 6 | **Transient external dependency failure → self-reap destroyed a healthy cluster** | Live (bring-up #3) | A momentary chart-download blip — `argocd-apps-2.0.2.tgz` 404 from **GitHub Releases** + crossplane repo 403, *same instant* (both fine minutes later) — failed the apply. The workflow's auto "self-reap" then destroyed the whole healthy cluster → forced a ~20-min rebuild. | Disabled self-reap during attended iteration (`ALLOW_PARTIAL_APPLY=true`); must re-enable for unattended. Future: retry-before-reap. |
| 7 | **Process: tear-down-first over-applied** | Meta | Bring-up #2's Crossplane↔XRD mismatch was mis-classified as "not safe to live-patch → tear down" — but `kubectl patch` of the XR CRD schema would have unblocked the composite live. The teardown forced a fresh billable bring-up. | New rule: small/live-fixable bug → fix on the running cluster + verify, *then* IaC as follow-up; teardown is the last step, not a reflex. |

Each `aegis-core`-tier IaC claim above was verified against the repo: `crossplane.tf` carries a comment "PSA-restricted compliance (live-diagnosed 2026-06-12)" and applies `securityContext` to Crossplane's *own* pods (`securityContextCrossplane`/`securityContextRBACManager`) but not to the function-pod DRC — exactly the gap in incident #2(a). The `xrd-workloadidentity.yaml` / `composition-workloadidentity.yaml` / `ecr.tf` / `iam-seed.tf` files all exist as the log describes.

> **中文小結:** 今天 7 個事件中,2 個 critical(跨帳號 ECR、IRSA 鏈斷兩處)是付費上線後才現形的 live-only;3 個被 pre-apply audit 靜態抓到(OIDC token、Cognito pool 寫死、qdrant secret 非 optional);1 個是已知待補的 model populator;1 個是流程教訓(瞬斷 → self-reap 把健康 cluster 拆了 + tear-down-first 用過頭)。

---

## 2A. Preparations — Planned, Intended, Effective, Missing

A fair retrospective must weigh what we *did* prepare against what we *should* have.

### What we prepared (and whether it worked)

| Preparation | Intended purpose | Did it work? |
|---|---|---|
| **Pre-apply multi-agent audit** (24 agents, 6 dimensions, adversarial-verify + completeness-critic) | Catch e2e-breakers *statically*, before spending on a billable apply | **Yes, materially** — caught 4 real breakers (qdrant `optional:true`, SPA `id_token`, frontend Cognito hardcode, redundant ServiceMonitor) and cleared 2 false criticals (`REGISTRIES_JSON` was actually correct; NS delegation was live). But **static-only** — see gaps below. |
| **Model pre-staging** (download + SHA-verify whisper-tiny *before* the bucket existed) | Have the model ready so the engine could serve same-run | **Partial** — uploaded + verified, but the engine never reached it (IRSA blocked). The prep was sound; the dependency it fed wasn't there. |
| **Integration branches** (audit the *post-merge* state, not half-branches) | Audit what would actually ship | **Yes** — the audit reviewed the true merged state. |
| **Escalation contract + autonomy rules** | Bounded autonomous operation (1-min monitor, destroy-on-fail) | **Mostly** — needed two live corrections: tear-down-first → fix-live, and IaC-discipline (capture every live fix back into IaC). |

### What we under-prepared (the gaps that actually bit)

Every *runtime* blocker slipped past our prep because **all our prep was static or single-component**:

1. **No runtime/integration rehearsal.** The audit read code; it could not see *live state* — the empty ECR repo, the IRSA chain, PSA-vs-function-pod, the transient chart 404. **A cheap ephemeral full-stack env (vcluster / kind-in-CI) exercising the e2e seam before the billable apply would have surfaced most of these.** (Class A.)
2. **No Crossplane composition testing.** `crossplane render` + `beta validate` would have flagged MR/schema problems offline. (Class B.)
3. **No PSA shift-left.** `kyverno apply` against the PSS-restricted library would have caught the function-pod securityContext gap — the PSA block *and* the `runAsUser` follow-on — with no cluster. (Class F.)
4. **No cross-repo config contract check.** The ECR account mismatch and the stale Cognito redirect/pool were two-repos-disagree defects; a CI assertion (single-source-of-truth + grep/CUE) would have caught them. (Class C — the genuinely-hard one.)
5. **No dependency mirror/cache.** The transient `argocd-apps` 404 / crossplane 403 would be a non-event behind an OCI mirror + digest pin. (Class D.)
6. **No "is the image actually in the registry the deploy pulls from" pre-flight.** A 3-line `aws ecr describe-images` against the deploy's `ecr_account_id` would have caught the headline ECR mismatch before apply.

**The throughline:** we prepared to validate *code* and *individual components*, but the failures were all at the *integration seam* and in *live/runtime state* — exactly what our preparations never exercised. The remedy is a cheap runtime-rehearsal layer (Sections 5–7), not more static review.

### 中文小結
事前做了:**pre-apply 多-agent 審查**(抓到 4 個真 breaker、清掉 2 個假警報,但只是**靜態**)、**model 預先上傳**(有傳但 engine 沒用到)、**integration 分支審查**、**autonomy 契約**(中途修正兩次)。少做、也正好出事的:**沒有 runtime/整合預演**(空 ECR、IRSA、PSA×function、transient chart 都是 live-state,靜態看不到)、**沒有 Crossplane composition 測試**、**沒有 PSA shift-left**、**沒有跨-repo config 契約檢查**、**沒有 chart mirror/cache**、**沒有「image 是否真的在 deploy 拉取的 registry」的 pre-flight**。主軸:我們驗的是「程式碼/單一元件」,出事的全在「整合接縫/執行期狀態」—— 解法是加一層便宜的 runtime 預演,不是更多靜態審查。

## 3. Problem Classes

Collapsing the inventory into recurring classes (this is the useful unit for prevention):

| Class | Definition | Today's members |
|-------|-----------|-----------------|
| **A. Integration-seam defects visible only at full e2e** | The component works in isolation and in narrower phases; the defect lives where two real subsystems meet for the first time. | #1 (CI↔deploy ECR account), #2 (SA→Crossplane→ACK→IAM), #3 (SPA↔gateway token) |
| **B. Half-completed migration / dual source of truth** | A migration landed partially; old and new both exist; CI/config still point at the deprecated one. | #1 (per-account ECR repos survived ADR-10-ph2) |
| **C. Cross-repo config drift** | Two repos disagree on a cross-cutting fact (account ID, hostname, Cognito pool, token type) with nothing reconciling them. | #1 (account), #3 (Cognito pool + redirect-uri + token type) |
| **D. External-dependency rot & transience** | A pinned-by-tag dependency hosted on a flaky endpoint 404s/403s, or its source moved. | #6 (chart 404/403 from GitHub Releases) |
| **E. Platform-capability vs workload-requirement mismatch** | A workload's manifests assume a cluster capability the platform never wired. | The 3-gap sync blocker (argo-rollouts absent, AppProject too narrow, redundant ServiceMonitor) — fixed pre-audit; same class as #2 (PSA capability) |
| **F. Admission / policy interactions** | A policy (PSA, Kyverno) blocks a pod the system itself needs — often an operator/function pod, not the workload. | #2(a) PSA blocks the Crossplane function pod; the AppProject ClusterPolicy whitelist |
| **G. Runtime-only config** | The defect is invisible to unit/component/render tests because it only manifests when kubelet/IAM/the live API evaluates it. | #4 (kubelet blocks before app soft-fail), #5 (empty bucket), #2 (live IAM denial), #1 (live ECR 404) |

A single incident often spans classes — e.g. #1 is A+B+C, #2 is A+F+G. That overlap is itself the signal: **these are the seams where multiple weaknesses compound.**

> **中文小結:** 7 類:A 全 e2e 才現形的整合縫、B 做一半的遷移/雙真實來源、C 跨 repo 漂移、D 外部依賴腐化/瞬斷、E 平台能力 vs workload 需求、F admission/policy 互卡、G 只有 runtime 才看得到。一個事件常跨多類,正好標出「多個弱點疊加」的縫。

---

## 4. Why So Many — Despite Prior Phases

The central insight: **each prior phase validated a real but narrower integration surface. None of them exercised the full-AWS-e2e seam, so its defects could not surface until today.**

| Phase | What it actually exercised | What it did NOT exercise (deferred to WS3) |
|-------|---------------------------|-------------------------------------------|
| **WS0 — greeter on local Talos** | Provider-neutral injection contract (image/region splice), Gateway API path, Talos substrate. Greeter = plain Deployments. | No ECR (in-cluster registry:2), no IRSA, no Cognito, no Crossplane, no Rollouts, no ACM. |
| **WS2 — aegis-core full on-prem (Talos)** | The deepest *substitute* axes: arm64 engine build → GHCR; S3→**MinIO**; IRSA→**SPIRE/SPIFFE**→MinIO-STS. Live-proven L1→L5. | The substitutes deliberately *replace* the AWS seams: SPIRE ≠ ACK/Crossplane IAM; MinIO-STS ≠ real `AssumeRoleWithWebIdentity`; Dex/nginx descoped; no cross-account ECR; no PSA×Crossplane-function; no real Cognito token-type. |
| **Cloud bring-ups (earlier 2026-06-18)** | Can the platform `apply` green? EKS/ACM/Cognito/ArgoCD up. Then: can `aegis-core` *sync*? (the 3-gap blocker). | Sync ≠ run. Pods pulling real images, assuming real IAM roles, serving real OIDC — all downstream of sync, none reached until the gaps were fixed. |
| **Today — formal staging e2e** | First execution of the **full AWS seam**: cross-account image pull, Crossplane→ACK→IAM, OIDC token validation against real Cognito, PSA against operator pods, real external charts. | — (this is the seam; that's why the defects landed here). |

**Genuinely new surface (predictable-in-hindsight, but reasonable to miss):**
- #1 cross-account ECR — only a real two-account apply with a real digest-pinned deploy can 404 on the wrong registry.
- #2 IRSA via Crossplane/ACK — WS2 proved the *equivalent* chain with SPIRE→MinIO-STS; the AWS chain (PSA→function-pod→composite→ACK→IAM) is a different mechanism that had never run.
- #2(a) PSA × Crossplane function pod, #2(b) XRD schema mismatch — both require the actual Crossplane runtime + the actual XRD CRD installed together.
- #6 transient chart 404/403 — non-deterministic; can't be "designed away," only made resilient.

**Avoidable regressions (we'd touched the surface before and still erred):**
- #3 OIDC token-type and the **hardcoded retired Cognito pool** — auth was already built and "neutral both ends" in WS1; a stale hardcoded pool/redirect and the access-vs-id-token confusion are config/wiring errors, not new-surface discovery.
- #1's *dual source of truth* — the ADR-10-ph2 migration was a known design; leaving the per-account repos *and* CI pointed at them is incomplete-migration hygiene, not novel.

**The honest scorecard:** ~60% of today's pain was genuinely new e2e seam that no prior phase could have surfaced; ~40% was avoidable config drift / incomplete-migration debt that a contract or single-source-of-truth check would have caught cheaply. The new-surface portion is *expected* the first time you run a seam — the lesson is to **run the seam cheaply before running it expensively**, not to feel bad about discovering it.

> **中文小結:** WS0 驗 injection、WS2 驗 SPIRE/MinIO 替身、cloud bring-up 驗 apply/sync——沒有一個碰到「全 AWS e2e」這條縫。約 60% 是合理的全新縫面(跨帳號 ECR、Crossplane PSA/XRD、IRSA 鏈),只有真的跑這條縫才看得到;約 40% 是可避免的回歸(OIDC token-type、寫死退役 Cognito pool、做一半的 ECR 遷移)。教訓不是「前面沒做好」,而是**該在付費前先用便宜的方式把這條縫跑一遍**。

---

## 5. Design Improvements

1. **Single source of truth for cross-cutting config + apply-time validation.** Registry account ID, hostnames, Cognito pool/client/redirect, OIDC token-type, ACM ARNs — today these live duplicated across `aegis-core`, `aegis-core-deploy`, GH vars, and Terraform. One authoritative source (Terraform outputs / one GH-var contract), and a CI check that **fails loud** if a consumer disagrees. The frontend already does the right version of this: its SPA host references `local.cognito_app_host` so it *can't* drift from the Cognito callback — generalize that pattern.

2. **Make "platform capability provided" vs "workload capability required" an explicit, checkable contract.** The 3-gap sync blocker and the PSA×function gap are the same disease: a workload assumes a capability (Rollouts CRD, a ClusterPolicy whitelist entry, a PSA-compliant function DRC) that the platform never wired. Encode platform-provided capabilities as a manifest; lint each workload against it before enrollment. (See §7-E.)

3. **Fail loud over fail silent.** Incident #1's fix — *remove* the per-account ECR repo, not just repoint CI — is the model: with no repo, a mispush fails red instead of silently succeeding into the wrong account. Audit other "silently-wrong-target" surfaces (an empty bucket that hard-gates is good; a wrong-account push that succeeds is bad).

4. **Idempotent + retry-tolerant apply.** A transient chart 404 should retry-in-place, not reap a healthy cluster (#6). Add bounded retry to the apply step *before* the reap fires, so genuine failures still reap but blips self-heal.

5. **Cheap ephemeral full-stack environment that exercises the e2e seam before billable bring-up.** The biggest structural lever. A vcluster (or kind-in-CI) running real Crossplane + ACK + Kyverno + ArgoCD + the actual manifests would have surfaced #2(a)(b) and the 3-gap blocker *statically/cheaply* — before paying for EKS. (See §7-A.)

6. **Runtime-config injection, not build-time hardcoding** (already underway via `/config.json` refactor) — kills the class of "frontend baked the wrong Cognito pool at build time" (#3).

> **中文小結:** 五個設計槓桿:(1) 跨切面設定單一真實來源 + apply-time 驗證;(2) 平台能力 vs workload 需求做成可檢查的契約;(3) fail-loud(刪掉 repo 比 repoint 更安全);(4) apply 可重試,別讓瞬斷觸發 reap;(5) 便宜的 ephemeral 全棧環境,在付費前先跑 e2e 縫。

---

## 6. Process Improvements

1. **Pre-apply adversarial audit as a standing gate.** Today's 24-agent audit caught 3 real e2e-breakers (#3 ×2, #4) *before* spending — that is exactly the right shape and should be a permanent pre-billable-apply step, not an ad-hoc one. Refine it: feed it the platform-capability manifest and the cross-repo config contract so it can flag drift (classes C/E) more reliably than free-form search did.

2. **Live-fix-then-IaC over teardown-first.** Codified after incident #7: for a small bug fixable live on a running cluster (even a `kubectl patch` of a CRD schema or a DRC), fix it live, verify the flow unblocks, capture the proper IaC fix as a follow-up PR — do **not** tear down + rebuild (~20 min apply + ~15 min teardown + EKS bill ≫ a few-minute live patch). Teardown is the last step after e2e verification, or only when the fix genuinely needs a human architectural decision.

3. **Attended vs unattended guardrail modes.** The self-reap (#6) is correct for *unattended* runs (a failed apply must not bleak billable resources) but counterproductive during *attended* iteration (a transient blip shouldn't cost a rebuild). Make the mode explicit (`ALLOW_PARTIAL_APPLY`), and **re-enable the reap the moment iteration ends** — an attended-mode flag left on unattended is a cost incident waiting to happen.

4. **Dependency pinning + caching/mirroring policy.** Stop pulling charts directly from GitHub Releases at apply time. Vendor/mirror them into an OCI registry under our control and pin by digest (see §7-D/G). This removes the entire #6 transience class.

5. **1-minute-cadence cost monitoring on every billable mutate**, with VPC-teardown-stall detection (orphan ALB-controller SG → `DependencyViolation`) — already a standing rule; keep it.

> **中文小結:** 流程五招:(1) pre-apply 對抗式 audit 變常設 gate;(2) live-fix-then-IaC,小 bug 直接在跑著的 cluster 修,別 tear-down-first;(3) attended/unattended 兩種 guardrail 模式,iteration 結束立刻把 reap 開回來;(4) chart 依賴 mirror + digest pin,別再從 GitHub Releases 拉;(5) 1 分鐘 cadence 成本監控 + VPC 卡死偵測。

---

## 7. Industry-Standard Solutions (researched, cited)

For each class, the established pattern/tool and an honest maturity verdict.

### A — Integration-seam defects: ephemeral / preview environments  → **MATURE**
The industry answer is **ephemeral per-PR environments** that stand up the *real* stack cheaply before any billable cloud bring-up. The leading building block is **vcluster** (lightweight virtual Kubernetes clusters inside a host cluster — spin up in seconds vs minutes for a real cloud cluster), commonly composed with **Crossplane + Argo CD** so a PR provisions a dedicated cluster, deploys the current commit, and auto-cleans on close. SaaS equivalents: **Qovery, Bunnyshell, Release, Uffizzi, Shipyard, Signadot**. For our case, a kind/vcluster-in-CI running real Crossplane + ACK + Kyverno + ArgoCD would have surfaced #2(a)(b) and the 3-gap blocker *without* paying for EKS. The fidelity gap: a vcluster can't fully reproduce *cloud-side* IAM/STS — but ACK/Crossplane *control-plane rendering* and PSA/admission behavior reproduce faithfully, which is exactly where #2 and the capability gaps lived.
Sources: <https://www.vcluster.com/blog/ephemeral-pr-environment-using-vcluster> · <https://2024.platformcon.com/talks/ephemeral-pull-request-environments-with-crossplane-argo-cd-and-vclusterpro> · <https://www.signadot.com/articles/comprehensive-guide-to-preview-environments/>

### B/C-partial — Crossplane composition testing  → **MATURE (shift-left), with a real edge**
`crossplane render` (graduated from beta in 1.17) renders a composite locally against the functions; **`crossplane beta validate`** checks the rendered output against the **XRD/CRD/Provider schemas offline**, using the Kubernetes API server's validation library *plus unknown-field detection* — no live control plane needed. **This class of error — "composition references a field not declared in the XRD schema" (our #2b) — is exactly what `beta validate` catches statically.** It is a single binary → trivial CI step. Community frameworks **xprin**, **KUTTL**, and **chainsaw** add render+assert test suites. The honest edge: `render`/`validate` exercise the *rendering* path; the PSA-rejects-the-function-pod failure (#2a) is a *runtime* admission event that `render` won't see — that one needs the ephemeral-cluster path (A) or policy testing (D-below). So #2b was statically preventable; #2a was not, purely from Crossplane tooling.
Sources: <https://docs.crossplane.io/latest/cli/command-reference> · <https://blog.upbound.io/composition-testing-patterns-rendering> · <https://github.com/crossplane-contrib/xprin>

### F — Policy / admission shift-left  → **MATURE**
The **Kyverno CLI** (`kyverno apply`, `kyverno test`) runs policies against manifests *outside the cluster* in CI, and **maps the Pod Security Standards (Baseline/Restricted) to policy checks** — so "this pod violates `restricted` PSA" is catchable at PR time before any deploy. **Conftest/OPA (Rego)** is the engine-neutral equivalent. The catch for #2(a): the pod that violated PSA was the **Crossplane function runtime pod**, which the platform generates dynamically from a `DeploymentRuntimeConfig` — it isn't in a static manifest we lint. So PSA shift-left would catch our *own* manifests reliably, but a generated operator pod needs either (i) a render step that emits the function pod spec to lint, or (ii) the ephemeral cluster (A). Mature tooling; the gap is that the offending pod wasn't in scope of a static lint.
Sources: <https://kyverno.io/docs/policy-types/cluster-policy/validate/> · <https://thenewstack.io/using-the-kyverno-cli-to-write-policy-test-cases/> · <https://www.red-team.sh/posts/policy-as-code-opa-kyverno-eks-security/>

### D — Helm / OCI chart dependency robustness  → **MATURE**
The recommended supply-chain-robust pattern: **stop hosting/pulling charts from GitHub Releases** (the exact source that 404'd in #6) and instead **store charts in an OCI registry** (content-addressable, cached, same pipeline/credentials as images), **vendor/relocate** charts you depend on (`helm pull` into your own registry), **pin by digest** (immutable, unlike tags), and let **Renovate** track updates. OCI registries give pull-through caching/mirroring so a transient upstream blip doesn't fail the apply. One honest wrinkle: Renovate digest-pinning for *OCI Helm* charts has had rough edges in some setups, but the mirror + digest-pin pattern itself is well-established.
Sources: <https://helm.sh/docs/topics/registries/> · <https://deepwiki.com/helm/helm/6.3-oci-registry-integration> · <https://docs.renovatebot.com/>

### C — Cross-repo config contract testing  → **GENUINELY HARD (partial answers only)**
This is the one class where the industry does **not** have a clean turnkey answer for *config* drift. **Consumer-driven contract testing (Pact)** + the **Pact Broker** as a deploy-gate source of truth is mature for **API request/response shapes** — it answers "can consumer vX and provider vY deploy together?" But Pact does **not** natively answer "two repos disagree on a registry account ID / a hostname / which OIDC token type" — those are *configuration* facts, not API schemas. The practical industry pattern is **single-source-of-truth config generation** (one authoritative value, all consumers derive from it) + a CI validation step — i.e. you build the contract yourself; there's no off-the-shelf "config Pact." GitOps drift detection (Argo CD) catches *cluster-vs-git* drift but not *repo-vs-repo* config disagreement. **Verdict: build single-source-of-truth + apply-time assertions in-house.**
Sources: <https://pact.io/> · <https://docs.pact.io/> · <https://specmatic.io/updates/pacts-dependency-drag-why-consumer-driven-contracts-dont-support-parallel-development/>

### E / GitOps health — capability contract + progressive-delivery gating  → **MATURE**
**Argo CD** models resource health (Healthy/Progressing/Degraded/Suspended) and understands Argo Rollouts via a Lua health check; **Argo Rollouts AnalysisTemplates** run continuous metric checks during canary and **automatically abort/rollback** on degradation. This is directly relevant to the audit's note that the `aegis-core` aggregate Application would look Degraded (engine model-pending masking a healthy gateway) — the industry pattern is to **gate on per-resource health, not aggregate app health**, exactly as we did (`kubectl get rollout aegis-core-gateway` + real HTTP 200, not the aggregate). For the platform-capability-vs-workload-requirement contract (class E) there's no single named product, but the GitOps norm is an **AppProject allow-list** (which we use) + capability addons owned by the platform tier — the discipline is real, the tooling is assembly.
Sources: <https://argoproj.github.io/rollouts/> · <https://argo-cd.readthedocs.io/en/stable/> · <https://oneuptime.com/blog/post/2026-02-26-argocd-automatic-rollback-health-degradation/view>

### G — Supply-chain pinning by digest (images AND charts)  → **MATURE / authoritative**
**SLSA** and CNCF/Docker guidance are unambiguous: **pin every external dependency — base images, GitHub Actions, Helm charts — by content-addressable digest (SHA), not mutable tag.** Digests are immutable; this both removes upstream drift (the #6 class) and closes the tag-repoint attack. We already digest-pin images (ADR-10/14 guards); extend the same discipline to charts (§D).
Sources: <https://slsa.dev/> · <https://www.docker.com/blog/software-supply-chain-security-best-practices/> · <https://www.wiz.io/academy/application-security/slsa-framework>

### #3 — OIDC token-type (access vs id)  → **KNOWN PITFALL, with a candid caveat**
The access-vs-id-token confusion is a **well-documented common SPA+API pitfall**. The *authoritative* guidance (Auth0/AWS/Microsoft/OAuth BCP) is the **opposite** of our fix: a SPA should send the **access token** to an API; the **id token** is for the SPA to learn *who the user is*, not for API authorization — sending the id token to an API is explicitly called out as a mistake. **Our gateway, however, validates `aud=clientId` + `custom:tenant_id`, which are ID-token claims** — so the *correct fix for our current design* was to send the id token. That works, but it signals our gateway's validation is **non-canonical**: the industry-clean design is to validate the *access* token (with a proper resource-server `audience` and scopes/claims on it). **Flagging candidly: #3's fix unblocks e2e, but the canonical hardening is to make the gateway an OAuth2 resource server that validates the access token** — worth an ADR follow-up, not a silent accept.
Sources: <https://aws.amazon.com/blogs/apn/how-to-integrate-rest-apis-with-single-page-apps-and-secure-them-using-auth0-part-1/> · <https://www.w3tutorials.net/blog/clarification-on-id-token-vs-access-token/> · <https://wso2.com/blogs/thesource/securing-spas-best-practices/>

> **中文小結:** 大多數類別業界都有成熟解:A 用 vcluster/ephemeral env、B/C-部分用 `crossplane render`+`beta validate`(#2b 可靜態抓,#2a 不行)、F 用 Kyverno CLI `test` + PSS mapping、D 用 OCI registry mirror + digest pin、E/health 用 Argo Rollouts analysis + 看 per-resource health、G 用 SLSA digest pinning。**只有 C(跨 repo 設定契約)是真的難**——Pact 只解 API shape,不解 account-ID/hostname/token-type 漂移,得自己做單一真實來源 + CI 驗證。另外**#3 的 token-type 修法雖然解了 e2e,但業界正解是讓 gateway 驗 access token**,我們現在驗 id token 是 non-canonical,該補一個 ADR。

---

## 8. What To Change Next (prioritized, actionable)

| Priority | Action | Kills which class | Effort |
|----------|--------|-------------------|--------|
| **P0** | IaC the two remaining engine fixes: populate the `default` `DeploymentRuntimeConfig` securityContext in `crossplane.tf` (#2a); align Crossplane↔XRD `resourceRefs.namespace` schema in `charts/aegis-xrds` (#2b). | A/F/G (the open blocker) | S |
| **P0** | Add `crossplane render` + **`crossplane beta validate`** and **`kyverno test`** (+ kustomize/helm render) as a **required pre-apply CI gate**. Statically catches #2b and our own PSA violations. | B, F, partial A | S–M |
| **P0** | Vendor/mirror all Helm charts into an OCI registry we own, **pin by digest**, stop pulling from GitHub Releases. Add bounded retry-before-reap to the apply step. | D, #6 | M |
| **P1** | Single-source-of-truth for cross-cutting config (registry account, hostnames, Cognito, **token-type**) generated from Terraform outputs / one GH-var contract, with a CI assertion that fails loud on consumer drift. | C, B | M |
| **P1** | Stand up a **kind/vcluster-in-CI** ephemeral full-stack env (Crossplane+ACK+Kyverno+ArgoCD+real manifests) to exercise the e2e seam before any billable EKS apply. | A (root lever) | M–L |
| **P1** | Encode a **platform-capability manifest** (Rollouts, kyverno, ALB-controller, Alloy, ArgoCD AppProject allow-list) and lint each workload against it at enrollment. | E | M |
| **P2** | Promote the **pre-apply adversarial audit** to a standing gate, fed with the capability manifest + config contract. | A/C/E (defense in depth) | S |
| **P2** | ADR: make the gateway a canonical OAuth2 **resource server validating the access token** (not the id token). Until then, document #3's id-token validation as a known deviation. | #3 hardening | M |
| **P2** | Land the real **Phase-4c model-store CI populator** (#5) so the model bucket isn't a manual seed. | G | M |
| **P3** | Re-enable the self-reap (`ALLOW_PARTIAL_APPLY=false`) the moment attended iteration ends; document attended/unattended as explicit modes. | process (#6) | XS |

**One-line takeaway:** the pitfalls weren't a sign the prior phases failed — they were the *first* exercise of the full-AWS-e2e seam. The durable fix is to **run that seam cheaply (ephemeral + render/validate/policy gates + a config contract) before running it expensively**, and to **fail loud, retry transients, and live-fix small bugs instead of tearing down**.

> **中文總結 (最終):** 地雷不是「前面失敗」,而是**第一次跑全 AWS e2e 這條縫**。真正的解:**在付費前用便宜方式把這條縫跑一遍**——ephemeral 環境 + `crossplane render/validate` + `kyverno test` + 跨 repo 設定契約;再加上 fail-loud、瞬斷重試、小 bug live-fix 不 tear-down。業界對大多數類別已有成熟工具,唯一要自己造的是「跨 repo 設定契約」這塊。最該先做的是 P0 三件:補完 engine 兩個 IaC 修、把 render/validate/policy 變成 pre-apply gate、chart mirror + digest pin。
