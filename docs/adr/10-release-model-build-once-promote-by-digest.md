# ADR-10: Release model — build once, promote by digest, single shared registry

## Status

Proposed (2026-06-05). Refines [ADR-03](03-delivery-cicd-gitops.md) (Delivery — CI/CD & GitOps).

## Context

ADR-03 fixed the delivery substrate: CI-driven `terraform apply`, pure-GitOps
reconciliation, per-cluster ArgoCD, workloads discovered by GitHub topic. It did
not fix the **artifact's path from build to production** — where the workload
image is built, where it lives, and how the *same bits* reach more than one
environment.

That path is currently under-specified and, for a multi-account posture, wrong.

- Each AWS account runs its own ECR repository (`aegis-greeter` in the dev
  account `677…`, again in the prod account `506…`). The workload's
  `publish.yml` pushes to whichever single registry its **repo-level** GitHub
  variables point at.
- Promoting dev → prod therefore means re-pointing those repo variables (a
  destructive, global overwrite) and **re-running the build against the prod
  account**.
- The deploy repo pins the image by git short-sha tag (`newTag`), not by a
  content digest.

Three problems follow.

### 1. A rebuilt image is not the verified image

If prod rebuilds — even from the identical git sha — there is no guarantee the
result is bit-for-bit what staging verified. Base-image drift, package-mirror
state, build timestamps, and any non-reproducible build step break identity. The
staging verification then does not transfer: prod runs an artifact nobody
tested. This is the supply-chain provenance argument (SLSA) — you verify an
**artifact**, and you ship **that** artifact, not a same-named rebuild.

### 2. A per-account registry forces a trust or a copy

Account isolation is correct: prod must not pull from the dev account's registry
(a dev compromise would poison the prod supply chain). But "each account its own
ECR" means the artifact exists in two registries, and proving the two identical
re-introduces problem 1 unless the **same** image is *copied*, never rebuilt.

### 3. The deploy repo already removed the registry from its concern

The registries-driven ApplicationSet List generator (post-#24) injects
`newName` — `<ecrAccountId>.dkr.ecr.<region>.amazonaws.com/<repo>` — from
`registries.auto.tfvars.json` at sync time. Deploy repos carry only the bare
`name:tag`. The registry is already a **per-cluster injected parameter**, not a
deploy-repo constant. This is the seam that makes a single shared registry a
config change rather than a redesign.

## Decision

**Build the workload image exactly once; promote the immutable artifact by
digest; serve every environment from one shared, neutral registry.**

### Build once

The workload repo's CI builds and pushes the image **one time**, on merge to its
`main`, and records the image **digest** (`sha256:…`). No environment ever
rebuilds. ECR repositories set `imageTagMutability = IMMUTABLE`, so a tag cannot
be re-pointed under a verified digest.

### Single shared registry, neutral account

One ECR repository per workload lives in a **neutral shared account** (the
account-fabric's shared-services account, or a dedicated artifacts account — see
Open sub-decisions). Every cluster — staging and prod, every region — pulls from
it through a cross-account ECR repository policy. The registry account is its own
trust boundary; it does not inherit any single environment's posture.
`registries.auto.tfvars.json` points `ecr_account_id` at the shared account for
**all** clusters; the existing injection then resolves the same registry
everywhere with zero deploy-repo change.

A single shared registry is the *primary* choice, not the only defensible one.
"Build once, promote by digest" is near-universal best practice; "one shared
registry vs per-account registries fed by replication" is where mature
organizations legitimately diverge. High-isolation or regulated estates often
keep a registry per account — populated by ECR cross-account **replication**
(push once, AWS copies the *same* digest), so prod never depends on a shared
registry's availability or attack surface. The build-once and promote-by-digest
invariants hold identically under both; only the registry topology differs. The
replication variant is retained as the named fallback (Alternatives).

### Promote by digest, not by rebuild

Promotion from staging to prod is a **config-repo change only**: the prod overlay
is set to the **same digest** staging verified. No rebuild, no re-push, no second
registry. The bits that passed staging are the bits prod runs. The deploy repo
pins the artifact by digest (`name@sha256:…`), upgrading from the mutable git-sha
tag.

### How a prod release is triggered

A prod release is a **promotion pull request** against the deploy repo: it copies
the **exact digest the staging overlay already carries and staging verified**
into `overlays/prod`. The PR *merge* is the trigger; review is the gate.

- **Gate** — the deploy repo's branch protection plus a GitHub `prod` Environment
  protection rule (required reviewers, optional wait timer). The release manager
  approving the promotion PR is the human go/no-go.
- **Apply** — the prod cluster's ArgoCD Application runs **auto-sync**, so the
  merge deploys the promoted digest with no second action. Git is the single
  source of truth and the audit record: what prod runs equals the digest in
  `overlays/prod`, with full history.
- **Initiation** — the digest copy is either a hand-authored PR or a thin
  `workflow_dispatch` "promote" job that reads the staging overlay's digest,
  writes `overlays/prod`, and opens the PR. Both end at the same gated merge.

Rejected for the trigger: ArgoCD manual-sync as the gate (moves the control point
off git, weakening audit) and auto-promote-on-staging-green for prod (continuous
*deployment* to prod removes the human gate; staging may auto-promote, prod does
not).

### Environment differences live in config, never in the artifact

The artifact is environment-agnostic. Everything that differs between staging and
prod — replica counts, resource limits, hostnames, the cluster account a role
trusts — lives in the deploy-repo overlay and the per-cluster injected parameters
(registry, IRSA role ARN, cert ARN). Credentials and IAM role ARNs are
**per-account by nature** and stay split; the artifact does not split.

### Selection is by promotion, not by branch

Neither repo uses a branch per environment. Branch-per-environment in the build
repo would rebuild the same source per environment — the anti-pattern this ADR
rejects. Environments are selected by **promoting a digest** through deploy-repo
overlays, optionally gated by a GitHub `prod` Environment protection rule.

## Alternatives considered

- **Per-account registry, build-once-push-many** (CI pushes the same image to
  each account's ECR, or ECR cross-account **replication** does it). Preserves
  artifact identity and strict account isolation. Rejected as the *primary* model
  because it maintains N registries and N push grants, and "are these two
  identical?" is answered by policy rather than by construction. Retained as the
  **fallback** if a single shared registry is organizationally unacceptable;
  replication (push once, AWS copies) is the mechanism, not N CI pushes.
- **Repo-level variable overwrite (current state).** Destructive, single-target,
  conflates environments in one global slot. This ADR exists to replace it.
- **Rebuild per environment from the same git sha.** Breaks the verify → ship
  chain (Context §1).
- **Branch-per-environment.** Rejected for the build repo (rebuilds source); the
  deploy repo uses overlay-per-environment (directory), consistent with
  [ADR-08](08-cluster-multi-tenancy.md).

## Consequences

- A shared/artifacts account gains an ECR repository per workload plus a
  cross-account pull policy enumerating the cluster accounts. Landing-zone /
  account-fabric work.
- The workload `publish.yml` moves from repo-level account variables to one
  shared-registry target; the dev → prod distinction leaves the build entirely.
  The destructive repo-var clobber done during the current campaign is reverted
  as part of this.
- The deploy repo gains a **staging overlay** beside prod and pins images by
  digest. Promotion becomes an explicit staging → prod overlay bump (PR or
  dispatch), enabling a human gate.
- A real **staging cluster** is implied: "verify in staging, promote to prod" is
  meaningless without one. The current campaign has run prod-only; standing up
  staging is part of realizing this model and is sequenced separately.
- ECR `IMMUTABLE` tags + digest pinning make every running artifact auditable
  back to one build. Optional hardening (cosign signature + SBOM/provenance
  attestation at build, verified at admission) layers on without changing the
  model.
- The 2-region E2E verification in flight is **orthogonal** to this decision — it
  exercises ArgoCD discovery and CI teardown, unaffected by registry topology. It
  proceeds on the present per-account prod ECR; this ADR is the target the next
  campaign migrates to.

## Open sub-decisions

- **Registry home** — the existing shared-services account vs a dedicated
  artifacts account. Dedicated is the cleaner trust boundary; shared-services is
  less new fabric.
- **Digest vs immutable-tag pin** — pin `name@sha256:…` (airtight) vs rely on
  ECR `IMMUTABLE` tags with a git-sha tag (simpler, slightly weaker).
- **Attestation depth** — whether cosign signing + SBOM/provenance and
  admission-time verification land now or in a later phase.

## Implementation phases

1. **Record (this ADR).** Decision hardened; the in-flight verify proceeds on
   current topology.
2. **Shared registry.** Pick the host account; create per-workload ECR +
   cross-account pull policy; repoint `registries.auto.tfvars.json` for all
   clusters; revert the build repo's repo-var clobber to one shared target.
3. **Digest pinning + staging overlay.** Deploy repos pin `@sha256:…`; add a
   staging overlay; build CI bumps the staging overlay to the freshly-built
   digest.
4. **Promotion gate.** Prod release = a promotion PR copying the staging-verified
   digest into `overlays/prod`; gated by branch protection + a GitHub `prod`
   Environment protection rule; prod ArgoCD on auto-sync so the merge deploys.
   Optionally a `workflow_dispatch` "promote" job authors the PR. See
   "How a prod release is triggered".
5. **Optional attestation.** cosign sign + SBOM/provenance at build;
   admission-time verification.

## References

- [ADR-03](03-delivery-cicd-gitops.md) — delivery substrate this refines
- [ADR-07](07-workload-self-ownership.md) — workload self-ownership; the
  registries injection seam
- [ADR-08](08-cluster-multi-tenancy.md) — overlay-per-environment in the deploy
  repo
- SLSA / in-toto artifact provenance; ECR cross-account replication and
  repository policies
