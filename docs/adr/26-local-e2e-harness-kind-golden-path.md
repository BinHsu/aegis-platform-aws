# ADR-26: Local E2E harness — kind golden-path lane gates the ownership inversion

## Status

**Accepted — decided by Bin via epic
[#167](https://github.com/BinHsu/aegis-platform-aws/issues/167) (2026-07-06/07);
recorded retroactively 2026-07-09.** Implemented: B1 (issue #170, PR #179) and
B2 (issue #171, PR #191), both merged. B3 (issue
[#172](https://github.com/BinHsu/aegis-platform-aws/issues/172)) is **open** —
recorded below as a **Proposed extension, not implemented**. This ADR and
[ADR-25](25-ownership-inversion-gitops-app-of-apps.md) were both reserved by
the epic (its open-decision #10) before either file existed; ADR-27 already
notes the reservation.

## Context

[ADR-25](25-ownership-inversion-gitops-app-of-apps.md)'s ownership-inversion
stages (A1–A6) each change what owns live infrastructure and are expensive and
risky to validate against real AWS — a bad migration surfaces as a stranded
EKS cluster, not a failed unit test. Epic #167 set the ordering rule
explicitly: **B gates A.** A local E2E harness proves the golden path — ArgoCD
synced, policies enforced, a sample workload admitted — entirely on `kind`,
for \$0, before any A-stage touches Terraform. B1 was buildable with zero open
decisions and zero AWS spend, making it the epic's ready-to-start entry point;
every A-stage's validation then re-runs the harness against the
GitOps-delivered components before its tracking issue is allowed to close.

## Decision

### B1 — kind golden-path skeleton (#170, PR #179)

- `scripts/e2e/golden-path.sh` — a substrate-agnostic driver (kind today, k3s
  per B3) that installs ArgoCD, Kyverno, and aegis-policies.
- `scripts/e2e/negative/assert-require-digest.sh` and
  `assert-default-deny.sh` — hermetic negative assertions: `require-digest`
  denies a tag-only pod and admits a digest-pinned one; the generated
  default-deny `NetworkPolicy` actually blocks cross-namespace traffic.
  `scripts/e2e/kind/kind-calico.yaml` installs Calico because kindnet does
  not enforce `NetworkPolicy` — without it the default-deny assertion would
  pass vacuously.
- `require-digest` flipped to **Enforce** as a **harness-local overlay only**
  (epic decision #8) — the production posture (Audit, `var.require_digest_action`
  before A2 retired the variable) is untouched outside the harness.
- Kyverno negative-test scope is **`require-digest` + default-deny only**
  (epic decision #7): the trust-subject policy was retired by ADR-22 and is
  deliberately **not** resurrected in test fixtures.
- `.github/workflows/e2e-golden-path.yml` — the CI gate: `contents: read`
  only, no `id-token` permission, assumes no AWS role, zero billable
  resources.
- `charts/aegis-policies/tests/` fixtures were added in the same PR so the
  static-checks `kyverno test` gate stopped skipping.

### B2 — sample workload onboarding (#171, PR #191)

- A `registry:2` container stands in for ECR. `crane copy` seeds it so the
  fixture's committed `@sha256` pin survives byte-for-byte (`docker push`
  would re-digest the image). In-cluster, `localhost:5000` resolves to it via
  containerd's `config_path` + per-node `hosts.toml` — kind's documented
  mirror pattern.
- `scripts/e2e/b2/workload-applicationset.yaml` — a faithful port of the
  production `AppProject` + workload `ApplicationSet` in
  `terraform/modules/regional-stack/argocd.tf`: same List generator, same
  `goTemplate`, same `templatePatch` conditionals, elements built from
  `sample-registries.json` with the exact transform of
  `local.workload_list_elements`.
- `scripts/e2e/b2/assert-workload-onboarding.sh` asserts: the rendered
  `Application/aegis-sample` reaches Synced + Healthy; the digest-pinned
  Deployment is admitted and available; the per-workload/per-account
  injections land (`commonAnnotations` for region + `ecr-repository`, the
  conditional model-store `ConfigMap` patch for an `engine_irsa`-declaring
  workload, cert/gateway-oidc guards staying off when not declared); a
  tag-only variant of the same workload is denied at admission.
- **The golden path is the acceptance gate for A5**: the epic's own text
  (and PR #191) name this harness as the pass/fail check for the A5 workload-
  `ApplicationSet` migration — re-running it against the GitOps-delivered
  `ApplicationSet`, instead of the harness-applied copy, had to reproduce the
  identical Synced + Healthy end-state with the same injections. PR #196
  (A5) confirms this: an isolated kind + ArgoCD render of the pre-A5 List
  generator against the post-A5 facts-bridge `Matrix` generator produced a
  byte-identical `spec.source`, differing only in the two intended A5
  additions (a `syncWave` and a `retry` backoff block).

### B3 — k3s lane (#172, **open — Proposed extension, not implemented**)

Epic decision #9: adopt `aegis-apple-container-provisioner-k3s` as a
documented **richer local lane**; `kind`-in-CI stays the required gate
regardless of whether B3 ships. `golden-path.sh`'s substrate-agnostic design
(it already branches on kind vs k3s) anticipates this, but the k3s
provisioner wiring itself has not been built. No A-stage was blocked on it —
every A1–A6 PR validated against `kind` alone.

### The hermetic-assertion approach

Every stage proves its gate with a **scripted, no-AWS, no-manual-inspection**
assertion script (`scripts/e2e/assert-*.sh`) that the CI workflow calls
directly — never a human eyeballing `kubectl get` output. Assertions are
structural enough to prove **negative and exclusion** cases as rigorously as
positive ones: `scripts/e2e/assert-ephemeral-profile.sh` (added in A6, PR
#197) registers a synthetic facts-bridge `cluster` Secret pointing at an
**unreachable** API server, flips the `profile` label, and asserts the ALB
controller and external-dns `Application`s are generated when `profile=full`
and **absent** when `profile=ephemeral` — the unreachable server means the
selector logic is proven with zero risk of a real chart actually syncing on
`kind`. `scripts/e2e/assert-argo-rollouts.sh` (A4) proves CRD-before-workload
ordering the same way: a probe `Rollout` is admitted only after
`rollouts.argoproj.io` reaches `Established`.

## Consequences

- Every ownership-inversion stage gained a \$0 pre-flight gate: an ordering or
  facts-bridge mistake surfaces in CI within minutes, not on a billable EKS
  run days later.
- The harness surfaced substrate-specific quirks that had to be discovered
  and fixed in-flight, not assumed: kindnet vs Calico for `NetworkPolicy`
  enforcement (B1); containerd's `config_path`/`hosts.toml` registry-mirror
  wiring, which breaks on containerd 2.x's removed `registry.mirrors` table
  on node images ≥ v1.33 — caught live during B2; `crane copy` needed in
  place of `docker push` to avoid re-digesting a pinned fixture image.
- Harness copies of production manifests (`scripts/e2e/b2/workload-applicationset.yaml`
  vs `argocd.tf`, later `gitops/platform-addons/addons/workloads/applicationset.yaml`)
  necessarily drift from what they mirror. Each carries an explicit lock-step
  warning in its header. Open decision **B2-a** — factor both into one file
  both Terraform and the harness read — is **AWAITING BIN**, deferred because
  production's `local.workload_list_elements` references live AWS outputs
  (`aws_s3_bucket`, ACM certs) only provable equivalent with `terraform plan`
  against real AWS, out of scope for a \$0 kind harness.
- B3 is a documented, deliberate gap: richer local iteration via k3s remains
  optional and unbuilt; `kind`-in-CI is the only required gate, so nothing
  downstream is blocked on B3 closing.
- Every A-stage PR (ADR-25) still names a **batched ephemeral-EKS run** as the
  final acceptance step this harness cannot substitute for — the kind lane
  proves delivery mechanics and negative/positive admission; it does not
  prove real AWS resources reconcile (e.g., an `XBucket` composing an actual
  S3 bucket, a real ALB provisioning) or that `terraform destroy` collapses
  cleanly against live cloud state.

## Relationship to prior ADRs

- **[ADR-25](25-ownership-inversion-gitops-app-of-apps.md)** (ownership
  inversion): this harness is ADR-25's validation precondition — "B gates A."
  Every A1–A6 PR cites a `scripts/e2e` assertion as its acceptance evidence,
  and B2's golden path is the explicit A5 acceptance gate.
- **ADR-07** (workload self-ownership) and **ADR-10** (build once, promote by
  digest): the guardrails this harness exercises — default-deny
  `NetworkPolicy` and `require-image-digest` — are ADR-07's and ADR-10's
  runtime enforcement. B1 proves them admit/deny on a real Kubernetes API
  server, a stronger claim than the `kyverno test` unit fixtures alone.
- **ADR-22** (Terraform↔Crossplane boundary v2): the trust-subject policy
  ADR-22 retired is explicitly excluded from B1's negative-test scope (epic
  decision #7) — this harness does not resurrect a retired policy just
  because it would be easy to test.
- **ADR-27** (node autoscaling): unrelated decision, same epic-adjacent
  numbering window — ADR-27's own Status section records that ADR-25/26 were
  reserved by epic #167 before this file existed.
- **Epic [#167](https://github.com/BinHsu/aegis-platform-aws/issues/167)**:
  the source decision record; B1–B3 are issues #170–#172.

## References

- Epic #167 — <https://github.com/BinHsu/aegis-platform-aws/issues/167>
- PRs: [#179](https://github.com/BinHsu/aegis-platform-aws/pull/179) (B1),
  [#191](https://github.com/BinHsu/aegis-platform-aws/pull/191) (B2)
- Open: [#172](https://github.com/BinHsu/aegis-platform-aws/issues/172) (B3,
  k3s lane, not implemented)
- [kind — configuring an insecure/local registry](https://kind.sigs.k8s.io/docs/user/local-registry/) —
  the `config_path`/`hosts.toml` mirror pattern B2 relies on.
- [Kyverno — testing policies](https://kyverno.io/docs/kyverno-cli/usage/test/) —
  the `kyverno test` fixtures B1 stopped skipping.
