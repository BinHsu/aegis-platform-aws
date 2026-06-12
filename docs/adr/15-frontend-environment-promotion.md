# ADR-15: Frontend environment promotion — the non-OCI artifact class

## Status

Accepted (operator 2026-06-12). Extends
[ADR-10](10-release-model-build-once-promote-by-digest.md) (build once, promote
by digest) to an artifact class that has **no OCI digest**: a static
single-page-app bundle served from S3 + CloudFront.

## Context

ADR-10 and [ADR-14](14-multi-image-atomic-promotion.md) cover container images,
where the artifact is content-addressed by an OCI digest and promotion is a
digest copy. The `aegis-core` **frontend** is a different artifact class, and
ADR-10's mechanism does not transfer cleanly.

Today's audit of the frontend:

- **Vite + React SPA.** The build emits **content-hashed assets**
  (`app.<hash>.js`, `chunk.<hash>.css`) — immutable per URL — plus a **mutable
  `index.html`** that references the current hashed asset names.
- **Direct, non-GitOps deploy.** The current flow is
  `aws s3 sync --delete` to **one staging bucket**, followed by a CloudFront
  `/*` invalidation. It is direct (CI writes the bucket), single-environment
  (no prod bucket, no overlay), and has **no promotion step**.
- **The killer constraint: env values are baked at build time.** The bundle
  embeds environment-specific config **at build** — `VITE_AEGIS_COGNITO_*`,
  `VITE_AEGIS_GATEWAY_ENDPOINT`. Vite inlines `import.meta.env.VITE_*` into the
  emitted JavaScript. A bundle built for staging **physically contains
  staging's Cognito pool and gateway URL**. Strict build-once
  (one artifact, every environment) is therefore **blocked** unless config
  becomes runtime-fetched — you cannot promote a staging bundle to prod when the
  staging bundle has prod's wrong endpoints compiled in.

So the question is two-layered: (1) what is "the digest" for a non-OCI artifact,
and (2) how do we get to build-once when the build currently bakes the
environment in?

## Decision

**Build once → upload to an immutable, git-SHA-addressed S3 prefix → promotion
repoints the prod origin at that same prefix → externalize env config to runtime
so the one bundle is environment-agnostic.**

### What is "the digest"

The content-addressed analogue of an OCI digest is the **release prefix keyed by
git SHA**:

```text
s3://<bucket>/releases/<git-sha>/index.html
s3://<bucket>/releases/<git-sha>/assets/app.<asset-hash>.js
```

The build uploads the whole bundle under `releases/<git-sha>/` **once** and never
overwrites that prefix. `<git-sha>` is the promotion handle, exactly as the OCI
digest is for an image. (The Vite per-asset content hash is a finer-grained
immutability *within* a release; the **release** unit we promote is the prefix.)

**Object immutability is convention, not enforcement** by default — nothing stops
a later `s3 sync` from overwriting `releases/<sha>/`. The enforcement option is a
**bucket policy** denying `s3:PutObject` / `s3:DeleteObject` on
`releases/*` to the CI principal *after* the upload completes (or S3 Object Lock
in governance mode on the prefix). We adopt the **deny-overwrite bucket policy**
as the target — it makes the release prefix immutable by construction, the
S3 analogue of ECR `IMMUTABLE`. (Status quo `--delete` sync is exactly what this
forbids; see WS1 below.)

### Serving and promotion

- **Staging serves the new release** by pointing staging's CloudFront origin path
  (or a pointer, below) at `releases/<sha>/`. The build that produced the prefix
  auto-advances staging — staging is the verify surface.
- **Promotion = repoint prod at the SAME prefix.** A prod release does **not**
  rebuild and does **not** re-upload. It repoints **prod's** CloudFront
  **origin path** (`/releases/<sha>`) — or a CloudFront Function /
  KeyValueStore pointer that rewrites the origin path — at the **same**
  `releases/<sha>/` staging verified. Prod serves the exact bytes staging served.
- **The pointer lives in git** — it is the GitOps handle. The prod origin-path
  value (or KeyValueStore pointer value) is a field in the prod overlay / config
  repo. **A promotion PR changes that one field**; CI applies it (updates the
  CloudFront distribution's origin path or writes the KeyValueStore key). Same
  shape as ADR-10's digest copy: the promotion is a reviewed git change, the
  apply is mechanical, git is the audit record of what prod serves.
- **Rollback = repoint** the prod pointer back to the previous `releases/<sha>/`
  (revert the promotion PR). The old prefix is still there (immutable), so
  rollback is instantaneous and serves known-good bytes.
- **Invalidation scope.** Because each release is a **distinct prefix**, prod's
  cutover invalidates only the **mutable entry document** — `/index.html` (and
  the SPA rewrite target) — **not** `/*`. The content-hashed assets are
  new URLs, never cached under an old name, so they need no invalidation. This
  is strictly cheaper and safer than the status quo `/*` blanket invalidation
  (which churns the whole edge cache on every deploy).

### The baked-env problem — resolved by runtime config

Strict build-once requires the bundle to be environment-agnostic. The app
fetches **`/config.json` at boot** — a tiny JSON with `cognito`,
`gatewayEndpoint`, and any other env-specific values. That file lives
**outside** the release prefix — at the bucket root or a per-env path
(`s3://<bucket>/config.json`, distinct per environment / distribution) — so the
**same** `releases/<sha>/` bundle reads staging's config under the staging
distribution and prod's config under the prod distribution. This enables **true
build-once**: one artifact, promoted by repoint, environment supplied at runtime.

The required frontend change is a **WS1 prerequisite, not optional**: replace
compile-time `import.meta.env.VITE_AEGIS_*` reads with a boot-time
`fetch('/config.json')` (one `config` provider / context, ~one file). The
Cognito SDK and gateway client read from the fetched object instead of the
inlined env. Without this change the bundle still carries baked env values;
promotion would serve staging's endpoints to prod users — a functional
regression. The `/config.json` refactor ships as part of WS1 alongside the
prefix/pointer/promotion plumbing.

## Alternatives considered

- **Per-env rebuild, promote the git SHA.** Keep baking env at build; build a
  prod bundle from the **same git SHA** under `releases/<sha>-prod/`; promotion
  repoints prod at *its* prefix. This promotes the **git SHA** (the source
  identity), **not the byte-identical artifact** — prod runs a separate build of
  the same source, which ADR-10 §1 explicitly calls out as breaking the
  verify→ship chain. Rejected: accepting per-env rebuild would bake env values
  into the artifact and forfeit the artifact-immutability the whole ADR exists to
  get — the prefix/pointer/promotion machinery would exist but would provide
  weaker guarantees than stated. The operator chose the clean build-once path;
  per-env rebuild does not deliver it.
- **Keep the direct `s3 sync --delete` (status quo).** One bucket, overwrite in
  place, `/*` invalidation. Rejected: no immutability (every deploy destroys the
  prior release — no rollback target), no env promotion (no prod path at all),
  not GitOps (CI mutates the bucket with no reviewed pointer). It is the thing
  this ADR replaces, mirroring ADR-10's rejection of the repo-var clobber.
- **S3 versioning-based.** Enable bucket versioning, promote by object version
  ID. Rejected: version IDs are **per-object**, but a release is a **set** of
  objects (index + N hashed assets); there is no single version ID for "the
  release", so you would still need an external manifest of per-object versions —
  more moving parts than an immutable prefix that names the whole set with one
  git SHA. Versioning is retained only as defense-in-depth (accidental-delete
  recovery), not as the promotion handle.
- **CloudFront staging-distribution swap.** Maintain two distributions and swap
  which one prod DNS points at. Rejected as heavier than the problem: it
  duplicates the distribution (cert, WAF, behaviors, logging) to move a pointer
  that an origin-path / KeyValueStore change moves in place, and DNS TTL makes
  the cutover slower and the rollback laggier than a repoint + targeted
  invalidation.

## Consequences

- **Build CI changes** from `aws s3 sync --delete <local-dist> s3://<bucket>/`
  to `aws s3 sync <local-dist> s3://<bucket>/releases/<git-sha>/` (no `--delete`,
  write-once prefix), then advances the **staging** pointer. A deny-overwrite
  bucket policy on `releases/*` makes the prefix immutable (the S3 analogue of
  ECR `IMMUTABLE`).
- **A prod CloudFront distribution / behavior** is provisioned (it does not exist
  today — current flow is staging-only), reading from the same bucket via a
  git-tracked origin-path / KeyValueStore pointer. This is platform/landing-zone
  work, sequenced like ADR-10's staging-cluster standup.
- **Promotion becomes a reviewed PR** that changes one pointer field, gated by
  the same `prod` Environment protection rule ADR-10 uses for image promotion —
  the frontend joins the same human go/no-go.
- **WS1 must include the `/config.json` frontend refactor** — it is a prerequisite
  of the prefix/pointer/promotion machinery, not a follow-up. Replace
  `import.meta.env.VITE_AEGIS_*` reads with a boot-time `fetch('/config.json')`
  before the first promotion runs against prod; without it the bundle carries
  staging endpoints and the promotion would be a functional regression.
- **Invalidation cost drops** from `/*` to `/index.html` (+ SPA rewrite target)
  per release, because content-hashed assets are new URLs each release.
- **The frontend is now promotable like the images** — `aegis-core`'s full
  release (two images per ADR-14 + the SPA per this ADR) advances staging and
  promotes to prod through reviewed git changes, no environment rebuilding the
  verified artifact.

## Related

[ADR-10](10-release-model-build-once-promote-by-digest.md) (the digest model
this adapts to a non-OCI artifact) ·
[ADR-12](12-registry-injection-vs-digest-pin-field-ownership.md) (overlay-owns-
the-pin, platform-injects-the-location — the SPA's `/config.json` is the same
"environment supplied at the edge, not baked into the artifact" principle) ·
[ADR-14](14-multi-image-atomic-promotion.md) (the multi-image promotion this
parallels for the frontend artifact class) ·
[ADR-13](13-ci-iam-roles-survive-teardown.md)
