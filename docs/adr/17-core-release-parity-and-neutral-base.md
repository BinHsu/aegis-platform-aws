# ADR-17: aegis-core release-model parity + provider-neutral base (WS1)

## Status

Accepted. Repo work (WS1 steps 1–4) done 2026-06-16; live local-Talos proof
(WS1-5) and the deferrals below tracked separately.

## Context

WS0 proved the platform↔workload injection contract is provider-neutral on a
local Talos target, with greeter (ADR-16). WS1 brings `aegis-core` /
`aegis-core-deploy` to the same ADR-10 release-model level and makes its deploy
base provider-neutral, so the local-first sequencing (WS0→WS3) holds for the
real workload too.

Two facts shaped the work, both discovered by reading the live repos (the
2026-06-12 runbook's framing was stale):

1. **The "direct-push→PR-bump" blocker is already solved.** `aegis-core`'s
   `release-staging-image.yml` already bumps `aegis-core-deploy` via
   branch→`gh pr create`→`gh pr merge --auto --squash` (the greeter pattern).
   No work needed.
2. **aegis-core is a Bazel monorepo building TWO images** (`gateway_go`,
   `engine_cpp`) that share ONE name `aegis-core`, distinguished by tag prefix,
   via `rules_oci`. The workloads are Argo **Rollout** CRDs, not Deployments.

## Decision

### Scope (operator decisions, 2026-06-16)

- **Local-first.** WS1 proves core against local Talos using a **local
  registry**; the ECR/OIDC pipeline is WS3 (decision A).
- **Pipeline + neutral overlay, not full serve.** WS1 proves the digest
  promotion pipeline + the neutral injection contract applies on Talos (images
  pull, manifests admitted). A fully-serving core — needing identity/storage/
  auth substitutes — is WS2 (decision B).

### Provider-neutral base via kustomize Components

The AWS-specific resources moved out of `k8s/base` into
`k8s/components/aws-binding` (a kustomize Component): the ALB Ingress, both
ServiceMonitors, the `iam/` WorkloadIdentity XR, and the engine SA's IRSA marker
annotation. `overlays/staging` and `overlays/prod` include that component;
`overlays/talos` does not. The base now renders zero AWS-kind resources.

This makes AWS an **additive binding** (ADR-16's language) rather than the
default the on-prem target subtracts from. The payoff: the Talos overlay is
purely additive (it adds a Gateway API HTTPRoute) — no `$patch: delete`, unlike
greeter's talos overlay whose base still carried an ALB Ingress. staging/prod
render **byte-identical** before and after the refactor (verified).

### Digest pinning for Rollouts (ADR-10/14)

Greeter uses kustomize's `images:` transformer. **Core cannot**: the `images:`
transformer does not reach a Rollout CRD, and it matches by image *name* — so it
could not give the gateway and engine (both named `aegis-core`) distinct
digests. Therefore each overlay pins per-resource digests with **JSON6902
patches** (`/spec/template/spec/containers/0/image = aegis-core@sha256:<digest>`),
and the existing registry replacement switches its delimiter from `:` to `@` to
splice the platform-injected registry in front of the digest. The seed Job
carries the SAME digest as the engine Rollout (ADR-14). Base images are bare
`aegis-core` (the standalone-build default); the digest lives in the overlay so
staging and prod can pin different digests across a promotion.

`validate.yml` migrated to enforce: (A) every image is `aegis-core@sha256:<64-hex>`,
(B) the injected registry splices before the digest, (C) seed==engine digest,
(D) prod promotions move both digests together or neither (ADR-14 atomicity).

## Consequences / deferrals

Everything WS1 does NOT do, and which workstream owns it (recorded explicitly
per the 2026-06-16 instruction that deferrals be documented in committed
artifacts, not chat):

| Deferred item | Owner | Why not WS1 |
|---|---|---|
| `aegis-core` CI bump: rewrite tag→digest, write into the overlay | **WS3** | The bump rides the ECR/OIDC pipeline (decision A → WS3). Editing an un-activatable CI now is untestable. Until WS3 the overlay digests are placeholders and `validate.yml` enforces only the `@sha256` *shape*. |
| ECR push + OIDC role assumption (`github-actions-aegis-core-ecr`) | **WS3** | AWS binding; needs operator `make bootstrap` + deployment-account ECR. |
| Engine identity (IRSA → SPIFFE/SPIRE or sealed-secret) | **WS2** | The deepest axis; greeter had no identity need so WS0 never proved it. Proven against core's real need in WS2. |
| Object store (S3 → MinIO), gateway auth (Cognito → Keycloak/Dex) | **WS2** | core-specific on-prem substitutes; required for a fully-serving core. |
| On-prem metrics (ServiceMonitor → Alloy/OTel) | **WS2** | The ServiceMonitor (kube-prometheus-stack CRD) is in `components/aws-binding`; the Talos target has no equivalent yet. |
| Live, fully-serving core on Talos | **WS2** | WS1 proves pipeline + neutral overlay only (decision B). |
| Frontend (S3/CloudFront, `release-staging-frontend.yml`) | **ADR-15** | Non-OCI artifact class, out of the ADR-10 release model. |
| Live local-Talos render/apply proof (images pull, manifests admitted) | **WS1-5** | The cluster step of WS1 itself; run after the repo work. |

## WS1-5 live proof (local Talos, 2026-06-16)

Decision B's bar — images pull + manifests admitted, not full serve — met on a
local Talos cluster (apple/container):

- **Gateway built locally** via Bazel `rules_oci` (`//packaging/gateway:image`,
  177s) and pushed to the in-cluster registry (the OCI layout was deref-copied,
  tarred, `container image load`-ed, and `container image push --scheme http`-ed,
  because `:push_staging` is linux-only and won't run on the macOS host).
- **Injection contract live on core**: after `kubectl apply -k overlays/talos`
  with the platform `commonAnnotations` injecting the LOCAL registry, the
  deployed gateway + engine Rollouts and the seed Job all carry
  `192.168.64.32:5000/aegis-core@sha256:<gateway-digest>` — the local registry
  spliced in front of the real digest, seed == engine. Same mechanism as the EKS
  overlays, different injected value. Proven on a real cluster, not just render.
- **Manifests admitted**: both Rollouts, both Services, both NetworkPolicies, the
  seed Job, the two ServiceAccounts, and the HTTPRoute (`aegis-core.local` →
  `aegis-core-gateway:8080`, Gateway API) all created.
- **Image pulls + runs**: the gateway image pulled from the local registry and
  its container Created+Started on Talos (it then exits without runtime config —
  expected; full serve is WS2).

Substrate caveats (not contract concerns):
- The **C++ engine was not built locally** (cross-toolchain cost on macOS);
  engine + seed used the gateway image as a stand-in (decision B). Building the
  engine image is part of WS2's full bring-up.
- The **Argo Rollouts controller** could not schedule on the tmpfs-backed nodes
  (insufficient ephemeral-storage; the same 16 GB-host substrate limit ADR-16
  recorded), so no Rollout-managed pods — the image-pull proof used a direct Pod.
- The **kyverno ClusterPolicy** could not be admitted (kyverno not installed —
  a cluster dependency, not provider-specific). Workload + route resources admit
  without it.

## References

- ADR-10 (build once, promote by digest), ADR-12 (registry injection vs
  digest-pin field ownership), ADR-14 (multi-image atomic promotion), ADR-16
  (provider-neutral injection contract, WS0).
- `aegis-core-deploy` branch `ws1/neutralize-base-and-digest`
  (`k8s/components/aws-binding`, `k8s/overlays/talos`, `validate.yml`).
- WS1 epic: `aegis-platform-aws` issues #44–#47 (`post-612-roadmap`).
