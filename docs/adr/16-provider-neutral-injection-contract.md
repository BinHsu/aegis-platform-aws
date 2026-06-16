# ADR-16: Provider-neutral injection contract

## Status

Accepted. Proven on a local Talos target (WS0, 2026-06-16).

## Context

ADR-07 (D3, region injection) and ADR-10/ADR-12 (registry injection vs digest
pinning) defined how the platform hands a workload its environment-specific
values: the platform injects two generic annotations and the workload's own
kustomize overlay consumes them.

- `aegis.binhsu.org/region` — the serving region.
- `aegis.binhsu.org/ecr-repository` — the image's registry/repository URL,
  spliced into the image's repo part by a `replacements` rule with delimiter
  `@`, so the digest pinned in the overlay's `images:` block survives.

The platform sets both as `kustomize.commonAnnotations` (an ApplicationSet does
this per cluster); the workload overlay declares no value for those keys and
reads them through replacements. The platform never learns the workload's
internal deployment/container/route names.

That contract was only ever exercised against EKS — the `ecr-repository` value
was always an ECR URL, the region an AWS region. The open question: is the
contract genuinely **provider-neutral**, or does "registry injection" quietly
mean "ECR injection" and "region" quietly mean "AWS region"? If AWS is wired in
below the annotation, the local-first sequencing (WS0→WS3) collapses — on-prem
would be a retrofit, not a target.

## Decision

**The injection contract is the platform↔workload boundary, and it is
target-neutral by construction.** A target is fully described by the two
injected annotation values plus a per-target overlay that swaps target-specific
resources (ingress mechanism, etc.). AWS is one target among many, bound by an
*additive* overlay — never the default the others retrofit around.

WS0 proved this on a local Talos cluster (apple/container substrate) by adding a
`talos` overlay to `aegis-greeter-deploy` that reuses the **same base** and the
**same replacements** as the staging/prod overlays. The only differences are the
injected values and one swapped resource:

- `ecr-repository` injected as a **local registry** URL (`<host>:5000/aegis-greeter`),
  not an ECR URL. On-prem has no ECR, so greeter is built locally and pushed to
  an in-cluster registry; the overlay pins that locally-built digest.
- `region` injected as `local-talos`, not an AWS region.
- The AWS-ALB `Ingress` is dropped (`$patch: delete`) and replaced by a Gateway
  API `HTTPRoute` (Envoy Gateway). Swapping the ingress mechanism per target is
  the per-target overlay's job; the base is untouched.

Everything else — the Deployment, the digest-pin mechanism, the region/registry
replacements — is byte-for-byte the base and the shared replacement rules.

## Consequences

- **Verified end to end.** Host → Envoy Gateway (Gateway API HTTPRoute) →
  greeter returned `HTTP 200`; a non-matching host returned `404` (real host
  routing). The running Deployment's image was the injected local-registry URL
  at the pinned digest, and the greeting body read
  `... [local-talos]` — the injected region reached the app's runtime behavior,
  not just the manifest. The contract holds across all the axes greeter can
  exercise.
- **The identity axis is NOT proven here.** The contract's deepest axis is
  workload identity (AWS IRSA → on-prem SPIFFE/SPIRE or sealed-secret). greeter
  is so minimal it has no identity need, so WS0 cannot exercise it. That axis
  first lands in WS2 with `aegis-core`, which has a real identity requirement —
  proven against a real need, not a synthetic one. Until then, "provider-neutral"
  is established for registry + region, asserted (not yet proven) for identity.
- **Registry is on-prem-honest.** Pulling the image from ECR would force an AWS
  credential as an `imagePullSecret` onto the on-prem cluster — the exact hidden
  cloud coupling WS0 exists to expose. A local registry keeps the execution
  cluster free of AWS credentials. A self-hosted Harbor (auth, RBAC, scanning)
  is a later air-gap refinement; WS0 used a plain `registry:2`.

### Substrate findings (apple/container Talos, 16 GB host)

These are properties of the dev substrate, not the contract — recorded so the
next run does not re-discover them.

- **GitOps delivery is structurally proven; live ArgoCD reconciliation is
  storage-constrained on this host.** The ArgoCD `Application` was authored and
  the `commonAnnotations` injection was verified to render the identical
  artifact a direct `kustomize build` produces. But Talos nodes on
  apple/container run `/var` on tmpfs (RAM-backed — the documented "no
  cross-restart survival" tradeoff), so ArgoCD's image plus git clones exhaust
  node ephemeral storage, triggering a disk-pressure eviction loop. On a 16 GB
  host already swapping, neither a 2 GB worker nor a 4 GB control-plane sustains
  the full GitOps control plane alongside Envoy + MetalLB + the workload.
  greeter was therefore delivered with `kubectl apply -k` of the **same overlay
  artifact** ArgoCD would render. Running ArgoCD here needs a larger host,
  persistent disk for `/var`, or a lighter agent — none of which change the
  contract.
- **MetalLB L2 host-reachability holds (verified 2026-06-14) but does not
  survive sustained node pressure.** After hours of churn the MetalLB speaker
  crash-looped and stopped announcing the VIP. The acceptance curl was taken via
  the Envoy proxy's NodePort instead, which exercises the same
  Gateway→HTTPRoute→Service→pod path. The VIP path is a substrate concern, not a
  routing-contract concern.

## References

- ADR-07 (region injection, D3), ADR-10 (build once, promote by digest),
  ADR-12 (registry injection vs digest-pin field ownership).
- `aegis-greeter-deploy` `k8s/overlays/talos/` (branch `ws0/talos-overlay`).
- WS0 epic: `aegis-platform-aws` issues #44–#47 (`post-612-roadmap`).
