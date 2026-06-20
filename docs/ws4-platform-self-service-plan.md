# WS4 — Platform Self-Service: One Declaration to Onboard a Workload

> **Status:** DRAFT plan. The Crossplane engine choice + the Terraform↔Crossplane
> boundary are now decided in **ADR-22 (Crossplane v2-era), which is authoritative**;
> this plan defers to it and is not re-litigating the engine. Axis B's `XService`
> onboarding XR is still a draft awaiting its own ADR.

## 0. Revision note — 2026-06-19 (read first; supersedes the as-written §2/§3/§5/§6 where they conflict)

After three grounded design rounds, the engine question is settled in **ADR-22**. The
corrections below override this plan's original text wherever they disagree — ADR-22 is
the source of truth, this plan is the build sequence:

1. **Engine = Crossplane v2** (GA 2025-08, CNCF Graduated), not v1. The whole fix-B
   namespace fight was a v1 cluster-scoped-vs-namespaced artifact that **disappears** in
   v2 (namespaced XRs by default). Authoring is v2-native: composition **functions**,
   **provider family + MRAP** (activate only the resource types we use), provider pod
   credentials via **EKS Pod Identity** (not the retired `/aegis-workload/` IRSA role).
2. **Identity left Crossplane.** ADR-21 §A + PR #117 moved engine IAM to **EKS Pod
   Identity + Terraform**. So Axis A's original premise — "extend `XWorkloadIdentity`" —
   is **void**. Crossplane never re-owns identity; Axis A is **non-identity** workload
   cloud only (`XBucket`/`XQueue`/`XTable`).
3. **Stateful stays in Terraform.** Crossplane has no `plan`/dry-run and a history of
   silent deletion on upgrade. Crossplane claims cover only **rebuildable, small-blast**
   resources; every data-bearing resource (RDS-class) stays in Terraform. The no-plan
   engine never owns a data store.
4. **Engine alternatives were evaluated and rejected** (ADR-22 §Options): **tofu-controller**
   keeps `plan` but is module-per-cloud with no app-facing neutral abstraction (fails the
   decisive criterion: multi-cloud complexity belongs to the platform engineer, not the
   backend engineer); **KRO** is only the composition layer (~1/3 of the stack), makes zero
   cloud API calls, has no on-prem path, and is still `v1alpha1`; **Kratix** is overkill for
   1–3 workloads. Crossplane v2 is the only tool with all three layers **and** an on-prem
   path. `function-kro` (Crossplane-side) means KRO's authoring ergonomics stay available
   later without migrating off Crossplane — the convergence is one-directional.
5. **Crossplane is scenario-justified, not premature.** The gate is (multi-cloud intent ×
   a dedicated platform role), not workload count. aegis passes both; the earlier
   "premature at 1–3 workloads" framing is withdrawn.

Everything below is the original plan; treat §2's "extend `XWorkloadIdentity`", §5's
identity row, and §6's scoreboard as superseded by the points above + ADR-22.
> **Scope:** the *platform* layer of `aegis-platform-aws` plus the deploy-repo contract.
> **Author context:** written after the WS3 staging end-to-end bring-up
> (`RETRO-ws3-staging-e2e-2026-06-18.md`), which is the empirical source for the
> "scattered onboarding" pain this work removes.

---

## 中文摘要 (Chinese summary)

WS4 的目標:讓「加一個 workload」像「加一塊積木 (Block)」一樣零摩擦。今天要上一個
workload(以 WS3 的 `aegis-core` 為例),操作分散在六、七個地方,而且很多缺口是
**apply 到一半才發現**(RETRO §2:argo-rollouts 沒裝、AppProject 沒放行、IRSA 鏈斷、
跨帳號 ECR、Cognito GH var、frontend edge IaC)。

WS4 切成**兩條正交的軸**,兩者會合流但**不是同一件事**:

- **軸 A(引擎/邊界):用 Crossplane 把 workload 級的雲端資源補完。** 把每個 workload
  自己的 S3 bucket / SQS / DynamoDB 等,從 Terraform/散落各處,搬成 Crossplane claim,
  延伸現有的 `XWorkloadIdentity`(ADR-09 fix-B 已證明這條 composition 路可行)。
- **軸 B(真正的 WS4):一份統一的 onboarding 宣告。** 每個 workload **一個**高階
  claim,fan-out 到**全部**依賴:ArgoCD Application + IRSA + ECR 接線 + ingress/ACM/
  Route53 + frontend edge + OIDC 注入 + 能力確認(argo-rollouts、AppProject 白名單)
  + 軸 A 的 workload 級雲端資源。

**命名陷阱:** 新 XR **不要**叫 `Workload`——會跟 k8s 既有「workload」(Deployment/
StatefulSet/Rollout/Job 的統稱)撞名。本文建議 **`XService` / `AegisService`**。

**選型結論:延伸自家 Crossplane XRD(`XService`),不引入 Score / OAM-KubeVela /
Backstage 當第二個控制平面。** 理由:fix-B 已實證 Crossplane composition 能 fan-out 到
真 AWS;aegis 的硬約束(provider-neutral、on-prem + 多雲、現有 XRD/Terraform 投資、
app/deploy 分離、dev 不碰 infra)正好是 Crossplane 的強項。Score 的中立性很吸引人,但
它只生成 manifests、不管 runtime reconcile / IRSA,仍要一個後端——在 aegis 那個後端就是
Crossplane,等於多一層卻不省事。詳見 §6 scoreboard。

**分期(每期先在 staging 驗,絕不在 prod 首演——RETRO「先用便宜的方式跑這條縫」):**
Phase 1 = 軸 A(workload 級雲端資源變 claim);Phase 2 = onboarding XR + Composition;
Phase 3 = 把 greeter 與 aegis-core 遷過去。

---

## 1. Problem Statement — Onboarding Is Scattered, and the Gaps Surface Mid-Apply

Adding a workload today means touching a value, a claim, a GitHub variable, and a deploy-repo
overlay across at least four planes — and the WS3 staging bring-up proved that the *missing*
pieces are discovered only when an `apply` or an ArgoCD sync fails on a billable cluster, not
up front.

### 1.1 The before-state: where a workload's onboarding actually lives today

| # | What you set | Where it lives | Plane |
|---|---|---|---|
| 1 | The workload's **catalog entry** (it exists at all) | `registries.auto.tfvars.json` → `var.workload_registries` (gitignored; CI materializes it from the `REGISTRIES_JSON` GitHub variable) | Terraform / GH var |
| 2 | **ArgoCD Application** (repoURL, overlay path, namespace, project) | rendered by the `List` generator in `terraform/modules/regional-stack/argocd.tf` (`local.workload_list_elements` → `applicationsets.aegis-workloads.template`) | Terraform → ArgoCD |
| 3 | **ECR pull wiring** (account-ID-hidden registry URL) | `ecr_account_id` / `ecr_region` in the registries entry → injected as the `aegis.binhsu.org/ecr-repository` annotation (ADR-12) | Terraform → annotation |
| 4 | **IRSA** (the engine's IAM role) | `engine_irsa.{service_account,role_name,policy_arns}` in the registries entry → `XWorkloadIdentity` Claim in the deploy repo (`aegis-core-deploy/k8s/components/aws-binding/iam/aegis-core-engine-identity.yaml`) + the role-arn annotation patch in `argocd.tf` `templatePatch` | TF + deploy repo + Crossplane |
| 5 | **ingress / ACM cert** | `ingress_cert.{ingress_name,cert_arn}` in the registries entry → ALB cert-arn annotation patch (`argocd.tf` `templatePatch`); cert itself from the module's `acm.tf` | Terraform → annotation |
| 6 | **OIDC config injection** (Cognito issuer/audience/JWKS) | `var.cognito_issuer/audience/jwks_url` (regional-stack `variables.tf` L108–124) → `gateway-oidc` ConfigMap patch (`argocd.tf` `templatePatch`); values set as GH vars post-apply from `cognito.tf` outputs | TF var + GH var → ConfigMap |
| 7 | **model bucket injection** | `aws_s3_bucket.models` (per-region, `model-store.tf`) → `model-store` ConfigMap patch (`argocd.tf` `templatePatch`) | Terraform → ConfigMap |
| 8 | **capability ensure** (argo-rollouts present; AppProject allow-list covers what the workload ships) | platform-side: `helm_release.argo_rollouts` + the `aegis-workloads` AppProject `clusterResourceWhitelist`/`namespaceResourceWhitelist` in `argocd.tf` | Terraform (platform) |
| 9 | **deploy-repo overlay** (the `aws-binding` component re-adds ALB Ingress + the `WorkloadIdentity` XR; staging/prod kustomization) | `aegis-core-deploy/k8s/components/aws-binding/`, `k8s/overlays/{staging,prod}/` | deploy repo |
| 10 | **frontend edge** (S3 + CloudFront + ACM for the SPA) | platform-tier IaC (commit `9ae8961` "IaC the frontend SPA edge"); Cognito redirect/pool values as `VITE_AEGIS_COGNITO_*` GH vars | Terraform + GH var |

Ten coordinates, four planes, two repos, and two value-injection channels (GitHub variables
*and* Terraform vars). No single artifact says "here is workload X and everything it needs."

### 1.2 The pain is empirical, not theoretical

The WS3 staging end-to-end (`RETRO-ws3-staging-e2e-2026-06-18.md` §2, §4) hit, in one billable
run, the exact gaps a unified onboarding declaration removes:

- **argo-rollouts not installed** — `aegis-core`'s gateway/engine are `argoproj.io` Rollouts;
  the platform had not wired the controller, so the first sync failed
  (`Rollout.argoproj.io "" not found`). Capability-vs-requirement mismatch (RETRO class E).
- **AppProject too narrow** — the workload ships a Kyverno policy and ACK/Crossplane CRDs the
  `aegis-workloads` project allow-list did not cover.
- **IRSA chain broken at two points** — PSA `restricted` rejected the Crossplane function pod,
  then a cluster-scoped XR could not compose a namespaced ACK `Role`
  (`spec.resourceRefs[].namespace: field not declared in schema`). Fixed by **fix-B**:
  replace ACK with the upjet `iam.aws.upbound.io/Role` (cluster-scoped). This is the live
  state of `composition-workloadidentity.yaml`.
- **cross-account ECR mismatch** — CI pushed to a per-account `aegis-core` repo while the
  deploy pulled from the deployment account → `ImagePullBackOff`.
- **Cognito values stale / hand-wired** — frontend hardcoded a retired pool; OIDC values are
  GitHub variables set post-apply by hand.
- **frontend edge IaC** — only landed during WS3 (`9ae8961`), discovered as a missing piece.

The **first prod dual-region cold start** (2026-06-18 go-live, [`docs/runbooks/2026-06-20-dual-region-full-verification.md`](runbooks/2026-06-20-dual-region-full-verification.md))
added a second class — not workload-sync gaps but **platform bring-up ordering** gaps, each
discovered mid-run on a fresh account:

- **cold-start plan resilience** — the `eks-version-cost-gate` plans the *regional* stack to
  read the EKS version *before* `apply-platform` runs. On a never-applied account the platform
  remote-state has zero outputs, so four bare `remote_state.platform.outputs.*` reads
  (`infra_ci`/`infra_apply` role ARNs, `zone_id`, `zone_name`) hard-failed the gate plan, which
  the gate's fail-safe reports as the misleading "EKS version aged out". Fix needed `try()` with
  **syntactically-valid placeholders, not `""`** — downstream resources validate *shape* at plan
  time (`aws_route53_record` rejects an empty `zone_id`; `aws_acm_certificate` rejects a SAN
  ending in `.`). A self-service platform must guarantee a regional plan is clean against an
  *unapplied* platform, or no pre-apply gate can run. (Fix: pins `v0.2.1`→`v0.2.2`.)
- **DNS delegation is a manual cross-system step in the middle of an automated apply** —
  `apply-platform` creates the SPA-edge ACM cert (us-east-1, for CloudFront) which blocks on
  DNS-01 validation. Validation cannot complete until the per-env zone (`prod.aws.binhsu.org`)
  is delegated from Cloudflare to the AWS NS — a manual paste into a *different* system. The
  automated apply silently hung ~9 min (toward a 45-min timeout) waiting for a human. The zone
  + validation CNAME exist in Route 53 the moment `apply-platform` creates them; only the parent
  NS record is external. WS4 should make the delegation a **declared, pre-checked prerequisite**
  (or automate it via a Cloudflare provider), not a mid-apply surprise.

> The throughline (RETRO §2A): everything we validated was *code or a single component*;
> everything that bit was at the *integration seam*, discovered at apply time — and the prod
> cold start showed the seam is not only workload↔platform but **platform↔platform (ordering)**
> and **platform↔external-DNS**. WS4 collapses the seam into one declared spec so the platform —
> not the operator mid-apply — owns the fan-out.

---

## 2. The Two Axes — They Combine, But They Are Not the Same Thing

WS4 has two orthogonal axes. Keep them distinct: Axis A widens *what a workload can ask the
cloud for*; Axis B widens *how a workload asks for everything at once*. Axis B can call Axis A,
but neither requires the other to ship.

### Axis A — Crossplane-completion of workload-scoped cloud (engine / boundary)

Move per-workload cloud resources — a workload's own S3 bucket, SQS queue, DynamoDB table —
from Terraform / scattered placement into **Crossplane claims**, extending the existing
`XWorkloadIdentity` pattern (ADR-09, fix-B). This is the natural continuation of ADR-09's
default-ownership rule: *workload-scoped AWS resources are declared by the workload's deploy
repo as an XR instance* (`docs/adr/09-platform-as-product-xrd.md`), promoting to platform
Terraform only on ADR-09's five named triggers (≥2 cross-workload consumers, ≥2 producers,
lifecycle outlives the workload, cross-account/region, RDS-class blast radius).

Today only **identity** (`XWorkloadIdentity` → IAM Role) is a claim. Axis A authors the next
XRDs: `XBucket`, `XQueue`, `XTable` — each a thin Composition over the matching upjet
`provider-aws-*` MR, with the IAM read/write policy wired back into the workload's
`WorkloadIdentity.policyArns` so the engine can actually reach what it provisioned.

**Why upjet, not ACK:** fix-B proved the boundary. ACK's `Role` is a *namespaced* MR; a
cluster-scoped XR recording a ref to it forces `spec.resourceRefs[].namespace`, which the XR
schema rejects (`composition-workloadidentity.yaml`, L9–17). The upjet
`iam.aws.upbound.io/Role` is cluster-scoped — bug gone, and the provider family stays uniform
across the multi-cloud control plane. Axis A's new XRDs follow the same upjet path.

### Axis B — A unified onboarding declaration (the real WS4)

**ONE high-level claim per workload that fans out to EVERYTHING** in §1.1's table. The platform
team owns the Composition; the workload (or the platform's workload catalog) declares one spec.
Adding a workload becomes a single declaration plus a deploy repo — "add a workload like adding
a Block."

The two axes combine: Axis B's onboarding Composition *references* Axis A's resource claims
(an `XService` with `cloud: {buckets: [...]}` fans out to `XBucket` claims). But Axis B ships
value even with zero Axis-A resources — it already collapses items 1–10 of §1.1 for greeter,
which has no per-workload cloud at all.

---

## 3. The Proposed Onboarding Claim

### 3.1 Naming — do NOT call it `Workload`

`Workload` collides with Kubernetes's own umbrella term for Deployment / StatefulSet / Rollout /
Job / DaemonSet (the "Workloads" API category). An operator reading `kind: Workload` cannot tell
the platform abstraction from a k8s primitive. **Recommendation: `XService` (composite) /
`Service` claim**, or `AegisService` if `Service` is too close to `core/v1 Service`. This doc
uses **`XService`**. (Alternatives considered: `ServiceOnboarding` — verbose; `Platform` — too
broad.)

### 3.2 Shape — minimal surface, platform-owned fan-out

Following ADR-09's principle (the deploy repo declares *only what is genuinely workload-owned*;
everything cluster/account-bound is derived or platform-injected), `XService` carries workload
*intent*, never account IDs or ARNs:

```yaml
apiVersion: platform.aegis.io/v1alpha1
kind: XService            # claim kind: Service (namespaced)
metadata:
  name: aegis-core
spec:
  parameters:
    deployRepo: aegis-core-deploy          # → ArgoCD Application source
    overlayEnv: staging                    # → overlay path (env from cluster)
    progressive: true                      # → ensure argo-rollouts capability
    identity:                              # → Axis-A XWorkloadIdentity
      serviceAccount: aegis-core-engine
      policyArns: []                       # skeleton; cloud.* appends read/write
    edge:                                  # → ingress + ACM + Route53 + OIDC
      ingressName: aegis-core-gateway
      oidc: true                           # → gateway-oidc ConfigMap injection
      frontend: true                       # → S3 + CloudFront + ACM SPA edge
    cloud:                                 # → Axis-A resource claims (optional)
      buckets: [{name: models, access: read}]
      queues: []
      tables: []
```

### 3.3 Field → fan-out mapping (the heart of WS4)

Each field replaces an explicit coordinate from §1.1. The right column names the *existing*
resource the Composition drives — WS4 is mostly re-wiring, not net-new mechanism.

| `XService` field | Fans out to | Replaces / drives (existing) |
|---|---|---|
| `deployRepo` + `overlayEnv` | ArgoCD `Application` (repoURL, `k8s/overlays/<env>` path, derived namespace, `aegis-workloads` project) | `local.workload_list_elements` + the ApplicationSet template in `argocd.tf` |
| *(implicit: registry account)* | ECR pull annotation `aegis.binhsu.org/ecr-repository` | `ecr_account_id`/`ecr_region` from the registries entry (ADR-10/12) — sourced from the platform's deployment-account default, not re-declared per workload |
| `identity.serviceAccount` + `identity.policyArns` | `XWorkloadIdentity` claim → upjet IAM Role + the SA `eks.amazonaws.com/role-arn` annotation patch | `engine_irsa.*` + `templatePatch` role-arn + policyArns patches in `argocd.tf` |
| `edge.ingressName` | ALB cert-arn annotation (`alb.ingress.kubernetes.io/certificate-arn`) | `ingress_cert.*` + the cert-arn `templatePatch`; cert from `acm.tf` |
| `edge.oidc` | `gateway-oidc` ConfigMap (issuer/audience/jwksUrl) | `cognito_issuer/audience/jwks_url` vars + the ConfigMap `templatePatch` |
| `edge.frontend` | S3 + CloudFront + ACM SPA edge + Cognito redirect/pool wiring | platform frontend-edge IaC (commit `9ae8961`) + `VITE_AEGIS_COGNITO_*` |
| `progressive` | ensure `argo-rollouts` installed + AppProject allow-list covers Rollout/Policy/CRDs | `helm_release.argo_rollouts` + the `aegis-workloads` project whitelist (the RETRO §2 #E gap) |
| `cloud.buckets[]` (and the per-region model bucket) | `XBucket` claim → upjet S3 bucket + read/write policy appended to `identity.policyArns`; `model-store` ConfigMap | `aws_s3_bucket.models` (`model-store.tf`) + the model-store `templatePatch` |
| `cloud.queues[]` / `cloud.tables[]` | `XQueue` / `XTable` claims (Axis A, new) | — (net-new; today such resources are ad-hoc) |

The account ID and every ARN stay out of the spec — exactly as ADR-12/19 require (the ECR
account ID and the ACM cert ARN are injected, never committed to a public deploy repo). The
two account-ID-hide tiers from ADR-11 hold: IDs are visible in the platform tier
(`accounts.json`), hidden from the public deploy repos.

---

## 4. Before / After

### 4.1 `aegis-core` (engine + gateway + frontend — the heavy case)

**Before (what WS3 actually required):**
1. Add an entry to `REGISTRIES_JSON` (account, region, `engine_irsa`, `ingress_cert`).
2. Author/maintain the `XWorkloadIdentity` claim in `aegis-core-deploy/.../aws-binding/iam/`.
3. Confirm `argo-rollouts` is installed platform-side (it was not — RETRO §2 E).
4. Confirm the `aegis-workloads` AppProject allow-list covers the Rollout/Kyverno-Policy/CRDs.
5. Set `cognito_issuer/audience/jwks_url` GH vars from `cognito.tf` outputs, post-apply.
6. Set `VITE_AEGIS_COGNITO_*` GH vars for the frontend; ensure the SPA edge IaC exists.
7. Ensure CI pushes to the *deployment-account* ECR repo, not a per-account one (RETRO §2 #1).
8. Discover the model bucket is empty and seed it (RETRO §2 #5).

**After:** one `XService` spec (§3.2) with `identity`, `edge.{oidc,frontend}`, and
`cloud.buckets:[models]`. The Composition installs/ensures argo-rollouts, widens the AppProject,
provisions IRSA + the model bucket + its policy, wires Cognito and the SPA edge from platform
outputs, and emits the ArgoCD Application. The operator reviews one diff, not eight planes.

### 4.2 `aegis-greeter` (plain Deployment — the light case)

**Before:** add a `REGISTRIES_JSON` entry (account + region only; greeter declares no
`engine_irsa`/`ingress_cert` — see `registries.auto.tfvars.json`); rely on the ApplicationSet
to render its Application; maintain the deploy-repo overlay.

**After:** `XService` with `deployRepo: aegis-greeter-deploy`, `overlayEnv`, no `identity`,
no `edge`, no `cloud`. Every optional fan-out keys off an absent field and renders nothing —
mirroring today's `{{- if … }}` guards in `argocd.tf` `templatePatch`. Greeter onboards with
the smallest possible spec; the platform's defaults (deployment-account ECR, derived namespace)
fill the rest.

---

## 5. The Terraform ↔ Crossplane Boundary (seed for ADR-21)

The dividing principle is **bootstrap dependency**: Terraform owns anything Crossplane needs in
order to run, plus anything shared across workloads or spanning accounts; Crossplane owns
workload-scoped cloud, reconciled in the cluster the workload already lives in. The
chicken-and-egg is not academic — fix-B proved it this session: **Crossplane cannot bootstrap
the cluster it runs in, nor grant itself its own IAM.** The upjet IAM provider gets its
credentials from an IRSA role (`irsa-ack-iam.tf`, reused with the `aegis-platform-aws-ack-iam-`
prefix so the org SCP carve-out still matches) that **Terraform** creates — Crossplane provisions
workload roles only *after* Terraform has granted Crossplane its own.

| Concern | Owner | Why |
|---|---|---|
| EKS cluster, VPC, node groups, addons | **Terraform** | Crossplane runs *inside* this; it cannot create its own substrate (chicken-egg). |
| Crossplane's **own** enablement: the provider IRSA role + the SCP carve-out it relies on | **Terraform** | Crossplane cannot grant itself the IAM it uses to grant others (proven by fix-B; `irsa-ack-iam.tf`). |
| Account/org fabric, SCPs, OIDC provider trust anchor | **Terraform** (landing zone) | Cross-account, org-level; pre-exists any cluster. ADR-07: landing zone narrows to "OIDC trust anchor only." |
| Shared edge: Route53 zone, Cognito user pool, ECR repos, wildcard ACM | **Terraform** | Shared across workloads / spans accounts; ADR-09's promotion triggers (≥2 consumers, cross-account) put these firmly in TF. ADR-19: the zone is delegated from Cloudflare (a one-time operator step), the deployment-account ECR is one shared registry (ADR-10). |
| ArgoCD, argo-rollouts, Kyverno, the XRDs/Compositions themselves | **Terraform** (Helm) | The control-plane machinery the claims depend on. A claim cannot install the controller that reconciles it. |
| Per-workload **identity** (IAM role) | **Terraform + EKS Pod Identity** (ADR-21 §A, ADR-22) | ~~Crossplane `XWorkloadIdentity`~~ **superseded.** Terraform owns the role; an `aws_eks_pod_identity_association` binds it to the namespace/SA. Destroyed cleanly with the stack — no orphan, no `/aegis-workload/`. Crossplane never owns identity. |
| Per-workload **stateful / data-bearing** cloud (RDS-class, anything whose deletion loses data) | **Terraform** | Crossplane has no `plan`/dry-run + a silent-deletion-on-upgrade history (ADR-22 §3). Keep `plan` where data is at stake; the no-plan engine never owns a data store. |
| Per-workload **cloud**: buckets, queues, tables (Axis A) | **Crossplane** (`XBucket`/`XQueue`/`XTable`) | Workload-scoped, single-consumer; ADR-09 default-ownership. Promotes to TF only on the five triggers. |
| The onboarding fan-out itself (Axis B) | **Crossplane** (`XService` Composition) | Composes the workload-scoped claims + references the TF-owned shared edge via injected values — same channel as today's `templatePatch`. |

**The rule of thumb for ADR-21:** if removing the workload would leave the resource orphaned or
still serving another consumer, it is shared → Terraform. If the resource lives and dies with
the workload and no one else reads it, it is a claim → Crossplane. The non-disruptive promotion
path stays ADR-09's: `deletionPolicy: orphan` → drop the claim → `terraform import` (the ARN is
stable).

---

## 6. Industry Options — Scoreboard and Recommendation

aegis's hard constraints: **provider-neutral** (ADR-16); **on-prem + multi-cloud** (the same
base must run on Talos with MinIO/SPIRE and on EKS with S3/IRSA); an **existing Crossplane/XRD +
Terraform** investment (ADR-09 fix-B is live); strict **app/deploy separation** (ADR-07/10); and
the **dev-doesn't-touch-infra** premise.

| Option | What it is | Fit for aegis | Score (1–5) |
|---|---|---|---|
| **1. Extend aegis's own Crossplane XRDs** (`XService`, continue ADR-09) | Author a platform XRD whose Composition fans out to existing claims + injected shared-edge values. | **Best fit.** fix-B already proved the composition → real-AWS path; the `templatePatch` fan-out logic already exists in `argocd.tf` and just needs to move behind an XR. Provider-neutral by the same Composition-swap seam ADR-16/ADR-09 define (AWS upjet vs on-prem MinIO/SPIRE Compositions). No second control plane, no new credential boundary. | **5** |
| **2. Score** (score.dev, CNCF Sandbox) | A platform-agnostic, environment-agnostic *workload spec* (`score.yaml`); a CLI implementation (`score-compose`, `score-helm`) *generates* platform config. | Attractive neutrality — but Score **only generates manifests; it does not reconcile runtime or provision IRSA/cloud resources**. It still needs a backend, and in aegis that backend is Crossplane. Adopting Score = one more spec layer over Crossplane without removing it; its generators also don't model the account-ID-hide injection (ADR-12) or the IRSA trust derivation (ADR-09). Worth revisiting *as the dev-facing front-end spec* later, not as the WS4 engine. | **3** |
| **3. OAM / KubeVela** | Open Application Model (Application + Components + Traits), CUE-templated; KubeVela is the runtime. | KubeVela *wraps* Crossplane Compositions to add an app-centric layer — useful when you don't already have a curated XRD vocabulary. aegis does. As the community notes, "if Crossplane is already in place it can make KubeVela obsolete." Adds a CUE/Trait control plane and a learning surface for a layer aegis already owns. | **2** |
| **4. Backstage golden paths / software templates** | A *developer portal*; the Scaffolder produces repos/catalog entries from form input. | Backstage is a **portal/scaffolder, not a runtime provisioner** — it creates a service skeleton at day 0, it does not reconcile IRSA or buckets at day N. Complementary (a future UI in front of `XService`), orthogonal to WS4's provisioning engine. Out of scope now. | **2** |

### Recommendation

**Extend the existing Crossplane XRD investment — author `XService` (Axis B) over new
per-resource XRDs (Axis A).** One-line rationale: fix-B already proved the Crossplane
composition → real-AWS path and the `templatePatch` fan-out logic already exists in
`argocd.tf`, so `XService` is the *lowest-friction, lowest-new-trust-surface* option that
also preserves provider-neutrality by the same Composition-swap seam ADR-16 defines — Score/
OAM/Backstage would each add a second control plane over a vocabulary aegis already owns.

(Honest caveat, not glossed: Score's neutrality is genuinely cleaner *at the spec layer* — a
`score.yaml` is more portable than a `platform.aegis.io` XR. If aegis ever wants a vendor-neutral
dev-facing spec decoupled from the Crossplane backend, Score-in-front-of-`XService` is the right
revisit. For WS4's goal — collapse the fan-out — it adds a layer without removing one.)

---

## 7. Phased Rollout — Each Phase Validated on Staging First

Per the RETRO's central lesson (§4, §8): *each phase exercises a different, narrower seam; run
the seam cheaply before the billable one.* **No phase debuts on prod.** Each phase is proven on
the local Talos substrate and/or the staging EKS cluster before prod ever sees it.

**Phase 1 — Axis A: per-workload cloud as claims.**
Author `XBucket` (first; the model bucket is the obvious pilot — it already exists as
`model-store.tf` and can migrate via ADR-09's orphan→import path), then `XQueue` / `XTable` as
demand appears. Each Composition wires its read/write policy back into `WorkloadIdentity`.
Validate with `crossplane render` + `crossplane beta validate` offline (RETRO §7 B — this would
have caught the fix-B schema mismatch before spending), then on local Talos (Composition swap to
MinIO), then on staging.

**Phase 2 — Axis B: the onboarding claim + Composition.**
Author the `XService` XRD (§3) and its Composition, moving the `argocd.tf` `templatePatch`
fan-out logic behind the XR. Keep the existing `List`-generator path working in parallel
(dual-run) so onboarding never breaks mid-migration. Validate the rendered ArgoCD Application,
IRSA chain, and ConfigMap injection on staging with a throwaway test workload before touching a
real one.

**Phase 3 — Migrate greeter, then aegis-core.**
Greeter first (the light case: no identity/edge/cloud — lowest blast radius), prove the
end-to-end onboard from a single `XService`, then migrate `aegis-core` (identity + edge + model
bucket). Retire the per-workload pieces of `REGISTRIES_JSON` only after both run green on
staging. Enable platform self-reap (`REAP_ON_APPLY_FAILURE=true`; opt-in, off by
default during attended iteration) only once unattended onboarding is proven.

---

## 7B. Carry-in from the WS3 prod go-live — fixes pending verification (WS4 owns the proof)

The 2026-06-18 prod dual-region cold-start proved the IaC path on `eu-west-1` but surfaced a
batch of fixes whose **code landed (or is in draft PR) during WS3, while their *verification*
is WS4 scope** — because verifying them properly is exactly the "run the seam cheaply before the
billable one" discipline WS4 builds (§7). WS4 owns the harness; these are its first real payload.

| Fix (from the go-live) | Artifact | How WS4 verifies it (no prod debut) |
|---|---|---|
| version-gate `try()` gaps + zone placeholders | merged (v0.2.1/v0.2.2) | **`terraform test` / plan-against-empty-state CI gate** (§7D below) — assert a regional plan is clean against an *unapplied* platform state |
| IAM global-name collision → region-suffix | merged (v0.2.3) | dual-region plan in the ephemeral/preview env — assert no `EntityAlreadyExists` across two parallel regions |
| version-gate `-lock=false` + error classification | PR #109 + draft PR (2026-06-19) | inject a stale `.tflock`, assert the gate plan still runs and the message names the real cause |
| **aegis-xrds DRC race** (explicit family provider) | draft PR (2026-06-19) | **`crossplane render` + live cluster** — family provider `Healthy=True`, non-empty securityContext on its deployment, pod 1/1; this is the Phase-1 `crossplane beta validate` gate (§7 Phase 1) |
| **destroy-platform var surface** (DRY) | draft PR (2026-06-19) | dispatch `destroy-platform` against a torn-down test account — assert it no longer fails on a missing `TF_VAR_*` |
| **EKS Pod Identity vs Crossplane IRSA**, flag decoupling, prod image-release + ECR replication | ADR (draft, 2026-06-19) | design decisions feeding WS4 Phases 1–3; Pod Identity also removes the orphan-IAM teardown hazard the go-live hit |

### 7D — Prevent the next cold-start surprise (the verification harness WS4 must build)

The go-live hit **5** latent bugs *on prod* that a disposable env would have caught first. WS4's
verification layer, applied to every fix above and every new `XService`:
- **Ephemeral / preview environment** (vcluster or a throwaway account) so a first-ever cold-start
  runs OFF the prod path — the single highest-leverage item.
- **`terraform test` (1.6+) plan-against-empty-state** as a PR gate — cold-start plan resilience
  becomes automated, not a thing I hand-checked locally at midnight.
- **`crossplane render` / `beta validate`** in CI for every chart/Composition change (RETRO §7B).
- **`kyverno test` + kustomize/helm render** as PR gates before any billable apply.

These are not new asks — they are the RETRO's §4/§8 conclusions, now with five concrete prod
casualties proving the cost of skipping them. **WS4 Phase 0 = stand up this harness**, then every
carry-in fix is verified through it before it re-touches prod.

---

## 8. Risks and the Escape-Hatch Caveat

- **Golden-path LCD (lowest common denominator).** `XService` covers the *common* shape
  (engine + edge + a few buckets). A genuinely novel need — a workload wanting an RDS cluster,
  a VPC peering, a non-standard ingress — must **extend the platform once** (a new XRD field or
  a new Axis-A claim), not fork the abstraction per workload. State this explicitly: the golden
  path is a paved road, not a wall. ADR-09's promotion triggers are the pressure valve — when a
  resource outgrows the claim, it graduates to Terraform.
- **A leaky abstraction is worse than none.** If `XService` hides a fan-out the operator must
  still debug at 3am, it has failed. Mitigation: every fan-out target stays inspectable
  (`kubectl get xworkloadidentity,xbucket`), and the Composition emits status conditions per
  fanned-out resource — the operator can always see *which* leg is unhealthy (the WS3 IRSA
  chain failed silently across two hops; status surfacing is the fix).
- **Dual source of truth during migration.** Phases 2–3 run `XService` and the legacy
  `List`-generator path together. This is exactly the half-completed-migration class that bit
  WS3 (RETRO §3 B — per-account ECR repos survived a partial ADR-10 migration). Mitigation: a
  CI assertion that a workload appears in *exactly one* path, and a hard cut-over per workload,
  not a long straddle.
- **XRD versioning.** `XService` ships `v1alpha1` with an explicit breaking-change license
  (ADR-09); `v1` is gated on a second-cloud Composition or six months steady-state. Do not
  promise stability the abstraction has not earned.
- **Crossplane as a wider blast radius.** Moving more provisioning into Crossplane makes the
  control plane more load-bearing. Keep the TF↔Crossplane boundary (§5) strict: the things
  Crossplane *needs to run* never move into Crossplane.

---

## Appendix — Source Grounding

**Repo (this session, read directly):**
- `terraform/modules/regional-stack/argocd.tf` — the `List` generator, `local.workload_list_elements`, the ApplicationSet template, and the `templatePatch` fan-out (role-arn, policyArns, cert-arn, model-store, gateway-oidc).
- `terraform/modules/regional-stack/variables.tf` (L60–124) — `workload_registries` shape (`engine_irsa`, `ingress_cert`), `cognito_*` injection vars.
- `terraform/modules/regional-stack/charts/aegis-xrds/templates/{xrd-workloadidentity.yaml,composition-workloadidentity.yaml,provider-aws-iam.yaml,deploymentruntimeconfig.yaml}` — the live XRD + fix-B upjet Composition.
- `registries.auto.tfvars.json` + `.github/workflows/infra-{plan,apply,apply-account,ops}.yml` — `REGISTRIES_JSON` → `registries.auto.tfvars.json` materialization.
- `docs/adr/{07,09,10,11,12,16,19}*.md` — self-ownership, platform-as-product XRD (+ fix-B amendment), build-once/promote-by-digest, account SoT, field ownership, provider-neutral injection, public edge.
- `../aegis-core-deploy/k8s/{base,components/aws-binding,overlays}/…` and `../aegis-greeter-deploy/k8s/…` — the deploy-repo overlay/component before-state; the live `WorkloadIdentity` claim.
- `RETRO-ws3-staging-e2e-2026-06-18.md` — §2 incident inventory, §2A preparations, §3 problem classes, §4 why-so-many, §7 industry solutions.

**Industry (web, cited):**
- Score — [docs.score.dev](https://docs.score.dev/docs/), [score-spec/spec](https://github.com/score-spec/spec), [CNCF: Score](https://www.cncf.io/projects/score/), [The New Stack: Score CNCF Sandbox](https://thenewstack.io/score-new-cncf-sandbox-tool-for-infrastructure-centric-dev/).
- Crossplane claims/XRD fan-out — [Crossplane: self-service infra claims](https://oneuptime.com/blog/post/2026-02-09-crossplane-claims-self-service/view), [Crossplane v1.20 multi-tenant guide](https://docs.crossplane.io/v1.20/guides/multi-tenant/).
- KubeVela / OAM vs Crossplane — [KubeVela vs Crossplane (Dev Genius, Feb 2026)](https://blog.devgenius.io/kubevela-vs-crossplane-platform-engineering-on-kubernetes-made-practical-3298a897effd), [KubeVela: Crossplane integration](https://kubevela.net/docs/platform-engineers/crossplane).
- Backstage golden paths / scaffolder — [Backstage software templates](https://backstage.io/docs/features/software-templates/), [Backstage golden paths (Medium, Apr 2026)](https://medium.com/@rameshavutu/how-to-build-golden-paths-in-backstage-idp-with-software-templates-170adce436fe).
