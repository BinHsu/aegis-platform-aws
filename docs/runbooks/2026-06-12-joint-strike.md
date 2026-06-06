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

## Unified 6/12 execution order

Run W1 and W2 on one cluster cycle. Order:

1. **Deploy (on-demand).** Dispatch `infra-apply` (`confirm: apply`) from main →
   `apply-platform` creates the destroy role (A7) + budget action (A9) + CE monitor (A2);
   `apply-regional` stands up EKS. Confirms A13 (dispatch, not merge) + the A12 gate path.
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
