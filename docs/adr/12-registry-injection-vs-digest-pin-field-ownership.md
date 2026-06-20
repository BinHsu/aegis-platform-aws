# ADR-12: Registry injection vs digest pin — `kustomize.images` field ownership

## Status

Accepted (2026-06-10). Refines [ADR-10](10-release-model-build-once-promote-by-digest.md)
(promote-by-digest) and the ADR-07 injection mechanics. Supersedes the
ApplicationSet's `kustomize.images` registry injection (the post-#24 D4
mechanism).
**Superseded for aegis-core by [ADR-23](23-image-distribution-public-ghcr-graviton.md)**
(2026-06-20): aegis-core's GHCR refs are static (no account id / region), so the
platform no longer injects a registry for it — the overlay carries the full ref.
Greeter still consumes the `aegis.binhsu.org/ecr-repository` annotation per this
ADR.

## Context

Two parties write to a workload's image reference, and they collided on one
kustomize field:

- **The deploy repo** pins the image **digest** (`image@sha256:…`) in its
  overlay's `images:` entry — the ADR-10 invariant (prod runs exactly the
  bits staging verified).
- **The platform** injects the **registry location** — the
  `<account>.dkr.ecr.<region>.amazonaws.com/<repo>` prefix — because account
  IDs stay out of public deploy repos (D4) and only the cluster knows which
  account/region it pulls from.

The platform's injection rode the same field: the ApplicationSet template set
`spec.source.kustomize.images = ["aegis-greeter=<acct>.dkr.ecr.<region>.amazonaws.com/aegis-greeter"]`
(newName only, no tag/digest), assuming kustomize would merge it with the
overlay's digest-only entry.

**It does not merge — it replaces.** Empirically, with kustomize v5.8.1:
ArgoCD applies an `images` override by running `kustomize edit set image`
against the overlay, and a newName-only override **replaces** the overlay's
digest-only entry for the same image name. The digest field is deleted, the
manifest renders `<registry>/aegis-greeter:latest`, the pod goes
ImagePullBackOff (no `latest` tag exists under `IMMUTABLE` tag mutability) —
and even if it pulled, the ADR-10 invariant would be silently dead: the
cluster would run whatever `latest` pointed at, not the promoted digest.

## Decision

**`kustomize.images` belongs exclusively to the deploy repo. The platform
never writes it.**

- The deploy repo's overlay owns the full `images:` entry — including the
  digest pin. Nothing platform-side touches that field.
- The platform injects the registry as an **annotation**, on the same channel
  as the existing region injection (`aegis.binhsu.org/region`):

  ```text
  aegis.binhsu.org/ecr-repository = <acct>.dkr.ecr.<region>.amazonaws.com/<repo>
  ```

  Full repository URL, **no tag, no digest** — exactly the value the old
  `images` line computed.
- The deploy repo consumes it with a kustomize **replacement** (delimiter
  `@`, index `0`) onto its container image field: the registry half of
  `registry@sha256:digest` is replaced, the digest half is untouched.
  Workload-owned, mirroring how greeter already consumes the region
  annotation — the platform still never learns any workload's internal
  deployment/container names.

The ownership rule generalises: the platform injects **cluster facts** as
annotations; the deploy repo decides **where they land** via replacements.
One generic channel, no per-workload knowledge platform-side, no shared-field
write collisions.

## Alternatives considered

- **Platform override carries the digest** (inject
  `name=<registry>/<repo>@sha256:…` so the replacement is complete):
  rejected — the platform cannot know the digest. The digest is the
  *promotion* artifact, owned by the deploy repo's overlay per ADR-10; piping
  it through platform terraform would invert the promotion flow and put the
  release pin in two places.
- **Overlay carries `newName`** (deploy repo writes the full registry URL,
  platform injects nothing): rejected — the ECR account ID lands in a public
  git repo, which is precisely what D4 exists to prevent; and it couples
  every overlay to one account/region, breaking multi-account pulls of the
  same overlay.
- **Patch/replacement injected platform-side onto the image field directly:**
  rejected — requires the platform to know each workload's
  deployment/container path, re-introducing the per-workload knowledge the
  annotation channel removed (same reasoning that kept region out of
  templatePatch).

## Consequences

- The ApplicationSet template no longer sets `kustomize.images`; it sets the
  `aegis.binhsu.org/ecr-repository` annotation in `commonAnnotations`
  (regional-stack `argocd.tf`).
- Deploy repos must add the consuming replacement (delimiter `@`, index 0)
  in their overlays — a one-time change per workload; greeter-deploy carries
  it as part of the 6/12 work. A workload that ignores the annotation simply
  keeps whatever registry its overlay names (which for a public repo should
  be none — so adopting the replacement is the D4-compliant path).
- The digest pin can no longer be wiped by a platform-side sync: the two
  writers now write disjoint fields.
- `registries.auto.tfvars.json` / `REGISTRIES_JSON` keep their shape — only
  the injection channel changed, not the data source.

## Related

[ADR-07](07-workload-self-ownership.md) ·
[ADR-10](10-release-model-build-once-promote-by-digest.md) ·
[ADR-11](11-account-dimension-single-source-of-truth.md)
