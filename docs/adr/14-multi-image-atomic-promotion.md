# ADR-14: Multi-image atomic promotion — two digests move as one unit

## Status

Proposed (operator sign-off pending). Extends
[ADR-10](10-release-model-build-once-promote-by-digest.md) (build once, promote
by digest) to a workload that ships **more than one image**, and depends on
[ADR-12](12-registry-injection-vs-digest-pin-field-ownership.md) (the overlay
owns the image pin; the platform injects only the registry).

## Context

ADR-10 modelled the single-image case: greeter ships one image, the overlay
carries one digest, promotion copies that one digest into the prod overlay. That
was the **carrier** — the thing under test was the promotion machinery, not the
workload.

`aegis-core` is the **real workload**, and it breaks the one-image assumption.
Today's audit of `aegis-core-deploy`:

- **Two images, one ECR repo.** `aegis-core` ships a **gateway** image and an
  **engine** image. Both live in a single ECR repository named `aegis-core`,
  distinguished only by **tag prefix**: the gateway is `staging-<sha>`, the
  engine is `engine-staging-<sha>`.
- **Three image-bearing manifests, two distinct images.** The gateway Rollout
  carries the gateway tag; the engine Rollout **and** the engine seed Job both
  carry the engine tag (the seed Job is pinned to the same SHA as the engine
  Rollout — it runs `engine seed --target=cloud` as a `PostSync` hook).
- **Mutable tags, not digests.** Both images are pinned by **mutable tag**
  (`engine-staging-6995fab…`), the pre-ADR-10 state. ADR-10's target is a
  content digest (`@sha256:…`); core has not migrated.
- **The staging bump is already commit-atomic.** `aegis-core` CI's
  `bump-image-tag` job rewrites the gateway Rollout tag and the engine
  Rollout + seed Job tags **in one commit** (three `yq` edits, one push). The
  per-manifest rewrite is real, but the unit of change is already a single git
  commit.

The new hazard is **cross-image consistency at promotion**. A prod cluster
running `gateway-D_new` against `engine-D_old` is not "mostly deployed" — it is
an **invalid deployment**: the gateway and engine share a wire contract, and a
half-promoted pair is exactly the skew the build-once model exists to prevent.
ADR-10's "copy the staging-verified digest" must become "copy the
staging-verified **set of digests**, all or nothing".

## Decision

**Pin each image by its own digest in the overlay; promote both digests in one
commit; CI asserts the pair moves together; rollback reverts that one commit.**

### (a) Two digest pins, one atomicity unit

The overlay carries **two** digest pins — one for the gateway image, one for the
engine image — mirroring greeter's single pin **×2**:

```text
# overlays/<env> image pins (digest, per ADR-10)
aegis-core (gateway) → aegis-core@sha256:<gateway-digest>
aegis-core (engine)  → aegis-core@sha256:<engine-digest>   # engine Rollout + seed Job
```

The seed Job consumes the **engine** digest — it is the same artifact as the
engine Rollout, so it is the same pin, not a third one. There are two distinct
images, therefore two pins.

The **atomicity unit is the git commit / PR**, exactly as in ADR-10 — the build
model does not add a new transactional primitive. Greeter promoted one digest in
one commit; core promotes two digests in one commit. The commit is the
all-or-nothing boundary git already gives us; we do not invent a manifest
transaction on top of it.

### (b) One ECR repo by tag prefix, or two ECR repos — keep one repo

Two images can live in **one ECR repository keyed by tag prefix** (current
state) or in **two ECR repositories** (`aegis-core-gateway`,
`aegis-core-engine`). We weighed:

- **IAM scoping.** Two repos let the gateway push role and the engine push role
  be scoped to disjoint repositories. But `aegis-core` is **one build repo with
  one CI push identity** — both images are built and pushed by the same
  workflow under one OIDC role (ADR-10's per-workload push role). There is no
  second principal to isolate, so the finer IAM grain buys nothing here.
- **Lifecycle policies keyed on tag prefix.** ECR lifecycle policies match on a
  `tagPrefixList`, so a single repo expresses "keep N most-recent `staging-*`"
  and "keep N most-recent `engine-staging-*`" as **two rules in one policy** —
  the prefix model is a first-class lifecycle dimension, not a workaround.
- **ADR-10's lean.** ADR-10 says "one ECR repository **per workload**", not per
  image. `aegis-core` is one workload (one deploy repo, one ApplicationSet
  entry, one promotion unit). One repo per workload keeps the registry topology
  aligned with the promotion topology — the thing that moves as a unit lives in
  one place.

**Decision: keep the single `aegis-core` repository, tag-prefix model.** It
matches ADR-10's per-workload lean, the lifecycle policy expresses both prefixes
cleanly, and there is no second push principal to isolate. Two repos are the
named fallback if the gateway and engine ever split into separate build repos
with separate push identities — at which point they are two workloads, not one,
and ADR-10's per-workload rule lands them in two repos by its own logic.

### (c) The promotion PR shape — both digests, or neither

A prod release copies **both** staging digests into `overlays/prod` in **one
commit**:

- The promotion job (or hand-authored PR) reads the gateway digest **and** the
  engine digest from the staging overlay and writes both into the prod overlay.
- `validate.yml` asserts the pair moves as a unit: on a promotion PR touching
  `overlays/prod`, **either both image digests differ from prod's current
  pins, or neither does**. A PR that bumps one digest and leaves the other
  stale **fails the check** — this is the structural guard against the
  `gateway-D_new` / `engine-D_old` skew. (The check compares the PR's prod pins
  against the base-branch prod pins; a one-image bump is the failure case it
  exists to catch.)
- The seed Job pin is **derived from** the engine pin, not promoted
  independently — `validate.yml` also asserts the seed Job's image equals the
  engine Rollout's image (they are the same artifact; a divergence is a bug).

### (d) Rollback = revert the one promotion commit

Because both digests landed in one commit, rollback is `git revert` of that
single commit: both pins return to the prior pair atomically, ArgoCD auto-syncs
prod back to the last-known-good **set**. There is no partial rollback to reason
about — the unit that rolled forward is the unit that rolls back.

## Alternatives considered

- **Image-list manifest file as a single artifact pointer.** A
  `release.json` / `images.yaml` in the overlay listing both digests, promoted
  as one file. Rejected as redundant: the two `images:` entries in the overlay
  **already are** that list, and kustomize already consumes them. A separate
  pointer file adds a second source of truth that can drift from the manifests
  it is supposed to summarize. The atomicity we need is the commit, not a
  bespoke file format.
- **OCI image index wrapping both images.** Publish a single OCI index
  (`application/vnd.oci.image.index.v1+json`) referencing the gateway and engine
  manifests, promote the index digest. Genuinely atomic at the registry layer,
  but it conflates two **independently-scheduled** images (gateway Rollout vs
  engine Rollout + seed Job are separate Kubernetes workloads) into one
  multi-arch-style artifact they are not. Kustomize would then have to unwrap the
  index to pin each container, re-introducing per-image references — the index
  buys atomicity we already get from the commit, at the cost of a packaging
  layer that fights the deployment model. Reconsider only if core grows to many
  images where a single index is genuinely simpler than an N-entry overlay.
- **Separate promotions with a compatibility matrix.** Promote gateway and
  engine independently, gate each against a tested-compatibility matrix.
  Rejected: this is the **failure mode** (independent movement) plus a manual
  ledger to compensate for it. The whole point is that the pair is one
  deployment; a matrix institutionalizes the skew instead of forbidding it.

## Consequences

- **Overlay gains a second digest pin.** `overlays/prod` (and the staging
  overlay ADR-10 introduces) carries gateway and engine digests; the
  ADR-12 registry-annotation replacement applies to **both** image references
  (the `@`-delimited replacement runs once per image — two replacements, same
  mechanism).
- **`validate.yml` gains the move-together assertion** (b/c above): both-or-
  neither on prod pins, plus seed-Job-equals-engine-Rollout. This is the
  concrete enforcement of "two digests, one unit".
- **WS1 migration: mutable tags → digest pins is a core-repo workflow change.**
  `aegis-core` CI's `bump-image-tag` job currently writes mutable tags
  (`engine-staging-<sha>`) into three manifests. WS1 changes it to capture each
  image's **digest** at push (`docker buildx --metadata-file` / `crane digest`)
  and write `@sha256:…` into the staging overlay — for **both** images, in the
  same one commit it already produces. This is staged **after** the
  PR + auto-merge port (the promotion-PR machinery and `validate.yml` land
  first; the digest-capture change to the build repo follows, so the new
  validation is in place before core starts emitting digests). ECR
  `imageTagMutability = IMMUTABLE` is set on the `aegis-core` repo as part of
  this step, closing tag re-pointing under a verified digest.
- **Lifecycle policy is two prefix rules in one repo** — no new repository to
  provision, no second cross-account pull policy, no second push grant.
- **Kyverno `require-digest`** (ADR-10) now covers two images per workload; the
  policy is per-image-reference and needs no change — it simply fires on both.

## Related

[ADR-10](10-release-model-build-once-promote-by-digest.md) ·
[ADR-12](12-registry-injection-vs-digest-pin-field-ownership.md) ·
[ADR-13](13-ci-iam-roles-survive-teardown.md) ·
[ADR-15](15-frontend-environment-promotion.md) (the non-OCI artifact class —
the frontend's promotion analogue to this multi-image one)
