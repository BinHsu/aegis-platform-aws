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
> single secret. **NOT YET BUILT** — the four files below do not exist. Scope vs 6/12 is an
> open decision (end of section).

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
| prod trigger | **promotion PR + `prod-apply-gated` approve** (replaces A13 dispatch) | more GitOps; adds the staging-verify→promote step dispatch lacks; **preserves A13's prod protection** |
| role / bucket | **derive from account_id** (no per-account secret) | role `gh-tf-apply-platform` already exists per account, same name; derive shrinks the secret surface |
| Option B (module `?ref=`) | **rejected** | single repo, regional-stack has one consumer; B only pays off on cross-repo module reuse |
| sizing | **base (`regions`) + per-account `overrides`** (cidr always base) | mirrors greeter base+patch; stores only the env *difference*, no duplicate-and-drift |
| version-gate | **block prod / warn staging** (`gate_blocks` input) | staging must stay fast; prod must not silently bill extended-support |

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
- [ ] The four files written + reviewed in a PR — **NOT merged** (the merge is the live event: it applies staging).
- [ ] New CI validated: `actionlint` clean; `workflow_call` wiring + prod-pin diff-detection + checkout-`ref` dry-checked.
- [ ] `REAPER_AUTODESTROY=true` is set (else ephemeral staging never auto-tears-down → the cost trap returns).
- [ ] A `staging` GitHub Environment exists (the reusable routes staging to an ungated env).
- [ ] staging platform state bucket `aegis-platform-aws-tfstate-251774439261` bootstrapped; `BOOTSTRAP_COMPLETE` handled per-account.
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
   (A2) and `apply-regional` stands up prod EKS, gated by `prod-apply-gated`. Confirms the A12
   gate path on the prod promotion. (A13 `workflow_dispatch` stays as break-glass only.)
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
