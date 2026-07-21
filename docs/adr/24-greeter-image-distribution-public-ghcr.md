# ADR-24: aegis-greeter image distribution — public GHCR

## Status

Accepted (2026-07-21). **Supersedes [ADR-10](10-release-model-build-once-promote-by-digest.md)
and [ADR-12](12-registry-injection-vs-digest-pin-field-ownership.md) for aegis-greeter
only** — the platform no longer injects the registry for greeter. Mirrors
[ADR-23](23-image-distribution-public-ghcr-graviton.md), which made the same move for
aegis-core on 2026-06-20. ADR-23's own text ("Greeter is unaffected and stays on ECR
with ADR-10/12 intact") is now stale as of this ADR — see the amendment note added
there.

## Context

Greeter's `publish.yml` (aegis-greeter repo) switched from AWS ECR to `ghcr.io` on
2026-07-21. The stated reason, from that workflow's own commit: the ECR + AWS OIDC push
path never actually worked — the `aegis-greeter-ci-push` IAM role's trust policy was
never wired to the aegis-greeter repo, so every push-to-ECR attempt failed on
`sts:AssumeRoleWithWebIdentity`. GHCR needs no external trust setup: auth is the
built-in `GITHUB_TOKEN`, scoped to the repo, always present. This is a narrower
motivation than ADR-23's (which was driven by a cross-account teardown coupling and an
arm64/Graviton node-cost argument) — but the resulting consumer-side shape is the same
one ADR-23 already established: a static public GHCR ref needs no per-account,
per-region injection.

## Decision

**Distribute the greeter image via public GHCR: `ghcr.io/binhsu/aegis-greeter`.**

- **Registry.** `ghcr.io/binhsu/aegis-greeter`, intended public (unconfirmed — see
  Consequences). No new build path; `aegis-greeter/.github/workflows/publish.yml` already
  does the push.
- **Static ref — the platform stops injecting the registry for greeter.** Exactly
  ADR-23's reasoning: a GHCR ref has no account id and no region, so there is nothing
  left for the platform to hide. `aegis-greeter-deploy`'s staging and prod overlays now
  carry `images.newName: ghcr.io/binhsu/aegis-greeter` directly, and no longer consume
  the `aegis.binhsu.org/ecr-repository` annotation (the `replacements` rule that spliced
  it into the image field is removed from both overlays). This supersedes ADR-12 **for
  greeter**, same as ADR-23 did for aegis-core.
- **Digest-promotion model is preserved.** Build once, promote the same digest from
  staging to prod (ADR-10's invariant) — unchanged. What changed is the registry
  hostname, not the promotion contract.
- **Talos/on-prem overlay is untouched.** `aegis-greeter-deploy`'s `k8s/overlays/talos`
  pulls from a local, in-cluster registry — never AWS ECR — and reuses the
  `aegis.binhsu.org/ecr-repository` annotation channel for that unrelated value. This ADR
  does not touch it.

## Consequences

- **The platform's `aegis.binhsu.org/ecr-repository` injection for greeter becomes dead
  data, not removed.** The shared ApplicationSet template
  (`gitops/platform-addons/addons/workloads/applicationset.yaml`) unconditionally injects
  this annotation for every workload in `registries.auto.tfvars.json`'s
  `workload_registries` map — it is not special-cased per repo. Rather than touch that
  shared template (blast radius: every onboarded workload, not just greeter), this ADR
  follows ADR-23's actual precedent: the annotation keeps arriving, harmlessly, and the
  deploy repo simply no longer reads it. **Follow-up, not done here:** remove greeter's
  entry from the real (gitignored) `registries.auto.tfvars.json` — the example template
  (`registries.auto.tfvars.json.example`) is updated by the companion PR to flag this.
- **Greeter's per-account ECR + CI push role are now orphaned**, exactly as ADR-23 left
  aegis-core's push role — a deliberate orphan, not deleted here. This includes (at
  least): `terraform/envs/platform/ecr.tf`'s greeter ECR repository resource,
  `terraform/envs/bootstrap/iam-seed.tf`'s `aegis-greeter-ci` role (which per the
  aegis-greeter publish.yml commit never successfully assumed anyway), and the
  `ECR_REPO_URL` / `ECR_REGISTRY` / `OIDC_ROLE_ARN` / `AWS_REGION` repo variables on
  `aegis-greeter`. A later cleanup PR can delete them; this ADR only records that they're
  dead.
- **`.github/workflows/preflight.yml`'s greeter ECR-existence check no longer applies.**
  It asserted the digest pinned in `aegis-greeter-deploy`'s overlay exists in the shared
  ECR (`aws ecr describe-images`). Post-migration, that digest lives in GHCR instead. The
  companion PR repoints this check to a GHCR digest-existence check (anonymous-token
  manifest lookup, since the image is intended public).
- **Package visibility is unconfirmed.** ADR-23 explicitly decided aegis-core's GHCR
  packages are public. This ADR assumes the same for greeter but nothing has verified
  `ghcr.io/binhsu/aegis-greeter`'s actual visibility setting. If it turns out private, EKS
  nodes need a GHCR `imagePullSecret` — no existing pattern in this codebase provisions
  one, so that would be new wiring, not a copy of an existing mechanism.

## Related

[ADR-10](10-release-model-build-once-promote-by-digest.md) (promote-by-digest — still
holds) ·
[ADR-12](12-registry-injection-vs-digest-pin-field-ownership.md) (superseded for
greeter — registry injection) ·
[ADR-23](23-image-distribution-public-ghcr-graviton.md) (the precedent this ADR mirrors,
for aegis-core) ·
`aegis-greeter-deploy` PR "chore(deploy): pull greeter image from GHCR instead of ECR".
