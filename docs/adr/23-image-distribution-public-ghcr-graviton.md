# ADR-23: aegis-core image distribution — public GHCR on Graviton

## Status

Accepted (2026-06-20). **Supersedes [ADR-10](10-release-model-build-once-promote-by-digest.md)**
(shared release registry in a dedicated AWS Deployment account) and
**supersedes [ADR-12](12-registry-injection-vs-digest-pin-field-ownership.md)
for aegis-core only** (the platform no longer injects the registry for
aegis-core). Depends on the node-arch switch to Graviton
(`feat(regional): switch managed node group to Graviton (arm64 t4g)`). Greeter is
unaffected and stays on ECR with ADR-10/12 intact.

## Context

ADR-10 put the shared release registry in a dedicated AWS Deployment account
(Deployments OU): build the image once, promote the immutable artifact by digest,
serve every environment from one cross-account ECR. ADR-12 then split field
ownership — the deploy repo pins the digest, the platform injects the
`<account>.dkr.ecr.<region>.amazonaws.com/<repo>` registry prefix as an
annotation, because the account id stays out of public deploy repos and only the
cluster knows which account/region it pulls from.

Two facts broke that model for aegis-core.

1. **The shared ECR had a single owner, and that owner was destroyed.** The
   deployment-account ECR was provisioned and torn down on the staging gate
   (`local.deployment_enabled`). The 2026-06-20 staging teardown destroyed it.
   Prod's image supply then pointed at a registry that no longer existed — a
   cross-account dependency where one environment's teardown can break another's
   cold start. The build-once / promote-by-digest invariant was sound; the
   *registry topology* coupled prod to staging's lifecycle.

2. **aegis-core already ships arm64 images to a public registry.** WS2's on-prem
   work publishes `linux/arm64` aegis-core engine + gateway images to public
   GHCR via `release-onprem-image.yml`, for forkers running Talos on arm64. AWS
   prod was about to run Graviton (t4g) nodes (also arm64) for the ~20% node
   saving. The exact same image already exists, public, and runs on the prod
   node architecture. Standing up a second cross-account ECR copy of bits that
   already exist publicly is ceremony, not isolation.

## Decision

**Distribute aegis-core images via public GHCR; pull the same arm64 image
on-prem and on AWS prod.**

- **Registry.** `ghcr.io/binhsu/aegis-core-engine` and
  `ghcr.io/binhsu/aegis-core-gateway`, public. The build is the existing
  `release-onprem-image.yml` — no new AWS-side build or push.
- **Architecture — single-arch, not multi-arch.** Images are `linux/arm64`
  only. AWS prod runs Graviton (`t4g.large`, `AL2023_ARM_64_STANDARD`); on-prem
  forkers run arm64 Talos. There is no x86 consumer, so a multi-arch manifest
  list would carry an unused amd64 half. The platform addon stack was verified
  arm64-clean (all 10 helm charts + 4 EKS managed addons are multi-arch; every
  digest/tag-pinned helper — `alpine/k8s`, `public.ecr.aws/aws-cli`,
  `curlimages/curl` — and the 3 Crossplane packages resolve to a manifest list
  carrying `linux/arm64`), so nothing on the node needs amd64.
- **Static refs — the platform stops injecting the registry for aegis-core.** A
  GHCR ref has no account id and no region (`ghcr.io/binhsu/aegis-core-engine` is
  the same string in every account and region). The reason the platform injected
  the ECR prefix — to keep account ids out of public repos and let each cluster
  name its own account/region — does not apply to a static public ref. The
  aegis-core overlays carry the full GHCR ref directly. This supersedes ADR-12
  **for aegis-core**: the `aegis.binhsu.org/ecr-repository` annotation injection
  no longer applies to it. Greeter keeps the ADR-12 annotation channel.
- **Digest-promotion model is preserved.** "The bits staging verified are the
  bits prod runs" (ADR-10's core invariant) is unchanged. Both overlays pin the
  **same digest** (`ghcr.io/binhsu/aegis-core-engine@sha256:…`); promotion is
  still copying the staging-verified digest into the prod overlay, gated by the
  `prod` Environment. What changed is the registry hostname, not the promotion
  contract or the per-image atomic-promotion rule (ADR-14 still holds: the
  gateway and engine digests move together or neither).
- **Root of trust moves external to AWS.** A public git repo's images now live
  in a public registry. The owner accepts this: the source is already public, so
  a public artifact registry does not widen what an attacker can read. It does
  move the supply-chain root of trust outside the AWS org boundary (loss of
  SCP/org governance and ECR tag immutability over the registry).

## Consequences

- **`deployment-ecr.tf` stays `count = 0` inert.** No aegis-core ECR repo, no
  cross-account pull policy, no `aegis-deployment` dependency on the aegis-core
  path. The greeter ECR resources are untouched.
- **`github-actions-aegis-core-ecr` push role is obsolete and deletable.** It
  pushed aegis-core images to the per-account/shared ECR; GHCR distribution
  removes its only consumer. It is a deliberate orphan with no `.tf` home — the
  prod-cold-start IAM survivor-import work leaves it alone (not adopted) so a
  later cleanup PR can delete it.
- **Node group switched to Graviton.** `ami_type` →
  `AL2023_ARM_64_STANDARD`, `node_instance` → `t4g.large` in both regions
  (the node-arch commit). The addon stack was verified arm64-clean as a
  precondition.
- **Greeter unaffected.** Greeter keeps its per-account ECR, the ADR-12 registry
  annotation, and ADR-10's promote-by-digest. This ADR narrows only the
  aegis-core distribution path.
- **No cross-account ECR ownership dance for aegis-core.** No
  `gh-tf-apply-deployment` role, no cross-account repository policy enumerating
  cluster accounts, no replication for a second-region ECR copy on the
  aegis-core path.

### Trade-off vs ADR-10

| | ADR-10 (shared AWS ECR) | ADR-23 (public GHCR) |
|---|---|---|
| Governance | inside the AWS org — SCP, org guardrails apply | external — no SCP/org control over the registry |
| Immutability | ECR `IMMUTABLE` tags | GHCR tags mutable; **digest pin is the only immutability guarantee** |
| Egress | cross-account, in-AWS | free public pull, no NAT/data-transfer for the image |
| Node cost | x86 (t3) | arm64 Graviton (t4g), ~20% cheaper |
| Coupling | prod ECR coupled to the staging-owned deployment account | none — static public ref, no per-env owner |
| Ownership | cross-account ECR + push-role + pull-policy choreography | none — reuse the on-prem image |

We **lose** AWS-org/SCP governance and ECR tag immutability over the registry; we
**gain** simplicity (no cross-account ECR ownership dance), free egress, cheaper
arm64 nodes, and decoupling from the staging-owned deployment account. The digest
pin — not tag immutability — carries the provenance guarantee, so the security
loss is bounded to "the registry host is outside the org" rather than "an
artifact can be silently swapped under a pin".

## Forker note: switching to amd64

The repo ships arm64 by default (Graviton t4g nodes, `linux/arm64` GHCR images).
A forker targeting x86 must flip three knobs — **all three must move together** or
the cluster starts with a node/image arch mismatch:

| # | File | Field | arm64 value (default) | amd64 value |
|---|------|--------|-----------------------|-------------|
| 1 | `terraform/modules/regional-stack/eks.tf` | `ami_type` | `AL2023_ARM_64_STANDARD` | `AL2023_x86_64_STANDARD` |
| 2 | `regions.auto.tfvars.json` | `regions.<region>.node_instance` | `t4g.large` | `t3.large` (or any x86 family) |
| 3 | `aegis-core-deploy` — `k8s/overlays/<env>/kustomization.yaml` | image digest pins | `ghcr.io/binhsu/aegis-core-{engine,gateway}@sha256:…` (arm64) | amd64 image digest — requires an amd64 build |

**Knob 3 caveat.** The image digest pins live in `aegis-core-deploy`, not this
repo. The published `ghcr.io/binhsu/aegis-core-{engine,gateway}` images are
`linux/arm64` only — an amd64 forker must build and publish their own amd64
images (or a multi-arch manifest list) and update the overlay digest pins in
`aegis-core-deploy` accordingly.

**Clean long-term fix — multi-arch image index (Slice-3).** Publish a manifest
list (`docker buildx build --platform linux/amd64,linux/arm64`) so both
architectures share one digest-pinnable image ref. A forker then changes only
knobs 1 and 2 (compute) and the correct image variant is pulled automatically —
no overlay surgery, no separate build path. This is the recommended future
direction; single-arch arm64 was shipped first because there was no x86 consumer
at the time (ADR-23 Decision section).

## Related

[ADR-10](10-release-model-build-once-promote-by-digest.md) (superseded — release
registry topology) ·
[ADR-12](12-registry-injection-vs-digest-pin-field-ownership.md) (superseded for
aegis-core — registry injection) ·
[ADR-14](14-multi-image-atomic-promotion.md) (still holds — both aegis-core
digests promote atomically) ·
the node-arch commit `feat(regional): switch managed node group to Graviton
(arm64 t4g)`.
