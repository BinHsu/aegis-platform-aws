# Runbook — WS4 staging dual-region full-functional validation (billable)

> **Status:** prepared, NOT YET EXECUTED. This is the single billable bring-up that
> validates the WS4 changes (EKS Pod Identity engine identity #117 + Crossplane v2
> XBucket #119) against the **full functional e2e** across **both regions**, then tears
> down to $0. Per the strategy: exhaust the free prep (Part A) first; run the billable
> bring-up (Parts B–E) once, completely, in one pass; never iterate partial billable runs.
>
> **Cost discipline:** this is a WS3-prod-magnitude dual-region cluster. Monitor every
> mutating run at ~1-minute cadence (global rule n). A failed apply leaves billable
> partial resources + can corrupt state — on failure, **destroy the partial stack before
> iterating** (global rule). Same-session teardown bounds cost.

## Scope (what "完整驗過" means here)

Re-validate the **entire** staging e2e (not just the changed slice) across **eu-central-1
+ eu-west-1**, because the WS4 changes touch the engine's identity + cloud-resource path,
so a partial check cannot prove no regression:

- gateway `/healthz` 200
- engine fetches its model from S3 via **EKS Pod Identity** (the new #117 path, replacing
  the retired Crossplane-composed IRSA role)
- OIDC 5-face BVA (no-token / garbage / malformed / tampered-sig → `Unauthenticated`;
  valid PKCE → through) + a real PKCE login carrying `custom:tenant_id` (ADR-20 Lambda)
- real audio → text transcription (whisper-tiny-en correct output)
- **WS4 new:** an `XBucket` claim reconciles a real S3 bucket via the Crossplane v2 stack;
  the function + provider pods run 1/1 under PSA=restricted (DRC securityContext admits them)
- teardown leaves **zero orphan IAM** (the whole reason for #117)

---

## Part A — Free pre-flight gates (ALL must be green before any billable apply)

Do not assume an apply will fill these — every one of them is a thing that bit WS3 at
apply-time on a billable cluster (RETRO §2/§2A). Clear them for free first.

- [ ] **A1. Offline gate green** — `terraform validate`, `crossplane render` +
      `crossplane resource validate`, BVA negatives exit 1 (PR #119 CI). ✅ already green.
- [ ] **A2. kind-in-CI green** — the v2 Crossplane stack installs on a real API server;
      function/provider pods admitted 1/1 under PSA=restricted (reproduces the
      2026-06-18 / fix-B #2a failure mode for free); MRAP activates only S3; XBucket XR →
      `Bucket` MR object is created. (PR #119 integration job.)
- [ ] **A3. Image-in-ECR pre-flight, BY DIGEST, for BOTH regions** — `aws ecr
      describe-images` confirms gateway + engine + frontend images exist by the digest the
      deploy pulls, in the registry the deploy targets, resolvable from **eu-central-1 AND
      eu-west-1** (RETRO #1 cross-account ECR; prod cold-start `sha256:0000` placeholder +
      no eu-west-1 replica). No placeholder digests. No per-account repo drift.
- [ ] **A4. Cross-repo config contract** — one authoritative source for: registry account,
      hostnames, Cognito pool/client/redirect, **OIDC token-type (id vs access)**, ACM
      ARNs — and a check that fails loud on consumer disagreement (RETRO Class C). Confirm
      `aegis-core` / `aegis-core-deploy` / GH vars / Terraform all agree before spend.
- [ ] **A5. Model artifact staged** — `whisper-tiny-en` downloaded + SHA/size-verified
      against manifest, ready to seed **each region's** model bucket (RETRO #5 empty store;
      engine hard-gates on non-empty `/models`). Account-scoped buckets survive teardown.
- [ ] **A6. DNS delegation pre-checked for BOTH zones** — the per-env zones for both
      regions are delegated (Cloudflare → Route53 NS) BEFORE apply, so ACM DNS-01
      validation does not hang mid-apply on a manual paste (prod cold-start hung ~9 min).
      Treat delegation as a declared prerequisite, not a mid-apply surprise.
- [ ] **A7. Pre-apply adversarial audit green** — re-run the multi-agent audit (RETRO
      §6.1; caught 4 real breakers last time) against the post-merge WS4 + #117 + dual-region
      state. Feed it A4's config contract. Resolve every confirmed breaker for free.
- [ ] **A8. Guardrail mode set deliberately** — `ALLOW_PARTIAL_APPLY` semantics confirmed
      (recall: reversed — `false` = self-reap ON). Attended iteration vs unattended reap is
      an explicit choice; re-enable reap the moment attended validation ends.

**Gate:** A1–A8 all green → request explicit human "go" for the billable spend → proceed.

---

## Part B — Apply sequence (billable; 1-min cadence monitoring from here)

Order matters; #119 is stacked on #117 (Pod Identity is the engine's identity foundation).

1. **B1.** Per-account `bootstrap_complete` gate set for the staging account(s).
2. **B2.** Apply **#117** (Pod Identity platform side) + **#22** (engine SA bare) — engine
   identity = Terraform-owned role + Pod Identity association; `eks-pod-identity-agent`
   addon DaemonSet Running on every node.
3. **B3.** Apply **#119** (Crossplane v2 + XBucket) — crossplane core + provider-family-aws
   + provider-aws-s3 + MRAP + function + DRCs reach `Healthy=True`; pods 1/1 under PSA.
4. **B4.** Both regions: **eu-central-1** then **eu-west-1** (regional-stack is multi-region
   by design — verify the second region is not a placeholder/half-apply, the prod gap).
5. **B5.** Seed each region's model bucket (A5 artifact); confirm `/models` non-empty.

On any apply failure: **destroy the partial stack before iterating** (do not leave a
half-applied billable stack; do not let a transient blip self-reap a healthy cluster —
retry-before-reap).

---

## Part C — Functional validation (run in BOTH regions)

For each of eu-central-1 and eu-west-1:

- [ ] **C1.** gateway `/healthz` → 200.
- [ ] **C2.** engine model-pull via **Pod Identity** — `AWS_CONTAINER_CREDENTIALS_FULL_URI`
      injected; creds resolve to `aegis-core-engine-<region>`; `s3 sync` ListBucket +
      GetObject succeed on the in-region bucket. **No role at `/aegis-workload/`.**
- [ ] **C3.** OIDC 5-face BVA — no-token / garbage / malformed / tampered-sig →
      `Unauthenticated`; valid PKCE id_token (with `custom:tenant_id` from the ADR-20
      Lambda) → through.
- [ ] **C4.** PKCE browser login end-to-end against the region's Cognito pool.
- [ ] **C5.** real audio → text — submit a sample, assert whisper-tiny-en correct output.
- [ ] **C6. WS4 new** — apply an `XBucket` claim; the Crossplane v2 Composition reconciles
      a **real S3 bucket** (public access blocked) via the provider's Pod Identity creds;
      the Terraform-side workload policy grants the workload read/write to it.
- [ ] **C7.** provider + function pods 1/1 under PSA=restricted (no
      `violates PodSecurity "restricted"` events).

---

## Part D — Teardown + zero-orphan verification

- [ ] **D1.** `terraform destroy` both regions (reverse order); same session.
- [ ] **D2.** Post-destroy IAM scan: **zero** leftover engine role / Pod Identity
      association / Crossplane provider role; **nothing under `/aegis-workload/`** (the #117
      raison d'être — the v1 stack orphaned a role here).
- [ ] **D3.** No orphan ALB SG / `DependencyViolation` stalling VPC delete (watch for the
      destroy-stuck pattern, not just run status).
- [ ] **D4.** Account-scoped model buckets intentionally retained (or emptied + deleted if
      decided) — confirm the chosen disposition; bill → $0.

---

## Part E — Close-out

- [ ] **E1.** All C-checks green in both regions → #117 / #22 / #119 cleared to merge
      (the cluster gate the DRAFTs were waiting on).
- [ ] **E2.** Re-enable self-reap (`ALLOW_PARTIAL_APPLY=false`) — attended iteration over.
- [ ] **E3.** Record the run (what passed, any forward-fixes) as a RETRO/ADR addendum.
- [ ] **E4.** Confirm bill is $0 post-teardown.

## References
- `RETRO-ws3-staging-e2e-2026-06-18.md` (§2 incident inventory, §2A free-prep gaps, §5/§6 fixes)
- `docs/runbooks/ws3-prod-dual-region-verification.md` · `ws3-prod-go-live-execution.md`
- `docs/adr/21-*.md` (Pod Identity) · `docs/adr/22-terraform-crossplane-boundary-v2.md` (Crossplane v2)
- PRs: #117 (Pod Identity platform) · aegis-core-deploy #22 (engine SA bare) · #119 (XBucket v2)
