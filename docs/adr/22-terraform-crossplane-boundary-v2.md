# ADR-22: The Terraform ↔ Crossplane boundary (Crossplane v2-era)

> **Status: Proposed.** The direction is settled (decided with Bin across three
> grounded design rounds, 2026-06-19); the ADR stays Proposed until a WS4 cluster
> bring-up validates the v2 mechanics and the on-prem `provider-minio` fit. Flip to
> Accepted once both are proven.

## 中文摘要

WS3 的 prod go-live 把 engine 的 IAM 從「Crossplane 在 cluster 內 compose 出來的 IRSA
role」搬成 **EKS Pod Identity**(ADR-21 §A,PR #117),順手把整套 Crossplane v1 IRSA
machinery 退役。問題接著浮出:**WS4 要不要、以及怎麼把 Crossplane 請回來**做 workload
級的雲端資源(bucket / queue / table)?

決策:**請回來,但用 Crossplane v2,而且只做該做的那一層。** 三件事釘死:

1. **引擎 = Crossplane v2**(GA 2025-08,CNCF Graduated)。它是 landscape 上**唯一**同時備齊
   三層(composition 抽象 / provider 真的開資源 / lifecycle 控制)又涵蓋 **on-prem**
   的工具。掃過的對手都缺角:**tofu-controller** 保留了 `plan` 但**沒有**給 app 端的
   cloud-neutral 抽象(module-per-cloud,違反判準);**KRO** 只有 1/3(composition 層,
   本身不開資源、無 on-prem path、still alpha);**Kratix** 對 1–3 workload 過重;**純
   Terraform** 沒有給 app 端的 K8s 抽象。
2. **判準(Bin):多雲複雜度留給平台工程師,不給後端工程師。** 推論:若要把複雜度丟給
   後端,該組織最好**綁死一朵雲**、直接圍繞 native blocks 開發——抽象在那情境下是純
   overhead。aegis 是**多雲意圖 × 有專職平台角色**,兩者皆成立,所以 Crossplane 由
   **場景**證成,不是由 workload 數量證成。
3. **劃界堵住 Crossplane 唯一致命傷(沒有 `plan`、升級會靜默刪)**:identity 歸
   **Pod Identity + Terraform**(已做);**所有 stateful / 有資料的資源留 Terraform**(plan
   留在最需要的地方);Crossplane 只碰**可重建、blast radius 小**的 workload 資源。那個
   沒有 plan 的引擎,永遠擁有不到一個資料庫。

收斂是**單向**的:想要 KRO 那套好寫的 authoring,日後可從 Crossplane 側用
`function-kro` 拿(內嵌、不必裝 KRO、保留 provider);反過來 KRO 拿不到 Crossplane 的
provider/on-prem。所以選 v2 不鎖死將來。

## Context

The WS3 prod dual-region cold start (2026-06-18) hit an orphaned IAM role: the
engine's IRSA role was composed **in-cluster** by Crossplane (a `WorkloadIdentity`
XRD + Composition → an upjet `iam.aws.upbound.io/Role` at the SCP-protected path
`/aegis-workload/`). Because the controller — not Terraform — owned that role, a
cluster teardown removed the controller before it reconcile-deleted the role,
orphaning it and colliding on the next cold-start apply. ADR-21 §A chose **EKS Pod
Identity** as the root-cause fix; PR #117 implemented the platform side and retired
the **entire** Crossplane v1 IRSA stack (crossplane core, `provider-aws-iam`, the
family provider, the XRD/Composition, the DeploymentRuntimeConfigs, the
`ProviderConfig`, and the `/aegis-workload/` IRSA role for the provider itself).

That retirement is correct for *identity*, but it leaves an open question for WS4
(`docs/ws4-platform-self-service-plan.md`): the plan's **Axis A** wanted to *extend*
the now-deleted `XWorkloadIdentity` pattern to author `XBucket` / `XQueue` / `XTable`
for per-workload cloud resources. With the v1 stack gone, "extend `XWorkloadIdentity`"
is no longer a valid premise. We must decide, from a clean slate, **whether Crossplane
returns at all, and if so on what terms** — without rebuilding the exact v1 machinery
whose cluster-ownership model caused the orphan.

Two facts reframe the decision versus when ADR-09 first chose Crossplane:

- **Crossplane v2 is GA** (2025-08-12; v2.3 current as of 2026-05; CNCF Graduated).
  v2 makes composite and managed resources **namespaced by default** and removes the
  cluster-scoped-XR / Claim duality. The central pain of ADR-09's fix-B — a
  cluster-scoped XR could not compose a namespaced ACK `Role`
  (`spec.resourceRefs[].namespace: field not declared in schema`) — was a **pure v1
  artifact**. In v2 a namespaced XR composes namespaced managed resources cleanly;
  that bug class disappears. v2 also removes native patch-and-transform (composition
  **functions** are now the only path) and replaces the monolithic provider with
  **provider families + Managed Resource Definitions (MRDs) gated by a Managed
  Resource Activation Policy (MRAP)**, so a cluster installs only the 10–20 resource
  types it needs instead of 100+ CRDs.
- **The upjet `provider-aws` now supports EKS Pod Identity** (`source: PodIdentity`),
  not only IRSA. A re-introduced provider pod gets its credentials with a fixed
  `pods.eks.amazonaws.com` trust principal — no per-cluster OIDC threading, and **no
  `/aegis-workload/` IRSA role + SCP carve-out**, the exact construct that orphaned at
  teardown.

## Decision

### 1. Crossplane v2 is the engine for workload-scoped cloud resources — justified by scenario, not scale

The gating condition for whether a platform should run Crossplane is **(real
multi-cloud intent) × (a dedicated platform role to own the abstraction)** — not the
number of workloads. aegis has both: the multi-cloud + on-prem replica is an explicit
goal (ADR-16), and the four-repo model (`platform` / `service` / `service-deploy`)
assumes a dedicated platform engineer. A platform with 1–3 workloads still passes this
gate; "premature at this scale" was the wrong test — scale is not the gate, scenario
is. (This supersedes the earlier "Crossplane is premature for 1–3 workloads" framing.)

The **decisive design criterion** (Bin): *multi-cloud complexity belongs to the
platform engineer, not the backend engineer.* The corollary is the honest escape
hatch — **if an organization is willing to push cloud detail down to backend
developers, it should bind to a single cloud and build directly around that cloud's
native blocks; a provider-neutral abstraction is pure overhead for a single-cloud
shop.** aegis chooses multi-cloud, so the complexity must live at the platform layer,
behind a cloud-neutral API the app teams declare against. Only a tool with all three
layers delivers that.

### 2. Identity is owned by EKS Pod Identity + Terraform — NOT Crossplane

ADR-21 §A is now the identity mechanism: Terraform owns the IAM role
(`aegis-core-engine-<region>`, region-suffixed, standard path `/`) and an
`aws_eks_pod_identity_association` binds it to the namespace/ServiceAccount. The role
is destroyed cleanly with the stack — no orphan, no `/aegis-workload/`, no
cross-teardown race. **This amends ADR-09**: `XWorkloadIdentity` is no longer the
identity primitive. Crossplane never re-owns identity.

### 3. Stateful / data-bearing resources stay in Terraform

Crossplane's one decisive weakness is the lack of a `plan` / dry-run, and a documented
history of **silently deleting resources during XRD/provider upgrades** (Eficode,
2025). We bound that blast radius by rule, not hope: **only rebuildable, small-blast
workload resources are Crossplane claims** (an empty bucket, a queue, a table). Every
stateful or data-bearing resource — RDS-class, anything whose deletion loses data —
**stays in Terraform**, where `plan` exists. The no-plan engine therefore never owns a
data store. This keeps ADR-09's promotion triggers as the hard valve.

### 4. When Crossplane returns (WS4), it is v2-native

- **Namespaced XRs** (the fix-B namespace fight is gone in v2).
- **Composition functions** only; the function-pod `DeploymentRuntimeConfig`
  `securityContext` is IaC'd from the start (the fix-B #2a PSA-vs-function-pod gap is
  more central in v2 — every composition rides the function runtime).
- **Provider family + an explicit MRAP** allow-listing only the resource types we use
  (no CRD explosion).
- **Provider pod credentials via EKS Pod Identity** (`source: PodIdentity`), not the
  retired `/aegis-workload/` IRSA role.
- Validated with `crossplane render` + `crossplane beta validate` in CI, then on local
  Talos (composition swap to the on-prem provider), then on staging — never a prod
  debut.

## Options considered

| Option | What it is | Why not (for aegis) |
|---|---|---|
| **Crossplane v2** (chosen) | composition (XRD) + provider (upjet MR) + lifecycle, CNCF Graduated | — the only tool with all three layers **and** an on-prem path |
| **tofu-controller** (flux-iac) | reconcile OpenTofu in-cluster, GitOps, **keeps `terraform plan`** as a git-approval gate | The one rival that beats Crossplane on `plan` — but it is **module-per-cloud with no shared CRD**: it gives app teams no cloud-neutral declaration, pushing per-cloud detail back toward the requester. **Fails the decisive criterion.** |
| **KRO** (Kube Resource Orchestrator) | a composition/orchestration layer (RGD + SimpleSchema + CEL) | Only **~1/3 of Crossplane's stack** — the composition layer. It makes **zero cloud API calls**; provisioning requires ACK/KCC/ASO underneath. **No on-prem/MinIO path** (ACK is AWS-only). No `deletionPolicy`/import lifecycle controls. Still `v1alpha1` (v0.9.2), AWS labels it "not for production", no formal CNCF status. Cannot remove Crossplane from aegis's stack — the on-prem replica needs Crossplane providers regardless. |
| **Kratix** | promise-based platform API + multi-cluster scheduling | Targets large multi-team orgs; delegates provisioning to a backend anyway. Overkill for 1–3 workloads. |
| **Plain Terraform / OpenTofu** (no controller) | strongest `plan`, largest provider ecosystem | **No app-facing Kubernetes abstraction** — app teams cannot self-declare against a neutral API. Retained for substrate + stateful (decision 3), not for the app-facing layer. |
| **Single cloud + native blocks** (CDK/ACK direct) | drop multi-cloud; embrace one cloud's primitives | The honest alternative *if* the multi-cloud goal were abandoned. aegis keeps the goal, so this is rejected — but it is the correct posture for a single-cloud org and is recorded so the trade is explicit. |

### The convergence is one-directional (why v2 is not a lock-in)

`function-kro` (crossplane-contrib, v0.3.0, 2026-03) embeds KRO's RGD / SimpleSchema /
CEL authoring **inside a Crossplane composition pipeline** — natively, with no need to
install KRO — while keeping Crossplane's provider and lifecycle layers; existing KRO
RGDs drop in unchanged. The reverse (KRO consuming Crossplane's full value) does not
exist. So if we later want KRO's lighter authoring ergonomics, we get them **from the
Crossplane side**. Choosing v2 now forecloses nothing.

## Consequences

- WS4 `docs/ws4-platform-self-service-plan.md` is revised: Axis A drops the
  "extend `XWorkloadIdentity`" premise (identity left Crossplane); the
  Terraform↔Crossplane boundary (§5) flips the identity row to Pod Identity and adds
  the stateful-stays-in-TF rule; the scoreboard (§6) adds the tofu-controller / KRO /
  Kratix evaluations.
- The two dormant `WorkloadIdentity` Kyverno ClusterPolicies left by PR #117 match
  kinds that no longer exist (inert). WS4 either prunes them or re-purposes them for
  the v2 XRs.
- The `/aegis-workload/` SCP carve-out in `aegis-aws-landing-zone` is now unused by
  this repo (no principal creates roles under that path). A fabric follow-up can
  remove it; the pre-existing orphan role from ADR-21 §A.5 still needs its break-glass
  cleanup.
- **Open validation (WS4 owns the proof):** (a) the v2 namespaced-XR → workload
  managed-resource path is clean for S3/SQS on a live cluster; (b) the on-prem
  `provider-minio` (community) genuinely fits the provider-neutral seam ADR-16
  imagines — if it does not, the on-prem object-storage path falls back to the
  injection layer, not Crossplane. Both are unverified at the time of writing and are
  the reason this ADR is Proposed, not Accepted.

## Relationship to prior ADRs

- **ADR-09** (platform-as-product XRD): amended — identity is no longer an
  `XWorkloadIdentity` claim; the default-ownership rule and the five promotion
  triggers stand for *non-identity* workload cloud resources.
- **ADR-16** (provider-neutral): upheld — the AWS-upjet vs on-prem-MinIO Composition
  swap is the provider-neutral seam; v2 keeps it, pending the `provider-minio`
  validation above.
- **ADR-21** (WS3 forward-fixes): §A (Pod Identity) is the identity mechanism this ADR
  builds the boundary around.

## References

- [Announcing Crossplane 2.0](https://blog.crossplane.io/announcing-crossplane-2-0/) — 2025-08-12 (namespaced XRs, P&T removal, families + MRDs)
- [Crossplane v2 what's new](https://docs.crossplane.io/latest/whats-new/) — v2.3, 2026-05
- [Crossplane managed resources — lifecycle controls](https://docs.crossplane.io/latest/concepts/managed-resources/) (deletionPolicy, management policies, external-name, import)
- [function-kro: YAML+CEL composition meets Crossplane](https://blog.crossplane.io/function-kro-yaml-cel/) — 2026-03-19; [repo](https://github.com/crossplane-contrib/function-kro)
- [Introducing open-source kro](https://aws.amazon.com/blogs/opensource/introducing-open-source-kro-kube-resource-orchestrator) — 2024-11-12 ("not yet intended for production use"); [kro.run](https://kro.run/docs/overview/) (v0.9.2, `v1alpha1`)
- [CNCF: Building platforms using kro for composition](https://www.cncf.io/blog/2025/12/15/building-platforms-using-kro-for-composition/) — 2025-12-15 (kro is single-cluster composition, not provisioning)
- [flux-iac/tofu-controller](https://github.com/flux-iac/tofu-controller) (v0.16.4, 2026-06; `approvePlan` git-approval gate)
- [Crossplane is great, but what about critical infrastructure?](https://www.eficode.com/blog/crossplane-is-great-but-what-about-critical-infrastructure) — Eficode, 2025-05 (no plan / silent deletion on upgrade)
- [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html); [Upbound provider-aws authentication](https://docs.upbound.io/providers/provider-aws/authentication/) (`source: PodIdentity`)
- ADR-09 `docs/adr/09-platform-as-product-xrd.md` · ADR-16 (provider-neutral) · ADR-21 `docs/adr/21-*.md`
