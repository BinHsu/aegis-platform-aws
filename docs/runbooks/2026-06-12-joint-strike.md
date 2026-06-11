# 2026-06-12 Joint-Strike — canonical plan

**Status: ACTIVE until 2026-06-12.** Single source of truth for the next aegis
multi-account deploy→verify→destroy window. It unifies two workstreams that share
one live cluster cycle:

- **W1 — ADR-10 multi-account GitOps joint-strike** (build-once / promote-by-digest).
- **W2 — 2026-06-06 cost-incident remediation, live-verified** (the guards merged on
  2026-06-06 are all static/unit-validated only; this cycle proves them end-to-end).

Touches repos: **aegis-platform-aws** (infra + CI), **aegis-greeter-deploy** (workload
promotion), **aegis-landing-zone-aws** (org OIDC/SCP/registry). Any aegis-repo agent that
is about to touch multi-account, promotion, or a real apply/destroy **reads this first**.

> This doc *sequences* 6/12 and is the entry point. Operational detail lives in the linked
> sources; where W1 detail is not duplicated here, follow the linked runbook/ADR.

---

## Why this cycle is gated on cost (read before any apply)

This window provisions **billable** prod infra (EKS control plane bills $0.10/hr, or
**$0.60/hr if the version is past standard support** — the 2026-06-06 incident). Apply →
verify → **destroy in the same window**. Poll a real apply/destroy at ~1-minute cadence;
a failed apply leaves partial billable resources.

Current spend-control posture (all merged 2026-06-06, PRs #28/#29):

- Prod infra is now **on-demand** — `infra-apply` is `workflow_dispatch` only (A13). A
  merge to main no longer deploys; you dispatch the apply deliberately, in this window.
- Org budgets (`aegis-daily-usd10` + `aegis-monthly-usd30`, payer) + prod
  `aegis-platform-aws-monthly` ($25) + MANUAL budget action (A9) + Cost Anomaly Detection
  (A2) are live.
- TTL reaper (A11) + the human-gated `destroy` environment (A7) are in place as backstops.

---

## Pre-flight (state as of 2026-06-06)

- **main** carries the full cost-incident remediation (A1–A13). main has **no branch
  protection** (branch-protection.tf applies only when platform is deployed).
- GitHub Environments exist: `prod-apply` / `prod-apply-gated` (apply gate) / `destroy`
  (teardown gate, reviewer = operator). Secret `AWS_DESTROY_ROLE_ARN` is pre-set to the
  deterministic ARN; the role itself is created by the platform apply in step 1.
- ADR-10 release model is Accepted; the greeter image must already exist at a digest the
  greeter-deploy overlays pin (see W1 sources).
- Nothing is deployed right now (prior stack destroyed 2026-06-06).

---

## W1 — ADR-10 joint-strike (multi-account GitOps)

Detailed operational runbook + rationale (do not duplicate — follow these):

- `docs/runbooks/prod-joint-strike-pattern-b.md` — the proven Pattern-B vertical (governed
  CI → prod EKS → greeter → ALB 200 → destroy).
- `docs/adr/10-release-model-build-once-promote-by-digest.md` — build-once / promote-by-digest.
- Agent-recall: the `project_adr10_release_model_campaign` memory (resume plan, CT seed
  path, the registry-home open sub-decision).

W1 essence for 6/12: build greeter image once → digest D in the shared/artifacts registry
→ staging cluster syncs + verifies D → promotion PR copies **the same digest** into the
prod overlay → prod ArgoCD auto-syncs → verify prod-D ≡ staging-D ≡ built-D. 2-region
verify folded in.

---

## W2 — cost-incident remediation, live-verification

Full incident analysis + the per-step verification runbook live in the postmortem:

- `docs/postmortems/2026-06-06-eks-extended-support-cost-incident.md` — root cause, the
  G1–G7 guardrail verdicts, the three-layer prevention model, the §7d validation matrix,
  and **§7e the ordered live-verification runbook** (this section sequences §7e).

What 6/12 must prove (all currently static/unit-validated only): A12 version gate, A2
member-CE access, A6 self-reap, A4 kyverno teardown, A7 human-gated destroy + the
**destroy-scoped policy authored from this teardown's CloudTrail**, A11 reaper.

---

## W3 — infra-tier multi-account GitOps promotion (design; staging-float / prod-tag-pin)

> Added 2026-06-06 (design session). The **infra-tier analogue of W1**: it evolves the
> platform apply from A13 manual `workflow_dispatch` → a staging-float / prod-tag-pin GitOps
> promotion, so the account dimension is **git-declared** (`accounts.json` — CI orchestration config, read by the callers via jq; NOT a
`*.auto.tfvars.json`, so terraform never auto-loads it), not a
> single secret. **BUILT — PR #31** (`feat/w3-multi-account-promotion`, the four files below)
> — **HOLD until 6/12**: the merge is the live event (it auto-applies staging). Scope vs 6/12
> is decided: full ship (end of section).

**Model.** staging account (251774439261) **floats on main** — merge → auto-apply (version-gate
warn-only). prod account (506221082337) is **pinned to a release tag**; a promotion PR bumps the
pin → gated apply of the tagged tf. Same shape as W1/greeter, one tier down.

**The artifact difference vs W1 — the crux.** W1 (workload) pins prod to an immutable **image
digest** (external blob in ECR). W3 (infra) has no external blob — **the tf code IS the
artifact**, so prod pins a **git tag**, and CI must `git checkout <tag>` and apply *that* tree,
never HEAD. HEAD-vs-tag split: `accounts.json` (topology + pins) is read from
**HEAD**; tf code + `regions.auto.tfvars.json` (scalars) from the **tag**.

**Decisions (locked 2026-06-06 — do not re-litigate; a fresh agent will be tempted).**

| Decision | Chosen | Why |
|---|---|---|
| Versioning | Model A / **Option A — CI `git checkout <tag>`** (not module `?ref=`) | no module restructure; industry norm for deployment versioning (TFC / Spacelift / Atlantis all track a git ref) |
| Tag form | **semantic release tag** (not a SHA transition) | human-readable + release notes; avoids the long-lived env-branch anti-pattern |
| staging vs prod | **staging floats main / prod pins tag** | mirrors greeter overlays; staging leaner = faster + cheaper |
| prod trigger | **promotion PR; prod apply ALWAYS runs in `prod-apply-gated`** (human approval unconditional — not only when the gate trips; replaces A13 dispatch) | more GitOps; adds the staging-verify→promote step dispatch lacks; **preserves A13's prod protection** |
| role / bucket | **derive from account_id** (no per-account secret) | role `gh-tf-apply-platform` already exists per account, same name; derive shrinks the secret surface |
| Option B (module `?ref=`) | **rejected** | single repo, regional-stack has one consumer; B only pays off on cross-repo module reuse |
| sizing | **base (`regions`) + per-account `overrides`** (cidr always base) | mirrors greeter base+patch; stores only the env *difference*, no duplicate-and-drift |
| version-gate | **block prod / warn staging** (`gate_blocks` input): with `gate_blocks=true`, a tripped A12 gate **HARD-FAILS the prod apply** — extended-support never reaches prod (the human approval in `prod-apply-gated` is not an override for it) | staging must stay fast; prod must not silently bill extended-support |

**Files to build (4 + 1 kept).**
- `accounts.json` — account dimension + per-env pin (`staging.pin: main`, `prod.pin: vX.Y.Z`) + `enabled_regions` + per-account `overrides` (sizing only; cidr stays in `regions`).
- `infra-apply-account.yml` — **reusable** (`workflow_call`): the current `version-gate → apply-platform → apply-regional` jobs, parameterised by `account_id, ref, regions_json, overrides_json, gate_blocks`. Checks out `ref`; derives bucket `aegis-platform-aws-tfstate-<account_id>` + role `arn:aws:iam::<account_id>:role/gh-tf-apply-platform`; staging routes to an ungated env regardless of gate.
- `infra-staging.yml` — **caller**: on push to main (`terraform/**` + the two tfvars) → reads staging from HEAD `accounts.json` → calls the reusable with `ref=main`, `gate_blocks=false`.
- `infra-prod.yml` — **caller**: on push to main → `git diff` to detect whether `accounts.prod.pin` changed; if so → calls the reusable with prod account, `ref=<the pin tag>`, `gate_blocks=true`.
- `infra-apply.yml` (existing) — **kept as break-glass** manual dispatch (forker / emergency override of promotion).

**Staging cost model — ephemeral (option 1; operator 2026-06-06).** "staging floats on main"
would otherwise mean a *persistent* staging EKS billing ~$0.10–0.60/hr — over the ~$30 budget,
the same always-on cost the 2026-06-06 incident was about. Resolution: staging is **ephemeral,
reaped by the existing A11 TTL reaper** — no new teardown code. A cluster with no
`keep=true` / `ttl-exempt=true` tag is auto-destroyed after `TTL_HOURS` once
`REAPER_AUTODESTROY=true`. So staging is up while you iterate (re-applied each merge) and
auto-gone after a quiet `TTL_HOURS`. Requirements: (1) `REAPER_AUTODESTROY=true`; (2) staging
clusters carry **no** `keep` tag (the default); (3) staging `TTL_HOURS` tuned to the dev
rhythm. Prod persistence (a `keep` tag) is a separate post-6/12 steady-state decision; for the
6/12 window **both** envs are ephemeral/reaped.

**6/12 prerequisites (all done before the window — none of these is the live merge).**
- [x] The four files written + reviewed in a PR (**#31**) — **NOT merged** (the merge is the live event: it applies staging).
- [ ] New CI validated: `actionlint` clean; `workflow_call` wiring + prod-pin diff-detection + checkout-`ref` dry-checked.
- [ ] `REAPER_AUTODESTROY=true` is set (else ephemeral staging never auto-tears-down → the cost trap returns).
- [ ] Operator one-liner: create the `staging` GitHub Environment — **no reviewers, deployment branches = main only** (the reusable routes staging to it ungated).
- [ ] Operator one-liner: create the `reaper-destroy` GitHub Environment — **no reviewers, deployment branches = main only** (the reaper's ungated, tag-guarded auto-destroy path; the destroy role's OIDC trust accepts its subject — ADR-11).
- [ ] staging platform state bucket `aegis-platform-aws-tfstate-251774439261` bootstrapped; `BOOTSTRAP_COMPLETE` handled per-account (migrates into `accounts.json` — ADR-11).
- [ ] Account-agnostic secrets/vars confirmed present for the staging-account context.

**Scope vs 6/12 — DECISION: (a) build + ship W3 on 6/12 (operator, 2026-06-06).**
6/12 goes full. The four files are built, reviewed, and merged **first** (a prerequisite
stage — see the Unified order's step 0), then the deploy runs **through W3**: staging
auto-applies on the merge, prod is reached via a promotion PR + `prod-apply-gated` approve.
**A13 `workflow_dispatch` is demoted to break-glass only** (forker / emergency) — it is no
longer the normal prod path. This supersedes the Unified execution order's original step 1;
the order below is updated to match.

---

## Unified 6/12 execution order

Run W1 and W2 on one cluster cycle. **Per the W3 (a) decision, build W3 first, then deploy
through it — not the A13 dispatch.** Order:

0. **Build W3 (prerequisite).** Write → review → merge the four files (W3 §Files): the account
   dimension (`accounts.json`) + the reusable `infra-apply-account.yml` + the two
   callers. Once merged, a merge to main auto-applies **staging** (warn-only gate); **prod** is
   reached only via a promotion PR.

1. **Deploy via W3.** staging floats up on step 0's merge and verifies; cut a release tag at the
   verified commit; open the promotion PR (`accounts.prod.pin` → that tag) → `infra-prod` checks
   out the tag → `apply-platform` creates the destroy role (A7) + budget action (A9) + CE monitor
   (A2) and `apply-regional` stands up prod EKS — **always in `prod-apply-gated`** (the human
   approval is unconditional for prod). The A12 gate runs with `gate_blocks=true`: if it fires,
   the prod apply **HARD-FAILS** (extended-support never reaches prod; approval is not an
   override). (A13 `workflow_dispatch` stays as break-glass only.)
   - If `apply-platform` fails on `aws_ce_anomaly_*` → enable member-account Cost Explorer
     access in the management account, re-apply (A2 caveat).
2. **W1 promotion.** Bring greeter up via ArgoCD; run the promotion-by-digest verify per
   the W1 sources; confirm prod-D ≡ staging-D ≡ built-D; 2-region check.
3. **W2 guard checks (optional, while up):** A12 aging-path (pin an old version on a branch
   → gate routes to `prod-apply-gated`), A6 self-reap (inject an apply failure).
4. **Teardown via the human gate.** Dispatch `infra-ops` `destroy-region` **from any
   branch** → it pauses on the `destroy` environment → approve → confirm it reaches
   `aws_eks_cluster` with **no kyverno hang** (A4). This first teardown runs the destroy
   role's **admin** policy.
5. **A7 destroy-scoped policy — author from step 4's CloudTrail.** IAM Access Analyzer →
   generate-policy-from-CloudTrail on the destroy → write a `gh-tf-destroy-platform` policy
   that allows the observed `Delete*/Detach*/Modify*/Schedule*/Describe*` set and denies
   `Create*/Run*` → attach (replace admin) → re-run a teardown to confirm no `AccessDenied`.
   (Cannot be authored from theory — that is why it is a step here, not pre-written.)
   The attach itself must run as `gh-tf-apply-platform` CI (land it as a terraform change)
   or via break-glass — SCP 4 denies `iam:AttachRolePolicy` to SSO principals.
6. **A11 reaper check.** Leave a tagged-ephemeral cluster past `TTL_HOURS` → run
   `ttl-reaper` → confirm alert + (if `REAPER_AUTODESTROY=true`) dispatched destroy.
7. **Confirm zero + cost.** `aws eks list-clusters` empty in all regions; Cost Explorer
   shows the burn bounded; nothing billable left.

---

## Cross-repo touch points

| Repo | What 6/12 touches |
|---|---|
| aegis-platform-aws | infra apply/destroy, the version gate, reaper, budget action, destroy role (this repo) |
| aegis-greeter-deploy | the promotion PR (copy digest D into the prod overlay) |
| aegis-landing-zone-aws | org OIDC providers, the `gh-tf-*` SCP glob, the shared registry account |

After the window: set this doc's status to **DONE** (or supersede), and remove the
keystone block from `~/.claude/CLAUDE.md` + the per-repo CLAUDE.md routing lines.

---

# Addendum 2026-06-10/11 — pre-window hardening executed, rehearsal findings, and the aegis-core onboarding scope

> The 6/12 window now opens from a **much harder-tested** state than the 2026-06-06
> pre-flight assumed. This addendum records (A) what was hardened + merged before the
> window, (B) what the live staging rehearsal proved/broke, (C) the org-wide repo-security
> baseline, and (D) the **scoped CI/CD-flow gap for onboarding aegis-core** — the real
> workload, after greeter proved the pipeline. The 6/12 review continues from here.

## A. Pre-window hardening (merged 2026-06-10) — 4 BLOCKERs + W3 + budgets + registry chain

A cross-repo review found 4 BLOCKERs that would each have broken the 6/12 window; all fixed
and merged the same day (15 PRs). Headlines (full detail in the agent memory
`project_state_0610_pre612_hardening_campaign`):

- **OIDC env-subs** (`gh-tf-apply-platform` trust): environment-gated apply jobs could not
  assume the role at all — would have killed every 6/12 apply. Fixed (platform #34).
- **Destroy-role EKS access entry**: destroy was K8s-`Unauthorized` at the helm layer →
  would strand a billing cluster (the 06-06 shape, different root cause). Fixed via a
  `cluster_admin_principals` map (#34).
- **ArgoCD registry injection wiped the digest**: the old `kustomize.images` newName-only
  injection deletes the overlay's `digest` field → renders `:latest`. Moved to an
  `aegis.binhsu.org/ecr-repository` annotation + kustomize `replacements` (ADR-12). This is
  the load-bearing contract greeter-deploy now implements and **core-deploy does NOT** (see D).
- **W3 multi-account** (#31): prod always `prod-apply-gated`; A12 hard-fails prod; per-account
  `bootstrap_complete`/`environment`/`operator_principal_arn` in `accounts.json` (ADR-11);
  multi-account ttl-reaper + account-parameterised infra-ops; reaper → ungated-but-tag-guarded
  `reaper-destroy` environment.
- **Budgets are IaC** (LZ #258/#259, ADR-019) + **OIDC fails closed** on `infra_repo_id`.
- **Shared registry chain landed**: `aegis-deployment` account (162975888022) vended +
  bootstrapped + `gh-tf-apply-deployment` seeded; platform #27 (deployment ECR + cross-account
  pull + require-digest Kyverno); `REGISTRIES_JSON` repointed; greeter publish.yml switched to
  **PR + auto-merge** digest bump (no more direct push to a protected branch).

## B. Staging rehearsal (2026-06-10, live) — 5 latent bugs caught, all fixed

The first deliberate W3 staging apply (`bootstrap_complete=true`) caught bugs that only static
validation had ever seen. **This is why the rehearsal existed.** Each one would have hit the
prod path on 6/12:

1. **A2 anomaly subscription** `IMMEDIATE`+EMAIL is rejected by the CE API (`Immediate
   frequencies only support SNSTopic`). → `DAILY` (#37).
2. **1× t3.medium cannot host the platform stack** — pods Pending → ALB-controller webhook
   no-endpoints → crossplane/kyverno deadline. Staging floor raised to **2 nodes** (#38).
3. **A6 self-reap masked a failed destroy** (`|| echo`): the step went GREEN while the cluster
   kept billing. Fixed to fail-loud with a still-billing escalation (#38). *Worst-class bug —
   a cost guard that lies.*
4. **A4 kyverno helm destroy still deadlocks** on a wedged cluster. Working fallback = the
   06-06 pattern: `terraform state rm` all `helm_release.*`/`kubernetes_*` from the regional
   state → pure-AWS `infra-ops destroy-region` (ran green). **6/12 teardown must expect this.**
5. **Stale S3 `.tflock`** after a cancelled run blocks the next plan — twice in one day. Fix:
   delete `<state-key>.tflock` (SSO-allowed), re-run.

Rehearsal ended at **zero billable** (eks/ec2/nat/alb/ebs all empty); staging parked
(`bootstrap_complete=false`, PR #40). Operator decision: **6/12 close-out = full teardown to
zero** on both accounts (destroy-region + destroy-platform, shared ECR included); next cycle
cold-starts with a fresh publish run.

## C. Org-wide public-repo security baseline (2026-06-11)

All 36 BinHsu public repos hardened via `gh` (detail: memory
`project_org_repo_security_baseline_0611`): secret scanning + push protection + Dependabot
vulnerability alerts on **36/36**; tiered `main-protection` rulesets (product = full +
CodeRabbit required check; first-party = full minus CodeRabbit; learning/profile = force-push
+ deletion block; forks = hygiene only). `aegis-enclave` flipped **public + protected** after
the ATMOS case-study thank-you closed that cycle.

## D. aegis-core onboarding — CI/CD-flow gap (the post-greeter work)

greeter was the **carrier** that proved the ADR-10 pipeline; **aegis-core + aegis-core-deploy is
the real workload**. The flow gap (not app content — CI/CD only) was scoped 2026-06-11:

**core release pipeline is currently RED.** `release-staging-image.yml` has failed on the last
4 runs (since 2026-05-21; last success 2026-05-18). The 2026-06-07 run died at **`Configure AWS
credentials (OIDC): Not authorized to perform sts:AssumeRoleWithWebIdentity`** — the release
OIDC role can't be assumed, so it never reaches ECR. **Two stacked blockers**, in order:

1. **🔴 OIDC role assumption broken** (release can't push to ECR at all). Same class as the
   platform #34 OIDC blocker. Fix first — until then nothing downstream is exercised.
2. **🔴 Direct-push to a now-protected branch.** Once #1 is fixed, the `bump-image-tag` job's
   `git push origin main` into `aegis-core-deploy` hits the CodeRabbit+PR ruleset that repo now
   carries (added 06-07) → it will fail (or rely on admin bypass) — **exactly the fragility
   greeter #10 already fixed** by switching to PR + auto-merge. Port greeter's pattern.

**Structural CI/CD-flow deltas core→greeter (beyond the two blockers):**

| Flow stage | greeter (ADR-10, done) | aegis-core (today) |
|---|---|---|
| Artifact identity | immutable `@sha256:` **digest** | mutable **tag** `staging-<sha>` / `engine-staging-<sha>` (digest captured, unused) |
| Registry | shared `aegis-deployment` (162975888022) | **staging account** (251774439261) |
| Handoff → deploy repo | branch + `gh pr create` + **auto-merge** (CodeRabbit-gated) | `yq` rewrite + **direct `git push origin main`** |
| Promotion | staging overlay digest-bump → **prod promotion PR copies same digest** | **none** — core-deploy has **no staging overlay**; release writes straight to base/prod |
| Frontend | n/a | separate `release-staging-frontend.yml` → **S3 sync + CloudFront invalidation, direct, non-GitOps**, no env promotion (ADR-10 does not cover this artifact class) |
| Release gates | Trivy HIGH+CRIT **pre-push**, blocking | Cosign keyless + SLSA L3 + SBOM attest (stronger) **but** Trivy CRITICAL-only **post-push**; gosec/semgrep/govulncheck all `\|\| true` (advisory) |
| Deploy-repo CI | `validate.yml` (digest-presence + injection-sim regression guard) | **none** (core-deploy has no `.github/`) |
| Injection axes | registry + region (2 annotations) | registry + region + **IRSA role-arn** (Crossplane WorkloadIdentity) — a 3rd axis greeter never had |
| Multi-image | 1 image = 1 digest pin | **2 images** (gateway + engine) sharing one ECR repo by tag-prefix → needs **atomic 2-digest promotion**, which ADR-10 has no model for |

**Onboarding effort split:** ~½ is porting greeter's proven mechanics (digest-pin, staging
overlay, PR-bump, `validate.yml`); ~½ needs **new design + ADRs** — (a) multi-image atomic
promotion (2 digests in one PR), (b) the frontend's non-GitOps env-promotion model (versioned
S3 prefix / CloudFront deployment id as the digest analogue). Sequence: **fix OIDC (blocker 1)
→ port PR-bump handoff (blocker 2) → digest-pin + staging overlay + validate.yml → then the two
new-ADR designs.** Full agent-recall in memory `project_post612_core_review_commitment`.

## E. Post-window roadmap — four workstreams (operator framing 2026-06-11)

**The carrier principle, applied twice.** greeter de-risks the hard work for core by being the
minimal workload: it proved the **release flow (ADR-10)** on AWS at 6/12, and it should also
prove the **on-prem substrate path** before core attempts it. Then core only ever adds its
genuinely-core-specific complexity on top of two already-proven paths — never fighting a new
substrate + multi-image + identity-abstraction all at once. So the roadmap is four workstreams,
tracked as issues WS0–WS3 (this section is their epic):

- **WS0 — greeter on-prem path proof (the carrier for on-prem).** Stand greeter up on a local
  Talos cluster and prove the reusable *path*: Talos bring-up, ArgoCD-on-Talos, MetalLB +
  ingress-nginx, a **Talos platform overlay** that injects the registry+region annotations (proving
  the injection contract is genuinely target-swappable, not EKS-only), and pulling the digest-
  pinned image from the shared ECR into Talos. **Output:** the reusable on-prem path + the
  per-target overlay shape + the "provider-neutral injection contract" ADR. **Caveat:** greeter is
  so minimal it has **no identity need**, so WS0 cannot exercise the IRSA→SPIFFE axis (the deepest
  part of the neutral contract) — that first lands in WS2. Option (open): give greeter a throwaway
  identity need (read an S3 object on AWS / a MinIO object on Talos) to prove the identity axis on
  the carrier too. Can run in parallel with WS1.
- **WS1 — core Parity.** Bring `aegis-core`/`aegis-core-deploy` up to greeter's ADR-10 level: fix
  the two blockers (OIDC role assumption; direct-push→PR-bump handoff) and port the proven
  CI/CD mechanics (digest pinning, registry, staging overlay, `validate.yml`). **Crucially, since
  the first real target is local (see decision below), WS1 builds the injection contract
  PROVIDER-NEUTRAL from the start** — no leaning on IRSA/Cognito/ALB. **Output:** core release
  pipeline GREEN with digest-promotion, proven against the **local Talos** target. **Gate for
  WS2 and WS3.**
- **WS2 — core On-prem (FULL verification, not a spike).** Stand core up on local Talos,
  **inheriting WS0's proven path**, adding only the **core-specific** substitutes. **Output:** core
  running on neutral infra. Substitutes core adds on top of WS0: identity IRSA→**SPIFFE/SPIRE or
  static/sealed-secret** (deepest — it threads the Crossplane WorkloadIdentity injection; the axis
  WS0 could not test), object store S3→**MinIO**, gateway auth Cognito→**Keycloak/Dex**, frontend
  CloudFront→**in-cluster nginx**, plus multi-image. (Ingress/DNS + the neutral injection contract
  come from WS0.) Registry can keep pulling the shared ECR for the first pass; a self-hosted
  **Harbor** is a later air-gap refinement.
- **WS3 — Full AWS bring-up.** With the contract already neutral, AWS becomes an **additive
  binding overlay**, never a retrofit: add the EKS/IRSA/ECR/Cognito/ALB bindings + multi-image
  atomic promotion + the frontend env-promotion model. **Output:** the real product live on the
  governed AWS platform (greeter's joint-strike, for the real workload).

**Sequencing — DECIDED 2026-06-11 (operator): local-first, because the project is past PoC.**
PoC-stage optimises for fast cloud demo (AWS-first, managed everything). Product-stage optimises
for control / portability / reproducibility / cost / no lock-in (and likely data-residency —
ATMOS). So prove on **neutral infra first**, where the architecture cannot secretly depend on a
managed service. Order: **WS0 (greeter proves the on-prem path) → WS1 (core parity, neutral) →
WS2 (core full on-prem, inherits WS0) → WS3 (add the AWS binding overlay).** WS0 ∥ WS1 may
overlap. This makes the provider-neutral injection contract a **WS0/WS1 prerequisite, not a WS2
deliverable** — the cleaner architecture, where AWS is just one target. Accepted risk: thin,
because greeter carries the substrate proof (WS0) and core inherits it — core's on-prem work is
reduced to its own workload substitutes (identity/storage/auth/multi-image).

> The epic / full-picture view lives in the agent memory
> `project_post612_core_review_commitment`; the four workstreams are tracked as GitHub issues
> WS0–WS3 in `aegis-platform-aws`. This §E is the committed-doc snapshot.
